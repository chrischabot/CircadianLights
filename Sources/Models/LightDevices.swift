import Foundation

// MARK: - Light Device Protocol

protocol LightDevice: Identifiable, Codable {
    var id: UUID { get }
    var name: String { get set }
    var isEnabled: Bool { get set }
    var isReachable: Bool { get }
}

// MARK: - Elgato Key Light

struct ElgatoLight: LightDevice, Equatable {
    let id: UUID
    var name: String
    var ip: String
    var isEnabled: Bool
    var isReachable: Bool = false

    // Current state (from device)
    var isOn: Bool = false
    var brightness: Int = 50      // 3-100
    var temperature: Int = 200    // 143-344 (Elgato value)

    var temperatureKelvin: Int {
        ColorTemperature.elgatoToKelvin(temperature)
    }
}

// MARK: - Philips Hue Light

struct HueLight: LightDevice, Equatable {
    let id: UUID
    var hueId: String             // ID from the Hue bridge (e.g., "1", "2")
    var name: String
    var isEnabled: Bool
    var isReachable: Bool = false

    // Current state (from device)
    var isOn: Bool = false
    var brightness: Int = 254     // 0-254
    var colorTemp: Int = 366      // 153-500 (mirek)

    var brightnessPercent: Int {
        Int(Double(brightness) / 254.0 * 100.0)
    }

    var temperatureKelvin: Int {
        ColorTemperature.mirekToKelvin(colorTemp)
    }
}

// MARK: - Philips Hue Bridge

struct HueBridge: Codable, Equatable {
    var ip: String
    var username: String?
    var isConnected: Bool = false

    var isAuthenticated: Bool {
        username != nil && !username!.isEmpty
    }
}
