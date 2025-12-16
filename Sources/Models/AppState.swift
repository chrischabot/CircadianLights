import SwiftUI
import Combine
import CoreLocation

@MainActor
final class AppState: ObservableObject {
    // MARK: - Published State

    @Published var isEnabled: Bool = false {
        didSet {
            if isEnabled {
                startOrchestrator()
            } else {
                stopOrchestrator()
            }
        }
    }

    @Published var currentColorTemperature: Int = 4000
    @Published var currentHueBrightness: Int = 100
    @Published var currentElgatoBrightness: Int = 100
    @Published var currentCloudCover: Int = 0
    @Published var currentRadiation: Double = 0
    @Published var cloudAdjustment: Int = 0  // Kelvin adjustment from weather
    @Published var currentDayProgress: Double = 0.5  // 0=sunrise, 0.5=noon, 1=sunset

    // MARK: - Device State

    @Published var hueLights: [HueLight] = []
    @Published var elgatoLights: [ElgatoLight] = []
    @Published var hueConnectionStatus: ConnectionStatus = .disconnected

    // MARK: - Persisted Settings

    @AppStorage("hueBridgeIP") var hueBridgeIP: String = "192.168.0.80"
    @AppStorage("hueUsername") var hueUsername: String = ""
    @AppStorage("updateIntervalSeconds") var updateIntervalSeconds: Int = 60
    @AppStorage("weatherAdjustmentEnabled") var weatherAdjustmentEnabled: Bool = true
    @AppStorage("useCurveBasedBrightness") var useCurveBasedBrightness: Bool = true

    // MARK: - Ambient Sensor Settings (Pro Display XDR / ALS)

    @AppStorage("ambientSensorSelection") var ambientSensorSelection: String = "auto" // "auto" or registry id
    @AppStorage("useAmbientSensorForElgatoBrightness") var useAmbientSensorForElgatoBrightness: Bool = true
    @AppStorage("ambientBrightnessLuxLow") var ambientBrightnessLuxLow: Double = 50
    @AppStorage("ambientBrightnessLuxHigh") var ambientBrightnessLuxHigh: Double = 5000
    @AppStorage("ambientBrightnessGamma") var ambientBrightnessGamma: Double = 2.0
    @AppStorage("useAmbientSensorForDaytimeColorTemperature") var useAmbientSensorForDaytimeColorTemperature: Bool = true
    @AppStorage("ambientColorTemperatureStrength") var ambientColorTemperatureStrength: Double = 0.35
    @AppStorage("elgatoRadianceIndoorFactor") var elgatoRadianceIndoorFactor: Double = 1.3

    // MARK: - Configurable Limits (persisted)

    @Published var brightnessLimits: CircadianCurve.BrightnessLimits {
        didSet { saveBrightnessLimits() }
    }

    @Published var colorTempLimits: CircadianCurve.ColorTempLimits {
        didSet { saveColorTempLimits() }
    }

    // MARK: - Services

    let solarService: SolarService
    let locationService: LocationService
    let elgatoService: ElgatoService
    let hueService: HueService
    let weatherService: WeatherService
    let ambientLightService: AmbientLightService
    private var orchestratorTask: Task<Void, Never>?

    // MARK: - Update Status

    @Published var lastUpdateTime: Date?
    @Published var elgatoUpdateResults: [UUID: Bool] = [:]
    @Published var hueUpdateResults: [UUID: Bool] = [:]

    // MARK: - Legacy Schedule (kept for backwards compatibility)

    @Published var brightnessSchedule: BrightnessSchedule {
        didSet {
            saveBrightnessSchedule()
        }
    }

    // MARK: - 24-Hour Preview Cache

    @Published var hourlyPreview: [CircadianCurve.HourlyPreview] = []

    // MARK: - Initialization

    init() {
        self.solarService = SolarService()
        self.locationService = LocationService()
        self.elgatoService = ElgatoService()
        self.hueService = HueService()
        self.weatherService = WeatherService()
        self.ambientLightService = AmbientLightService()
        self.brightnessSchedule = Self.loadBrightnessSchedule()
        self.brightnessLimits = Self.loadBrightnessLimits()
        self.colorTempLimits = Self.loadColorTempLimits()

        // Load saved lights
        self.elgatoLights = Self.loadElgatoLights()
        self.hueLights = Self.loadHueLights()

        // Detect location on init
        Task {
            await detectLocation()
        }

        // Auto-test Elgato lights on startup
        Task {
            await testAllElgatoLights()
        }

        ambientLightService.start()
    }

    // MARK: - Elgato Auto-Connect

    /// Test all configured Elgato lights to update reachability status
    func testAllElgatoLights() async {
        for index in elgatoLights.indices {
            let reachable = await elgatoService.isReachable(ip: elgatoLights[index].ip)
            elgatoLights[index].isReachable = reachable
        }
    }

    // MARK: - Location

    func detectLocation() async {
        if let location = await locationService.detectLocation() {
            solarService.updateLocation(latitude: location.latitude, longitude: location.longitude)
            print("Location detected: \(locationService.locationName) (\(location.latitude), \(location.longitude))")

            // Update values immediately
            await updateCurrentValues()
            updateHourlyPreview()
        } else {
            print("Failed to detect location, using defaults")
        }
    }

    // MARK: - Orchestrator Control

    private func startOrchestrator() {
        orchestratorTask?.cancel()
        orchestratorTask = Task {
            await runUpdateLoop()
        }
    }

    private func stopOrchestrator() {
        orchestratorTask?.cancel()
        orchestratorTask = nil
    }

    private func runUpdateLoop() async {
        while !Task.isCancelled {
            await updateLights()
            try? await Task.sleep(for: .seconds(updateIntervalSeconds))
        }
    }

    // MARK: - Core Calculations

    /// Update current values without sending to lights
    private func updateCurrentValues() async {
        guard let sunrise = solarService.todaySunrise(),
              let sunset = solarService.todaySunset() else {
            return
        }

        let now = Date()

        // Calculate day progress with 60-minute transition zones
        currentDayProgress = CircadianCurve.extendedDayProgress(
            date: now,
            sunrise: sunrise,
            sunset: sunset,
            transitionMinutes: 60
        )
        let isAmbientAdjustmentTime = currentDayProgress >= 0 && currentDayProgress <= 1

        // Fetch weather data if enabled
        var radiationFactor: Double? = nil
        if weatherAdjustmentEnabled {
            if let location = locationService.currentLocation {
                await weatherService.getWeatherData(
                    latitude: location.latitude,
                    longitude: location.longitude
                )
            }

            currentCloudCover = weatherService.currentCloudCover
            currentRadiation = weatherService.currentRadiation
            radiationFactor = weatherService.normalizedRadiation

            // Calculate actual applied cloud adjustment (matching CircadianCurve.colorTemperature logic)
            cloudAdjustment = calculateActualCloudAdjustment(
                progress: currentDayProgress,
                cloudCover: currentCloudCover,
                maxBoost: colorTempLimits.cloudBoostMax
            )
        } else {
            cloudAdjustment = 0
        }

        // Calculate color temperature using smooth curves
        // Cloud cover is passed regardless of time - the curve function handles daylight fading
        let kelvin = CircadianCurve.colorTemperature(
            progress: currentDayProgress,
            limits: colorTempLimits,
            cloudCover: weatherAdjustmentEnabled ? currentCloudCover : 0
        )

        // True Tone-style: blend toward measured ambient during daylight.
        if useAmbientSensorForDaytimeColorTemperature,
           isAmbientAdjustmentTime,
           let ambient = selectedAmbientReading(),
           ambient.correlatedColorTemperatureKelvin > 1000 {
            let strength = min(1.0, max(0.0, ambientColorTemperatureStrength))
            let weight = strength * ambientBlendWeight(forLux: ambient.illuminanceLux)
            let blended = Double(kelvin) * (1 - weight) + Double(ambient.correlatedColorTemperatureKelvin) * weight
            currentColorTemperature = Int(min(7500, max(Double(colorTempLimits.warmest), blended)).rounded())
        } else {
            currentColorTemperature = kelvin
        }

        // Calculate brightness using smooth curves
        if useCurveBasedBrightness {
            currentHueBrightness = CircadianCurve.hueBrightness(
                progress: currentDayProgress,
                limits: brightnessLimits,
                radiationFactor: radiationFactor
            )

            if useAmbientSensorForElgatoBrightness,
               isAmbientAdjustmentTime,
               let ambient = selectedAmbientReading() {
                currentElgatoBrightness = elgatoAmbientBrightness(
                    ambientLux: ambient.illuminanceLux,
                    progress: currentDayProgress,
                    limits: brightnessLimits
                )
            } else {
                if weatherAdjustmentEnabled, weatherService.lastFetchTime != nil {
                    currentElgatoBrightness = elgatoRadianceBrightness(
                        progress: currentDayProgress,
                        limits: brightnessLimits,
                        radiation: currentRadiation,
                        diffuseRadiation: weatherService.currentDiffuseRadiation
                    )
                } else {
                    currentElgatoBrightness = CircadianCurve.elgatoBrightness(
                        progress: currentDayProgress,
                        limits: brightnessLimits,
                        radiationFactor: radiationFactor
                    )
                }
            }
        } else {
            // Use legacy fixed schedule
            let (hueBrightness, elgatoBrightness) = brightnessSchedule.brightnessForCurrentTime()
            currentHueBrightness = hueBrightness
            currentElgatoBrightness = elgatoBrightness
        }
    }

    func updateLights() async {
        await updateCurrentValues()

        lastUpdateTime = Date()

        let weatherInfo = weatherAdjustmentEnabled
            ? " (\(weatherService.cloudCoverDescription) \(currentCloudCover)%, \(Int(currentRadiation))W/m², +\(cloudAdjustment)K)"
            : ""
        print("[\(Date())] Updating: \(currentColorTemperature)K\(weatherInfo), Hue: \(currentHueBrightness)%, Elgato: \(currentElgatoBrightness)%, Progress: \(String(format: "%.2f", currentDayProgress))")

        // Update Elgato lights
        let elgatoResults = await elgatoService.updateLights(
            elgatoLights,
            kelvin: currentColorTemperature,
            brightnessPercent: currentElgatoBrightness
        )
        elgatoUpdateResults = elgatoResults

        // Update reachability status
        for (id, success) in elgatoResults {
            if let index = elgatoLights.firstIndex(where: { $0.id == id }) {
                elgatoLights[index].isReachable = success
            }
        }

        // Update Hue lights if authenticated
        if !hueUsername.isEmpty {
            let hueResults = await hueService.updateLights(
                bridgeIP: hueBridgeIP,
                username: hueUsername,
                lights: hueLights,
                kelvin: currentColorTemperature,
                brightnessPercent: currentHueBrightness
            )
            hueUpdateResults = hueResults

            // Update reachability status
            for (id, success) in hueResults {
                if let index = hueLights.firstIndex(where: { $0.id == id }) {
                    hueLights[index].isReachable = success
                }
            }

            if hueResults.values.contains(true) {
                hueConnectionStatus = .connected
            } else if !hueResults.isEmpty {
                hueConnectionStatus = .error
            }
        }

        let elgatoSuccess = elgatoResults.values.filter { $0 }.count
        let hueSuccess = hueUpdateResults.values.filter { $0 }.count
        print("[\(Date())] Updated \(elgatoSuccess)/\(elgatoLights.filter(\.isEnabled).count) Elgato, \(hueSuccess)/\(hueLights.filter(\.isEnabled).count) Hue lights")

        // Update preview after each update
        updateHourlyPreview()
    }

    // MARK: - 24-Hour Preview

    func updateHourlyPreview() {
        guard let sunrise = solarService.todaySunrise(),
              let sunset = solarService.todaySunset() else {
            return
        }

        hourlyPreview = CircadianCurve.generate24HourPreview(
            sunrise: sunrise,
            sunset: sunset,
            brightnessLimits: brightnessLimits,
            colorTempLimits: colorTempLimits,
            hourlyCloudCover: weatherService.hourlyCloudCover,
            hourlyRadiation: weatherService.hourlyRadiation
        )
    }

    // MARK: - Manual Refresh

    func refreshNow() async {
        await updateLights()
    }

    // MARK: - Cloud Adjustment Helpers

    /// Calculate the actual cloud adjustment applied to color temperature.
    /// Mirrors the logic in CircadianCurve.colorTemperature() for accurate display.
    private func calculateActualCloudAdjustment(progress: Double, cloudCover: Int, maxBoost: Int) -> Int {
        guard cloudCover > 0 else { return 0 }

        // Curve value: 0 at night, sigmoidCosine during day
        let curveValue: Double
        if progress < 0 || progress > 1 {
            curveValue = 0
        } else {
            curveValue = CircadianCurve.sigmoidCosine(progress)
        }

        // Daylight factor: fades during twilight
        let daylightFactor: Double
        if progress < 0 {
            daylightFactor = 0
        } else if progress < 0.1 {
            daylightFactor = progress / 0.1
        } else if progress <= 0.9 {
            daylightFactor = 1.0
        } else if progress <= 1.0 {
            let twilightProgress = (progress - 0.9) / 0.1
            daylightFactor = 1.0 - (twilightProgress * 0.5)
        } else if progress <= 1.5 {
            let afterSunsetProgress = (progress - 1.0) / 0.5
            daylightFactor = 0.5 * (1.0 - afterSunsetProgress)
        } else {
            daylightFactor = 0
        }

        // Cloud boost with power curve
        let cloudFactor = Double(cloudCover) / 100.0
        let cloudBoost = pow(cloudFactor, 1.5) * Double(maxBoost)

        // Actual applied = cloudBoost * daylightFactor * curveValue
        return Int((cloudBoost * daylightFactor * curveValue).rounded())
    }

    // MARK: - Ambient Sensor Helpers

    private func selectedAmbientReading() -> AmbientLightService.SensorReading? {
        if ambientSensorSelection == "auto" {
            return ambientLightService.autoSelectedSensor
        }

        if let selectedID = UInt64(ambientSensorSelection),
           let match = ambientLightService.sensors.first(where: { $0.id == selectedID }) {
            return match
        }

        return ambientLightService.autoSelectedSensor
    }

    private func ambientBlendWeight(forLux lux: Double) -> Double {
        let low = max(0.001, ambientBrightnessLuxLow)
        let high = max(low + 0.001, ambientBrightnessLuxHigh)
        let clampedLux = max(0.001, lux)

        let logLow = log10(low)
        let logHigh = log10(high)
        let logLux = log10(clampedLux)

        let normalized = (logLux - logLow) / (logHigh - logLow)
        return min(1.0, max(0.0, normalized))
    }

    private func elgatoAmbientBrightness(
        ambientLux: Double,
        progress: Double,
        limits: CircadianCurve.BrightnessLimits
    ) -> Int {
        let range = Double(limits.elgatoMax - limits.elgatoMin)

        let clampedProgress = min(1.0, max(0.0, progress))
        let dayCurve = CircadianCurve.sigmoidCosine(clampedProgress)
        let normalizedLux = ambientBlendWeight(forLux: ambientLux)
        let gamma = max(0.1, ambientBrightnessGamma)
        let luxFactor = pow(normalizedLux, gamma)

        let curveValue = dayCurve * luxFactor
        let brightness = Double(limits.elgatoMin) + curveValue * range
        return min(limits.elgatoMax, max(limits.elgatoMin, Int(brightness.rounded())))
    }

    private func elgatoRadianceBrightness(
        progress: Double,
        limits: CircadianCurve.BrightnessLimits,
        radiation: Double,
        diffuseRadiation: Double
    ) -> Int {
        // Normalize shortwave radiation (typical clear-sky peak ~1000 W/m²)
        let radiationNorm = min(1.0, max(0.0, radiation / 1000.0))
        let radiationCurve = pow(radiationNorm, 1.5)

        // Diffuse ratio helps distinguish "overcast" from "clear".
        let diffuseRatio = radiation > 1 ? diffuseRadiation / radiation : 1.0
        let overcastDamping = 1.0 - (min(1.0, diffuseRatio) * 0.7)
        let indoorFactor = min(2.0, max(0.5, elgatoRadianceIndoorFactor))

        // Progress outside 0-1 indicates night (extended twilight handled by caller).
        let dayFactor: Double
        if progress < 0 {
            dayFactor = max(0, 1 + progress * 2)
        } else if progress > 1 {
            dayFactor = max(0, 1 - (progress - 1) * 2)
        } else {
            dayFactor = 1.0
        }

        var curveValue = radiationCurve * overcastDamping * indoorFactor * dayFactor
        curveValue = min(1.0, max(0.0, curveValue))

        let range = Double(limits.elgatoMax - limits.elgatoMin)
        let brightness = Double(limits.elgatoMin) + curveValue * range
        return min(limits.elgatoMax, max(limits.elgatoMin, Int(brightness.rounded())))
    }

    // MARK: - Persistence

    private static func loadBrightnessSchedule() -> BrightnessSchedule {
        guard let data = UserDefaults.standard.data(forKey: "brightnessSchedule"),
              let schedule = try? JSONDecoder().decode(BrightnessSchedule.self, from: data) else {
            return .default
        }
        return schedule
    }

    private func saveBrightnessSchedule() {
        if let data = try? JSONEncoder().encode(brightnessSchedule) {
            UserDefaults.standard.set(data, forKey: "brightnessSchedule")
        }
    }

    private static func loadBrightnessLimits() -> CircadianCurve.BrightnessLimits {
        guard let data = UserDefaults.standard.data(forKey: "brightnessLimits"),
              let limits = try? JSONDecoder().decode(CircadianCurve.BrightnessLimits.self, from: data) else {
            // User's specified defaults: Hue min 60%, Elgato min 4%
            return CircadianCurve.BrightnessLimits(
                hueMax: 100,
                hueMin: 60,
                elgatoMax: 100,
                elgatoMin: 4
            )
        }
        return limits
    }

    private func saveBrightnessLimits() {
        if let data = try? JSONEncoder().encode(brightnessLimits) {
            UserDefaults.standard.set(data, forKey: "brightnessLimits")
        }
    }

    private static func loadColorTempLimits() -> CircadianCurve.ColorTempLimits {
        guard let data = UserDefaults.standard.data(forKey: "colorTempLimits"),
              let limits = try? JSONDecoder().decode(CircadianCurve.ColorTempLimits.self, from: data) else {
            return .default
        }
        return limits
    }

    private func saveColorTempLimits() {
        if let data = try? JSONEncoder().encode(colorTempLimits) {
            UserDefaults.standard.set(data, forKey: "colorTempLimits")
        }
    }

    private static func loadElgatoLights() -> [ElgatoLight] {
        guard let data = UserDefaults.standard.data(forKey: "elgatoLights"),
              let lights = try? JSONDecoder().decode([ElgatoLight].self, from: data) else {
            // Default configuration for your setup
            return [
                ElgatoLight(id: UUID(), name: "Key Light 1", ip: "192.168.0.47", isEnabled: true),
                ElgatoLight(id: UUID(), name: "Key Light 2", ip: "192.168.0.88", isEnabled: true)
            ]
        }
        return lights
    }

    func saveElgatoLights() {
        if let data = try? JSONEncoder().encode(elgatoLights) {
            UserDefaults.standard.set(data, forKey: "elgatoLights")
        }
    }

    private static func loadHueLights() -> [HueLight] {
        guard let data = UserDefaults.standard.data(forKey: "hueLights"),
              let lights = try? JSONDecoder().decode([HueLight].self, from: data) else {
            return []
        }
        return lights
    }

    func saveHueLights() {
        if let data = try? JSONEncoder().encode(hueLights) {
            UserDefaults.standard.set(data, forKey: "hueLights")
        }
    }

    // MARK: - Hue Bridge

    /// Authenticate with the Hue bridge. User must press bridge button first.
    func authenticateHue() async -> Bool {
        hueConnectionStatus = .connecting

        if let username = await hueService.authenticate(bridgeIP: hueBridgeIP) {
            hueUsername = username
            hueConnectionStatus = .connected

            // Fetch available lights
            hueLights = await hueService.fetchLights(bridgeIP: hueBridgeIP, username: username)
            saveHueLights()

            return true
        } else {
            hueConnectionStatus = .error
            return false
        }
    }

    /// Disconnect from Hue bridge
    func disconnectHue() {
        hueUsername = ""
        hueConnectionStatus = .disconnected
        hueLights = []
        saveHueLights()
    }

    /// Refresh the list of Hue lights from the bridge
    func refreshHueLights() async {
        guard !hueUsername.isEmpty else { return }

        hueLights = await hueService.fetchLights(bridgeIP: hueBridgeIP, username: hueUsername)
        saveHueLights()
    }

    /// Test connection to a single Elgato light
    func testElgatoLight(ip: String) async -> Bool {
        await elgatoService.isReachable(ip: ip)
    }

    /// Turn an Elgato light on or off
    func setElgatoLightOnOff(ip: String, on: Bool) async -> Bool {
        await elgatoService.setOnOff(ip: ip, on: on)
    }

    /// Turn a Hue light on or off
    func setHueLightOnOff(lightId: String, on: Bool) async -> Bool {
        guard !hueUsername.isEmpty else { return false }
        return await hueService.setOnOff(
            bridgeIP: hueBridgeIP,
            username: hueUsername,
            lightId: lightId,
            on: on
        )
    }
}

// MARK: - Connection Status

enum ConnectionStatus: String {
    case disconnected = "Disconnected"
    case connecting = "Connecting..."
    case connected = "Connected"
    case error = "Error"
}
