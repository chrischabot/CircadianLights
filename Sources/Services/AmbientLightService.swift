import Foundation
import IOKit
import IOKit.hid

/// Reads macOS ambient light sensor data (e.g. Pro Display XDR) via HID reports.
///
/// Pro Display XDR exposes an "Ambient Light" sensor (UsagePage 0x20 / Usage 0x41)
/// with an input report containing illuminance + correlated color temperature.
@MainActor
final class AmbientLightService: ObservableObject {

    struct SensorReading: Identifiable, Sendable, Equatable {
        let id: UInt64
        let product: String
        let serialNumber: String?
        let illuminanceLux: Double
        let correlatedColorTemperatureKelvin: Int
        let chromaticityX: Double
        let chromaticityY: Double
        let lastUpdated: Date
    }

    enum Status: Sendable, Equatable {
        case idle
        case unavailable
        case running
        case error(String)
    }

    // MARK: - Published State

    @Published private(set) var status: Status = .idle
    @Published private(set) var sensors: [SensorReading] = []

    // MARK: - Private State

    private var manager: IOHIDManager?
    private var devicesByID: [UInt64: IOHIDDevice] = [:]
    private var smoothedByID: [UInt64: SensorReading] = [:]
    private var pollTask: Task<Void, Never>?

    private let pollInterval: Duration = .seconds(1)
    private let smoothingAlpha: Double = 0.25

    // MARK: - Public API

    func start() {
        guard pollTask == nil else { return }

        refreshDevices()

        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.pollOnce()
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        closeAllDevices()
        closeManager()
        sensors = []
        smoothedByID = [:]
        status = .idle
    }

    /// Auto-selects the sensor with the highest illuminance.
    var autoSelectedSensor: SensorReading? {
        sensors.max(by: { $0.illuminanceLux < $1.illuminanceLux })
    }

    // MARK: - Polling

    private func pollOnce() {
        if devicesByID.isEmpty {
            refreshDevices()
            return
        }

        var nextReadings: [SensorReading] = []
        nextReadings.reserveCapacity(devicesByID.count)

        for (id, device) in devicesByID {
            guard let reading = readInputReport(from: device, id: id) else { continue }
            let smoothed = smooth(reading: reading, id: id)
            nextReadings.append(smoothed)
        }

        nextReadings.sort { $0.id < $1.id }
        sensors = nextReadings
        status = sensors.isEmpty ? .unavailable : .running
    }

    // MARK: - HID Setup

    private func refreshDevices() {
        closeAllDevices()
        devicesByID = [:]
        smoothedByID = [:]

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey: 0x20,
            kIOHIDDeviceUsageKey: 0x41
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            status = .error("IOHIDManagerOpen failed (\(openResult))")
            return
        }

        let deviceSet = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        var openedCount = 0

        for device in deviceSet {
            guard let id = registryID(for: device) else { continue }

            let openDeviceResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            guard openDeviceResult == kIOReturnSuccess else {
                continue
            }

            devicesByID[id] = device
            openedCount += 1
        }

        status = openedCount > 0 ? .running : .unavailable
    }

    private func closeAllDevices() {
        for (_, device) in devicesByID {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    private func closeManager() {
        guard let manager else { return }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    // MARK: - Report Parsing

    private func readInputReport(from device: IOHIDDevice, id: UInt64) -> SensorReading? {
        var buffer = [UInt8](repeating: 0, count: 64)
        var length: CFIndex = buffer.count

        let result = IOHIDDeviceGetReport(
            device,
            kIOHIDReportTypeInput,
            CFIndex(1), // Pro Display XDR ALS uses ReportID 1
            &buffer,
            &length
        )
        guard result == kIOReturnSuccess else {
            return nil
        }

        let data = Data(buffer.prefix(Int(length)))
        guard data.count >= 18 else { return nil }

        // Report format (little-endian):
        // [0] reportId
        // [1] state
        // [2..5]  sensor value (observed as illuminance, scaled by 1e-3)
        // [6..9]  correlated color temperature (Kelvin)
        // [10..13] chromaticity x (scaled by 1e-8)
        // [14..17] chromaticity y (scaled by 1e-8)
        let valueRaw = data.uint32LE(at: 2)
        let kelvinRaw = data.uint32LE(at: 6)
        let chromaXRaw = data.uint32LE(at: 10)
        let chromaYRaw = data.uint32LE(at: 14)

        let product = stringProperty(device, key: kIOHIDProductKey) ?? "Ambient Light Sensor"
        let serial = stringProperty(device, key: kIOHIDSerialNumberKey)

        return SensorReading(
            id: id,
            product: product,
            serialNumber: serial,
            illuminanceLux: Double(valueRaw) / 1000.0,
            correlatedColorTemperatureKelvin: Int(kelvinRaw),
            chromaticityX: Double(chromaXRaw) / 100_000_000.0,
            chromaticityY: Double(chromaYRaw) / 100_000_000.0,
            lastUpdated: Date()
        )
    }

    private func smooth(reading: SensorReading, id: UInt64) -> SensorReading {
        guard let previous = smoothedByID[id] else {
            smoothedByID[id] = reading
            return reading
        }

        let alpha = smoothingAlpha
        let lux = previous.illuminanceLux * (1 - alpha) + reading.illuminanceLux * alpha
        let kelvin = Double(previous.correlatedColorTemperatureKelvin) * (1 - alpha) + Double(reading.correlatedColorTemperatureKelvin) * alpha
        let x = previous.chromaticityX * (1 - alpha) + reading.chromaticityX * alpha
        let y = previous.chromaticityY * (1 - alpha) + reading.chromaticityY * alpha

        let smoothed = SensorReading(
            id: reading.id,
            product: reading.product,
            serialNumber: reading.serialNumber,
            illuminanceLux: lux,
            correlatedColorTemperatureKelvin: Int(kelvin.rounded()),
            chromaticityX: x,
            chromaticityY: y,
            lastUpdated: reading.lastUpdated
        )

        smoothedByID[id] = smoothed
        return smoothed
    }

    // MARK: - Properties

    private func registryID(for device: IOHIDDevice) -> UInt64? {
        let service = IOHIDDeviceGetService(device)
        var entryID: UInt64 = 0
        let result = IORegistryEntryGetRegistryEntryID(service, &entryID)
        guard result == KERN_SUCCESS else { return nil }
        return entryID
    }

    private func stringProperty(_ device: IOHIDDevice, key: String) -> String? {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
        return value as? String
    }
}

// MARK: - Data Helpers

private extension Data {
    func uint32LE(at offset: Int) -> UInt32 {
        let end = offset + 4
        guard offset >= 0, end <= count else { return 0 }

        var value: UInt32 = 0
        value |= UInt32(self[offset])
        value |= UInt32(self[offset + 1]) << 8
        value |= UInt32(self[offset + 2]) << 16
        value |= UInt32(self[offset + 3]) << 24
        return value
    }
}
