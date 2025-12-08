import Foundation

/// Mathematical functions for smooth circadian lighting curves.
///
/// Uses sigmoid-transformed cosine curves for natural-feeling transitions,
/// following research on circadian rhythm lighting best practices.
struct CircadianCurve {

    // MARK: - Configurable Limits

    struct BrightnessLimits: Codable, Equatable {
        var hueMax: Int = 100        // Peak brightness for Hue (%)
        var hueMin: Int = 60         // Minimum brightness for Hue at night (%)
        var elgatoMax: Int = 100     // Peak brightness for Elgato (%)
        var elgatoMin: Int = 4       // Minimum brightness for Elgato at night (%)

        static let `default` = BrightnessLimits()
    }

    struct ColorTempLimits: Codable, Equatable {
        var warmest: Int = 2700      // Warmest (night) in Kelvin
        var coolest: Int = 6500      // Coolest (peak day) in Kelvin
        var cloudBoostMax: Int = 1000 // Max Kelvin increase for 100% cloud cover

        static let `default` = ColorTempLimits()
    }

    // MARK: - Sigmoid-Transformed Cosine

    /// Sigmoid function for smooth S-curve transitions
    /// - Parameters:
    ///   - x: Input value (typically 0 to 1)
    ///   - steepness: Controls how sharp the transition is (higher = sharper)
    /// - Returns: Smoothly transformed value between 0 and 1
    static func sigmoid(_ x: Double, steepness: Double = 10) -> Double {
        1.0 / (1.0 + exp(-steepness * (x - 0.5)))
    }

    /// Normalized sigmoid that maps [0,1] -> [0,1] exactly
    static func normalizedSigmoid(_ x: Double, steepness: Double = 10) -> Double {
        let sig = sigmoid(x, steepness: steepness)
        let sigMin = sigmoid(0, steepness: steepness)
        let sigMax = sigmoid(1, steepness: steepness)
        return (sig - sigMin) / (sigMax - sigMin)
    }

    /// Cosine curve that peaks at solar noon
    /// - Parameters:
    ///   - progress: Day progress where 0 = sunrise, 0.5 = solar noon, 1 = sunset
    /// - Returns: Value from 0 (endpoints) to 1 (peak)
    static func cosineCurve(_ progress: Double) -> Double {
        // Map progress to [-π, π] so cos peaks at center
        let angle = (progress - 0.5) * 2 * .pi
        return (cos(angle) + 1) / 2
    }

    /// Sigmoid-transformed cosine for smoother dawn/dusk transitions
    /// Combines the natural shape of cosine with sigmoid smoothing
    static func sigmoidCosine(_ progress: Double, steepness: Double = 6) -> Double {
        let cosVal = cosineCurve(progress)
        return normalizedSigmoid(cosVal, steepness: steepness)
    }

    // MARK: - Solar Position Calculations

    /// Calculate day progress based on current time relative to sunrise/sunset
    /// - Parameters:
    ///   - date: Current date/time
    ///   - sunrise: Today's sunrise
    ///   - sunset: Today's sunset
    /// - Returns: Progress value: <0 = before sunrise, 0-1 = daytime, >1 = after sunset
    static func dayProgress(date: Date, sunrise: Date, sunset: Date) -> Double {
        let dayLength = sunset.timeIntervalSince(sunrise)
        guard dayLength > 0 else { return 0.5 }

        let elapsed = date.timeIntervalSince(sunrise)
        return elapsed / dayLength
    }

    /// Calculate extended day progress including twilight periods
    /// Uses 1-hour transition periods before sunrise and after sunset
    static func extendedDayProgress(
        date: Date,
        sunrise: Date,
        sunset: Date,
        transitionMinutes: Double = 60
    ) -> Double {
        let transitionSeconds = transitionMinutes * 60
        let extendedSunrise = sunrise.addingTimeInterval(-transitionSeconds)
        let extendedSunset = sunset.addingTimeInterval(transitionSeconds)
        let extendedDayLength = extendedSunset.timeIntervalSince(extendedSunrise)

        guard extendedDayLength > 0 else { return 0.5 }

        let elapsed = date.timeIntervalSince(extendedSunrise)
        return elapsed / extendedDayLength
    }

    // MARK: - Brightness Calculations

    /// Calculate brightness percentage based on solar position
    /// - Parameters:
    ///   - progress: Day progress (0 = sunrise, 0.5 = noon, 1 = sunset)
    ///   - min: Minimum brightness (%)
    ///   - max: Maximum brightness (%)
    ///   - radiationFactor: Optional adjustment based on actual radiation (0-1)
    /// - Returns: Brightness percentage
    static func brightness(
        progress: Double,
        min: Int,
        max: Int,
        radiationFactor: Double? = nil
    ) -> Int {
        // Clamp progress to valid range with smooth tails
        let clampedProgress: Double
        if progress < 0 {
            // Before sunrise - use sigmoid to smoothly approach min
            clampedProgress = 0
        } else if progress > 1 {
            // After sunset - use sigmoid to smoothly approach min
            clampedProgress = 1
        } else {
            clampedProgress = progress
        }

        // Base curve using sigmoid-cosine
        var curveValue = sigmoidCosine(clampedProgress)

        // Apply radiation factor if available (actual measured light)
        if let radiation = radiationFactor {
            // Blend between curve and actual radiation
            // Weight actual radiation more during daytime
            let radiationWeight = 0.3 * curveValue  // Up to 30% influence at peak
            curveValue = curveValue * (1 - radiationWeight) + radiation * radiationWeight
        }

        // Handle night time (outside 0-1 range)
        if progress < 0 || progress > 1 {
            // Night time - smoothly transition to minimum
            let nightProgress: Double
            if progress < 0 {
                // Hours before sunrise
                nightProgress = Swift.max(0, 1 + progress * 2) // Fade in last 30 min before sunrise zone
            } else {
                // Hours after sunset
                nightProgress = Swift.max(0, 1 - (progress - 1) * 2) // Fade out first 30 min after sunset zone
            }
            curveValue = curveValue * nightProgress
        }

        // Map curve value to brightness range
        let range = Double(max - min)
        let brightness = Double(min) + (curveValue * range)

        return Int(brightness.rounded())
    }

    /// Calculate Hue brightness with configured limits
    static func hueBrightness(
        progress: Double,
        limits: BrightnessLimits,
        radiationFactor: Double? = nil
    ) -> Int {
        brightness(progress: progress, min: limits.hueMin, max: limits.hueMax, radiationFactor: radiationFactor)
    }

    /// Calculate Elgato brightness with configured limits
    static func elgatoBrightness(
        progress: Double,
        limits: BrightnessLimits,
        radiationFactor: Double? = nil
    ) -> Int {
        brightness(progress: progress, min: limits.elgatoMin, max: limits.elgatoMax, radiationFactor: radiationFactor)
    }

    // MARK: - Color Temperature Calculations

    /// Calculate color temperature based on solar position
    /// - Parameters:
    ///   - progress: Day progress (0 = sunrise, 0.5 = noon, 1 = sunset)
    ///   - limits: Color temperature limits
    ///   - cloudCover: Cloud cover percentage (0-100)
    /// - Returns: Color temperature in Kelvin
    static func colorTemperature(
        progress: Double,
        limits: ColorTempLimits,
        cloudCover: Int = 0
    ) -> Int {
        // Base color temp curve - warm at edges, cool at center
        let curveValue: Double

        if progress < 0 || progress > 1 {
            // Night time - warmest
            curveValue = 0
        } else {
            curveValue = sigmoidCosine(progress)
        }

        // Map curve to temperature range
        let range = Double(limits.coolest - limits.warmest)
        var kelvin = Double(limits.warmest) + (curveValue * range)

        // Apply cloud cover boost - fades out during twilight
        if cloudCover > 0 {
            // Cloud boost follows a curve - more effect at higher cloud cover
            let cloudFactor = Double(cloudCover) / 100.0
            // Use power curve for more natural feel (light clouds = small effect)
            let cloudBoost = pow(cloudFactor, 1.5) * Double(limits.cloudBoostMax)

            // Calculate daylight factor that fades during twilight
            // Full boost when progress 0.1-0.9, fades at edges
            let daylightFactor: Double
            if progress < 0 {
                // Before sunrise - no boost
                daylightFactor = 0
            } else if progress < 0.1 {
                // Dawn twilight - fade in from 0 to 100%
                daylightFactor = progress / 0.1
            } else if progress <= 0.9 {
                // Full daytime - 100% boost
                daylightFactor = 1.0
            } else if progress <= 1.0 {
                // Dusk twilight - fade from 100% to 50%
                let twilightProgress = (progress - 0.9) / 0.1  // 0 to 1
                daylightFactor = 1.0 - (twilightProgress * 0.5)  // 1.0 to 0.5
            } else if progress <= 1.5 {
                // After sunset twilight - fade from 50% to 0%
                let afterSunsetProgress = (progress - 1.0) / 0.5  // 0 to 1
                daylightFactor = 0.5 * (1.0 - afterSunsetProgress)  // 0.5 to 0
            } else {
                // Full night - no boost
                daylightFactor = 0
            }

            // Also scale by curve value so boost is lower at dawn/dusk
            kelvin += cloudBoost * daylightFactor * curveValue
        }

        // Clamp to reasonable range
        return Int(min(7500, max(Double(limits.warmest), kelvin)).rounded())
    }

    // MARK: - 24-Hour Preview Generation

    struct HourlyPreview: Identifiable {
        let id = UUID()
        let hour: Int
        let date: Date
        let colorTemp: Int
        let hueBrightness: Int
        let elgatoBrightness: Int
        let isDaytime: Bool
        let cloudCover: Int
        let radiation: Double?
    }

    /// Generate 24-hour preview data for visualization
    static func generate24HourPreview(
        sunrise: Date,
        sunset: Date,
        brightnessLimits: BrightnessLimits,
        colorTempLimits: ColorTempLimits,
        hourlyCloudCover: [Int: Int] = [:],  // hour -> cloud cover %
        hourlyRadiation: [Int: Double] = [:] // hour -> normalized radiation (0-1)
    ) -> [HourlyPreview] {
        var previews: [HourlyPreview] = []

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        for hour in 0..<24 {
            guard let hourDate = calendar.date(byAdding: .hour, value: hour, to: today) else {
                continue
            }

            let progress = extendedDayProgress(
                date: hourDate,
                sunrise: sunrise,
                sunset: sunset,
                transitionMinutes: 60
            )

            let isDaytime = progress >= 0 && progress <= 1
            let cloudCover = hourlyCloudCover[hour] ?? 0
            let radiation = hourlyRadiation[hour]

            // Normalize radiation if present (typical peak ~1000 W/m²)
            let normalizedRadiation = radiation.map { min(1.0, $0 / 1000.0) }

            let colorTemp = colorTemperature(
                progress: progress,
                limits: colorTempLimits,
                cloudCover: cloudCover  // Let colorTemperature handle daylight fading
            )

            let hueBri = hueBrightness(
                progress: progress,
                limits: brightnessLimits,
                radiationFactor: normalizedRadiation
            )

            let elgatoBri = elgatoBrightness(
                progress: progress,
                limits: brightnessLimits,
                radiationFactor: normalizedRadiation
            )

            previews.append(HourlyPreview(
                hour: hour,
                date: hourDate,
                colorTemp: colorTemp,
                hueBrightness: hueBri,
                elgatoBrightness: elgatoBri,
                isDaytime: isDaytime,
                cloudCover: cloudCover,
                radiation: radiation
            ))
        }

        return previews
    }
}
