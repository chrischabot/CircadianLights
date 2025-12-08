import Foundation
import CoreLocation
import Solar

/// Service for calculating color temperature based on solar position and time of day.
///
/// Uses the Solar library for sunrise/sunset calculations and interpolates
/// color temperature throughout the day to match natural daylight.
final class SolarService: @unchecked Sendable {
    // MARK: - Properties

    private var location: CLLocationCoordinate2D

    /// Color temperature curve throughout the day (hour -> Kelvin)
    /// Based on natural daylight color temperature progression
    private let colorTemperatureCurve: [(hour: Double, kelvin: Int)] = [
        (0.0, 2700),    // Midnight - warm
        (5.0, 2700),    // Pre-dawn - warm
        (6.0, 3200),    // Dawn begins - warming up
        (7.0, 4000),    // Early morning
        (8.0, 5000),    // Morning
        (9.0, 5500),    // Mid-morning
        (12.0, 6500),   // Solar noon - peak daylight (coolest)
        (14.0, 6200),   // Early afternoon
        (16.0, 5500),   // Late afternoon
        (17.0, 4800),   // Pre-sunset
        (18.0, 4000),   // Sunset begins
        (19.0, 3200),   // Sunset
        (20.0, 2900),   // Dusk
        (21.0, 2700),   // Evening
        (24.0, 2700),   // End of day (wraps to midnight)
    ]

    // MARK: - Initialization

    /// Initialize with a default location (can be updated later)
    /// Default is San Francisco coordinates
    init(latitude: Double = 37.7749, longitude: Double = -122.4194) {
        self.location = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    // MARK: - Public Methods

    /// Update the location used for solar calculations
    func updateLocation(latitude: Double, longitude: Double) {
        self.location = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Get the current color temperature in Kelvin based on time of day
    /// - Returns: Color temperature in Kelvin (2700-6500)
    func currentColorTemperature() -> Int {
        return colorTemperature(for: Date())
    }

    /// Get the color temperature for a specific date/time
    /// - Parameter date: The date/time to calculate for
    /// - Returns: Color temperature in Kelvin
    func colorTemperature(for date: Date) -> Int {
        // Get solar data for dynamic sunrise/sunset adjustment
        let solar = Solar(for: date, coordinate: location)

        // Calculate current fractional hour
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let fractionalHour = Double(hour) + Double(minute) / 60.0

        // If we have valid solar data, adjust the curve based on actual sunrise/sunset
        if let sunrise = solar?.sunrise, let sunset = solar?.sunset {
            return adaptiveColorTemperature(
                fractionalHour: fractionalHour,
                sunrise: sunrise,
                sunset: sunset,
                referenceDate: date
            )
        }

        // Fall back to fixed curve interpolation
        return interpolateColorTemperature(for: fractionalHour)
    }

    /// Get sunrise time for today (or nil if sun doesn't rise)
    func todaySunrise() -> Date? {
        return Solar(coordinate: location)?.sunrise
    }

    /// Get sunset time for today (or nil if sun doesn't set)
    func todaySunset() -> Date? {
        return Solar(coordinate: location)?.sunset
    }

    /// Check if it's currently daytime
    func isDaytime() -> Bool {
        return Solar(coordinate: location)?.isDaytime ?? true
    }

    // MARK: - Private Methods

    /// Interpolate color temperature from the fixed curve
    private func interpolateColorTemperature(for fractionalHour: Double) -> Int {
        // Find the two points to interpolate between
        var lowerPoint = colorTemperatureCurve.first!
        var upperPoint = colorTemperatureCurve.last!

        for i in 0..<colorTemperatureCurve.count - 1 {
            let current = colorTemperatureCurve[i]
            let next = colorTemperatureCurve[i + 1]

            if fractionalHour >= current.hour && fractionalHour < next.hour {
                lowerPoint = current
                upperPoint = next
                break
            }
        }

        // Handle edge case at exactly 24.0
        if fractionalHour >= 24.0 {
            return colorTemperatureCurve.first!.kelvin
        }

        // Linear interpolation
        let range = upperPoint.hour - lowerPoint.hour
        guard range > 0 else { return lowerPoint.kelvin }

        let progress = (fractionalHour - lowerPoint.hour) / range
        let kelvinDiff = Double(upperPoint.kelvin - lowerPoint.kelvin)
        let interpolatedKelvin = Double(lowerPoint.kelvin) + (progress * kelvinDiff)

        return Int(round(interpolatedKelvin))
    }

    /// Calculate adaptive color temperature based on actual sunrise/sunset times
    private func adaptiveColorTemperature(
        fractionalHour: Double,
        sunrise: Date,
        sunset: Date,
        referenceDate: Date
    ) -> Int {
        let calendar = Calendar.current

        // Extract hours from sunrise/sunset
        let sunriseHour = Double(calendar.component(.hour, from: sunrise)) +
                          Double(calendar.component(.minute, from: sunrise)) / 60.0
        let sunsetHour = Double(calendar.component(.hour, from: sunset)) +
                         Double(calendar.component(.minute, from: sunset)) / 60.0

        // Calculate solar noon (midpoint between sunrise and sunset)
        let solarNoon = (sunriseHour + sunsetHour) / 2.0

        // Determine which phase of day we're in
        if fractionalHour < sunriseHour - 1.0 {
            // Deep night (before dawn)
            return 2700
        } else if fractionalHour < sunriseHour {
            // Dawn transition (1 hour before sunrise)
            let progress = (fractionalHour - (sunriseHour - 1.0)) / 1.0
            return Int(2700.0 + progress * 500.0) // 2700 -> 3200
        } else if fractionalHour < solarNoon {
            // Morning: sunrise to solar noon
            let progress = (fractionalHour - sunriseHour) / (solarNoon - sunriseHour)
            return Int(3200.0 + progress * 3300.0) // 3200 -> 6500
        } else if fractionalHour < sunsetHour {
            // Afternoon: solar noon to sunset
            let progress = (fractionalHour - solarNoon) / (sunsetHour - solarNoon)
            return Int(6500.0 - progress * 3500.0) // 6500 -> 3000
        } else if fractionalHour < sunsetHour + 1.0 {
            // Dusk transition (1 hour after sunset)
            let progress = (fractionalHour - sunsetHour) / 1.0
            return Int(3000.0 - progress * 300.0) // 3000 -> 2700
        } else {
            // Night
            return 2700
        }
    }
}

// MARK: - Debug/Preview Helpers

extension SolarService {
    /// Generate a preview of color temperatures throughout the day
    func dailyTemperaturePreview() -> [(hour: Int, kelvin: Int, description: String)] {
        var preview: [(hour: Int, kelvin: Int, description: String)] = []

        for hour in 0..<24 {
            let kelvin = interpolateColorTemperature(for: Double(hour))
            let description = ColorTemperature.description(for: kelvin)
            preview.append((hour: hour, kelvin: kelvin, description: description))
        }

        return preview
    }
}
