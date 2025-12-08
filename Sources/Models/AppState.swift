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

            // Calculate cloud adjustment based on configured max
            cloudAdjustment = weatherService.cloudCoverAdjustment(maxBoost: colorTempLimits.cloudBoostMax)
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

        currentColorTemperature = kelvin

        // Calculate brightness using smooth curves
        if useCurveBasedBrightness {
            currentHueBrightness = CircadianCurve.hueBrightness(
                progress: currentDayProgress,
                limits: brightnessLimits,
                radiationFactor: radiationFactor
            )

            currentElgatoBrightness = CircadianCurve.elgatoBrightness(
                progress: currentDayProgress,
                limits: brightnessLimits,
                radiationFactor: radiationFactor
            )
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
