import Foundation

/// Utility for converting between different color temperature representations.
///
/// Color temperature can be expressed in:
/// - **Kelvin (K)**: Human-readable scale (2000K warm to 6500K+ cool)
/// - **Mirek/Mired**: Used by Philips Hue (1,000,000 / Kelvin)
/// - **Elgato value**: Similar to Mirek but different range
enum ColorTemperature {
    // MARK: - Constants

    /// Minimum Kelvin value (warmest)
    static let minimumKelvin = 2000

    /// Maximum Kelvin value (coolest)
    static let maximumKelvin = 6500

    /// Hue minimum Mirek (coolest, ~6535K)
    static let hueMinMirek = 153

    /// Hue maximum Mirek (warmest, ~2000K)
    static let hueMaxMirek = 500

    /// Elgato minimum value (coolest, 7000K)
    static let elgatoMinValue = 143

    /// Elgato maximum value (warmest, 2900K)
    static let elgatoMaxValue = 344

    // MARK: - Kelvin to Device Values

    /// Convert Kelvin to Philips Hue Mirek value
    /// - Parameter kelvin: Color temperature in Kelvin (2000-6500)
    /// - Returns: Mirek value (153-500)
    static func kelvinToMirek(_ kelvin: Int) -> Int {
        let clampedKelvin = max(minimumKelvin, min(maximumKelvin, kelvin))
        let mirek = 1_000_000 / clampedKelvin
        return max(hueMinMirek, min(hueMaxMirek, mirek))
    }

    /// Convert Kelvin to Elgato API value
    /// - Parameter kelvin: Color temperature in Kelvin (2900-7000)
    /// - Returns: Elgato temperature value (143-344)
    static func kelvinToElgato(_ kelvin: Int) -> Int {
        let clampedKelvin = max(2900, min(7000, kelvin))
        let value = Int(round(1_000_000.0 / Double(clampedKelvin)))
        return max(elgatoMinValue, min(elgatoMaxValue, value))
    }

    // MARK: - Device Values to Kelvin

    /// Convert Philips Hue Mirek to Kelvin
    /// - Parameter mirek: Mirek value (153-500)
    /// - Returns: Color temperature in Kelvin
    static func mirekToKelvin(_ mirek: Int) -> Int {
        guard mirek > 0 else { return 4000 }
        return 1_000_000 / mirek
    }

    /// Convert Elgato API value to Kelvin
    /// - Parameter value: Elgato temperature value (143-344)
    /// - Returns: Color temperature in Kelvin
    static func elgatoToKelvin(_ value: Int) -> Int {
        guard value > 0 else { return 4000 }
        return 1_000_000 / value
    }

    // MARK: - Brightness Conversions

    /// Convert percentage brightness to Hue brightness value
    /// - Parameter percent: Brightness percentage (0-100)
    /// - Returns: Hue brightness value (0-254)
    static func percentToHueBrightness(_ percent: Int) -> Int {
        let clamped = max(0, min(100, percent))
        return Int(Double(clamped) / 100.0 * 254.0)
    }

    /// Convert Hue brightness value to percentage
    /// - Parameter brightness: Hue brightness (0-254)
    /// - Returns: Brightness percentage (0-100)
    static func hueBrightnessToPercent(_ brightness: Int) -> Int {
        Int(Double(brightness) / 254.0 * 100.0)
    }

    /// Convert percentage brightness to Elgato brightness value
    /// - Parameter percent: Brightness percentage (0-100)
    /// - Returns: Elgato brightness value (3-100)
    static func percentToElgatoBrightness(_ percent: Int) -> Int {
        max(3, min(100, percent))
    }

    // MARK: - Descriptions

    /// Get a human-readable description of the color temperature
    /// - Parameter kelvin: Color temperature in Kelvin
    /// - Returns: Description string
    static func description(for kelvin: Int) -> String {
        switch kelvin {
        case ..<2500:
            return "Candlelight"
        case 2500..<3000:
            return "Warm White"
        case 3000..<4000:
            return "Soft White"
        case 4000..<5000:
            return "Cool White"
        case 5000..<5800:
            return "Daylight"
        case 5800..<6500:
            return "Bright Daylight"
        default:
            return "Cool Daylight"
        }
    }
}
