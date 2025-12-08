import Foundation
import OpenMeteoSdk

/// Service for fetching weather data to adjust lighting based on conditions.
///
/// Uses Open-Meteo API to get hourly:
/// - Cloud cover (affects color temperature)
/// - Shortwave radiation (actual light levels)
/// - Direct/diffuse radiation (light quality)
///
/// Caches data and refreshes every 5 minutes minimum.
@MainActor
final class WeatherService: ObservableObject {
    // MARK: - Published State

    @Published var currentCloudCover: Int = 0           // 0-100%
    @Published var currentRadiation: Double = 0         // W/m² (shortwave)
    @Published var currentDirectRadiation: Double = 0   // W/m² (direct)
    @Published var currentDiffuseRadiation: Double = 0  // W/m² (diffuse)
    @Published var lastFetchTime: Date?
    @Published var isEnabled: Bool = true

    // Hourly forecasts for 24-hour preview
    @Published var hourlyCloudCover: [Int: Int] = [:]       // hour -> cloud cover %
    @Published var hourlyRadiation: [Int: Double] = [:]     // hour -> shortwave radiation W/m²

    // MARK: - Private State

    private var cachedHourlyData: [HourlyWeatherData] = []
    private var lastFetchLocation: (lat: Double, lon: Double)?
    private let cacheValiditySeconds: TimeInterval = 300  // 5 minutes

    struct HourlyWeatherData {
        let date: Date
        let hour: Int
        let cloudCover: Float
        let shortwaveRadiation: Float
        let directRadiation: Float
        let diffuseRadiation: Float
    }

    // MARK: - Public API

    /// Get current weather conditions
    /// Returns cached value or fetches new data if stale
    func getWeatherData(latitude: Double, longitude: Double) async {
        let needsRefresh = shouldRefresh(latitude: latitude, longitude: longitude)

        if needsRefresh {
            await fetchWeatherData(latitude: latitude, longitude: longitude)
        }

        updateCurrentValues()
    }

    /// Force refresh weather data
    func refresh(latitude: Double, longitude: Double) async {
        await fetchWeatherData(latitude: latitude, longitude: longitude)
    }

    /// Calculate color temperature adjustment based on cloud cover
    /// Returns a Kelvin offset to add to base temperature (positive = cooler)
    /// Uses smooth curve instead of step function
    func cloudCoverAdjustment(maxBoost: Int = 1000) -> Int {
        guard isEnabled else { return 0 }

        // Smooth curve: cloudFactor^1.5 gives more gradual response
        let cloudFactor = Double(currentCloudCover) / 100.0
        let adjustment = pow(cloudFactor, 1.5) * Double(maxBoost)

        return Int(adjustment.rounded())
    }

    /// Get normalized radiation factor (0-1) for brightness calculations
    /// 1.0 = bright sunny day (~1000 W/m²), 0 = no radiation
    var normalizedRadiation: Double {
        min(1.0, max(0, currentRadiation / 1000.0))
    }

    /// Human-readable description of current cloud cover
    var cloudCoverDescription: String {
        switch currentCloudCover {
        case 0..<20:
            return "Clear"
        case 20..<40:
            return "Partly Cloudy"
        case 40..<60:
            return "Mostly Cloudy"
        case 60..<80:
            return "Cloudy"
        case 80...100:
            return "Overcast"
        default:
            return "Unknown"
        }
    }

    /// Human-readable description of radiation level
    var radiationDescription: String {
        switch currentRadiation {
        case 0..<50:
            return "Dark"
        case 50..<200:
            return "Low Light"
        case 200..<500:
            return "Moderate"
        case 500..<800:
            return "Bright"
        case 800...:
            return "Very Bright"
        default:
            return "Unknown"
        }
    }

    // MARK: - Private Methods

    private func shouldRefresh(latitude: Double, longitude: Double) -> Bool {
        guard let lastFetch = lastFetchTime,
              let lastLocation = lastFetchLocation else {
            return true
        }

        // Refresh if cache is older than 5 minutes
        if Date().timeIntervalSince(lastFetch) > cacheValiditySeconds {
            return true
        }

        // Refresh if location changed significantly (more than ~10km)
        let latDiff = abs(latitude - lastLocation.lat)
        let lonDiff = abs(longitude - lastLocation.lon)
        if latDiff > 0.1 || lonDiff > 0.1 {
            return true
        }

        return false
    }

    private func fetchWeatherData(latitude: Double, longitude: Double) async {
        // Request cloud cover AND radiation data
        let urlString = """
            https://api.open-meteo.com/v1/forecast?\
            latitude=\(latitude)&\
            longitude=\(longitude)&\
            hourly=cloud_cover,shortwave_radiation,direct_radiation,diffuse_radiation&\
            forecast_days=1&\
            format=flatbuffers
            """.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: " ", with: "")

        guard let url = URL(string: urlString) else {
            print("[Weather] Invalid URL")
            return
        }

        do {
            let responses = try await WeatherApiResponse.fetch(url: url)

            guard let response = responses.first,
                  let hourly = response.hourly else {
                print("[Weather] No data in response")
                return
            }

            let utcOffset = response.utcOffsetSeconds
            let times = hourly.getDateTime(offset: utcOffset)

            // Get all variable arrays
            // Variables are in order: cloud_cover, shortwave_radiation, direct_radiation, diffuse_radiation
            let cloudCoverValues = hourly.variables(at: 0)?.values ?? []
            let shortwaveValues = hourly.variables(at: 1)?.values ?? []
            let directValues = hourly.variables(at: 2)?.values ?? []
            let diffuseValues = hourly.variables(at: 3)?.values ?? []

            let calendar = Calendar.current

            // Build cached data
            cachedHourlyData = zip(times.indices, times).compactMap { index, date -> HourlyWeatherData? in
                guard index < cloudCoverValues.count,
                      index < shortwaveValues.count,
                      index < directValues.count,
                      index < diffuseValues.count else {
                    return nil
                }

                let hour = calendar.component(.hour, from: date)

                return HourlyWeatherData(
                    date: date,
                    hour: hour,
                    cloudCover: cloudCoverValues[index],
                    shortwaveRadiation: shortwaveValues[index],
                    directRadiation: directValues[index],
                    diffuseRadiation: diffuseValues[index]
                )
            }

            // Build hourly lookup dictionaries for 24-hour preview
            hourlyCloudCover = [:]
            hourlyRadiation = [:]
            for data in cachedHourlyData {
                hourlyCloudCover[data.hour] = Int(data.cloudCover.rounded())
                hourlyRadiation[data.hour] = Double(data.shortwaveRadiation)
            }

            lastFetchTime = Date()
            lastFetchLocation = (latitude, longitude)

            updateCurrentValues()

            print("[Weather] Fetched \(cachedHourlyData.count) hours. Current: \(currentCloudCover)% clouds, \(Int(currentRadiation)) W/m²")
        } catch {
            print("[Weather] Failed to fetch: \(error)")
        }
    }

    private func updateCurrentValues() {
        let now = Date()

        // Find the closest hour in cached data
        var closestData: HourlyWeatherData?
        var smallestDiff: TimeInterval = .infinity

        for data in cachedHourlyData {
            let diff = abs(data.date.timeIntervalSince(now))
            if diff < smallestDiff {
                smallestDiff = diff
                closestData = data
            }
        }

        if let data = closestData {
            currentCloudCover = Int(data.cloudCover.rounded())
            currentRadiation = Double(data.shortwaveRadiation)
            currentDirectRadiation = Double(data.directRadiation)
            currentDiffuseRadiation = Double(data.diffuseRadiation)
        }
    }
}
