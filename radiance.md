# Radiance-Based Brightness Control

## Overview

Replace the current time-based brightness calculation with a radiance-based system that uses actual solar radiation data from Open-Meteo to determine appropriate key light brightness levels.

## Problem Statement

The current implementation calculates brightness primarily from solar position (time of day), with radiation data only having 30% influence. This produces inappropriate brightness levels:

- **Current behavior:** Overcast December midday → ~76% brightness
- **Desired behavior:** Overcast December midday → ~8-10% brightness
- **Sunny summer midday:** Should remain at ~100%

## Calibration Data

Real-world testing established these targets:

| Condition | Radiation (W/m²) | Diffuse Ratio | Target Brightness |
|-----------|------------------|---------------|-------------------|
| Summer sunny | ~900 | ~11% | ~100% |
| Winter overcast | ~167 | ~51% | ~8-10% |

## Algorithm

### Core Formula

```swift
brightness = min + (curveValue × range)

where:
  curveValue = pow(radiationNorm, 1.5) × overcastDamping × indoorFactor × dayFactor
```

### Components

#### 1. Radiation Normalization
```swift
let radiationNorm = min(1.0, max(0, currentRadiation / 1000.0))
```
- 1000 W/m² = reference maximum (bright sunny day)
- Clamp to 0-1 range

#### 2. Power Curve (Perceptual Scaling)
```swift
let radiationCurve = pow(radiationNorm, 1.5)
```
- Exponent of 1.5 provides non-linear scaling that matches human brightness perception
- Low radiation (0.167) → 0.068 (drops faster than linear)
- High radiation (0.9) → 0.85 (stays high)

#### 3. Overcast Damping (Diffuse Ratio)
```swift
let diffuseRatio = currentDiffuseRadiation / max(1, currentRadiation)
let overcastDamping = 1.0 - (min(1.0, diffuseRatio) × 0.7)
```
- Diffuse ratio > 0.7 indicates overcast conditions
- Maximum 70% reduction when fully overcast (100% diffuse)
- Clear sky (10% diffuse) → damping = 0.93 (minimal effect)
- Overcast (51% diffuse) → damping = 0.64

#### 4. Indoor Factor (User Configurable)
```swift
let indoorFactor: Double  // Range: 0.5 to 2.0, default 1.3
```
- Accounts for window position and room lighting conditions
- 1.3 = window behind user (needs fill light to match background)
- 1.0 = neutral indoor position
- 0.5 = dark room, minimal ambient light

#### 5. Day Factor (Transition Smoothing)
```swift
let dayFactor: Double
if progress < 0 {
    // Before sunrise - fade in
    dayFactor = max(0, 1 + progress × 2)
} else if progress > 1 {
    // After sunset - fade out
    dayFactor = max(0, 1 - (progress - 1) × 2)
} else {
    // Daytime - full effect
    dayFactor = 1.0
}
```
- Provides smooth transitions at dawn/dusk
- During night, falls back to minimum brightness

### Complete Calculation

```swift
static func radianceBasedBrightness(
    progress: Double,
    min: Int,
    max: Int,
    radiation: Double,           // W/m² from WeatherService
    diffuseRadiation: Double,    // W/m² from WeatherService
    indoorFactor: Double = 1.3
) -> Int {
    // 1. Normalize radiation (0-1)
    let radiationNorm = Swift.min(1.0, Swift.max(0, radiation / 1000.0))

    // 2. Apply power curve for perceptual scaling
    let radiationCurve = pow(radiationNorm, 1.5)

    // 3. Calculate overcast damping from diffuse ratio
    let diffuseRatio = radiation > 1 ? diffuseRadiation / radiation : 1.0
    let overcastDamping = 1.0 - (Swift.min(1.0, diffuseRatio) * 0.7)

    // 4. Calculate day factor for dawn/dusk transitions
    let dayFactor: Double
    if progress < 0 {
        dayFactor = Swift.max(0, 1 + progress * 2)
    } else if progress > 1 {
        dayFactor = Swift.max(0, 1 - (progress - 1) * 2)
    } else {
        dayFactor = 1.0
    }

    // 5. Combine all factors
    var curveValue = radiationCurve * overcastDamping * indoorFactor * dayFactor

    // 6. Clamp to valid range
    curveValue = Swift.min(1.0, Swift.max(0, curveValue))

    // 7. Map to brightness range
    let range = Double(max - min)
    let brightness = Double(min) + (curveValue * range)

    return Int(brightness.rounded())
}
```

## Expected Results

| Condition | Radiation | Diffuse% | radiationCurve | overcastDamping | curveValue | Brightness |
|-----------|-----------|----------|----------------|-----------------|------------|------------|
| Summer sunny | 900 | 11% | 0.85 | 0.92 | 1.02→1.0 | **100%** |
| Partly cloudy | 500 | 35% | 0.35 | 0.76 | 0.35 | **38%** |
| Winter overcast | 167 | 51% | 0.068 | 0.64 | 0.057 | **9%** |
| Heavy overcast | 80 | 90% | 0.023 | 0.37 | 0.011 | **5%** |
| Night | 0 | - | 0 | - | 0 | **4% (min)** |

## Implementation Changes

### 1. WeatherService.swift

Add property to expose diffuse radiation for brightness calculation:

```swift
// Add to WeatherService class (around line 17)
@Published var currentDiffuseRadiation: Double = 0  // Already exists, just ensure it's published

// Add computed property for diffuse ratio
var diffuseRatio: Double {
    guard currentRadiation > 1 else { return 1.0 }
    return currentDiffuseRadiation / currentRadiation
}
```

### 2. CircadianCurve.swift

#### A. Add Indoor Factor to BrightnessLimits

```swift
// Modify BrightnessLimits struct (around line 11)
struct BrightnessLimits: Codable, Equatable {
    var hueMax: Int = 100
    var hueMin: Int = 60
    var elgatoMax: Int = 100
    var elgatoMin: Int = 4
    var indoorFactor: Double = 1.3      // NEW: 0.5-2.0, default 1.3
    var useRadianceMode: Bool = true    // NEW: toggle for new algorithm

    static let `default` = BrightnessLimits()
}
```

#### B. Add New Brightness Function

Add after existing `brightness()` function (around line 156):

```swift
/// Calculate brightness based on actual solar radiation (radiance mode)
/// Uses power curve scaling for perceptual accuracy
static func radianceBrightness(
    progress: Double,
    min: Int,
    max: Int,
    radiation: Double,
    diffuseRadiation: Double,
    indoorFactor: Double = 1.3
) -> Int {
    // Normalize radiation (1000 W/m² = reference max)
    let radiationNorm = Swift.min(1.0, Swift.max(0, radiation / 1000.0))

    // Power curve for perceptual scaling
    let radiationCurve = pow(radiationNorm, 1.5)

    // Overcast damping from diffuse ratio
    let diffuseRatio = radiation > 1 ? diffuseRadiation / radiation : 1.0
    let overcastDamping = 1.0 - (Swift.min(1.0, diffuseRatio) * 0.7)

    // Day factor for dawn/dusk transitions
    let dayFactor: Double
    if progress < 0 {
        dayFactor = Swift.max(0, 1 + progress * 2)
    } else if progress > 1 {
        dayFactor = Swift.max(0, 1 - (progress - 1) * 2)
    } else {
        dayFactor = 1.0
    }

    // Combine factors
    var curveValue = radiationCurve * overcastDamping * indoorFactor * dayFactor
    curveValue = Swift.min(1.0, Swift.max(0, curveValue))

    // Map to brightness range
    let range = Double(max - min)
    let brightness = Double(min) + (curveValue * range)

    return Int(brightness.rounded())
}

/// Elgato brightness using radiance mode
static func elgatoRadianceBrightness(
    progress: Double,
    limits: BrightnessLimits,
    radiation: Double,
    diffuseRadiation: Double
) -> Int {
    radianceBrightness(
        progress: progress,
        min: limits.elgatoMin,
        max: limits.elgatoMax,
        radiation: radiation,
        diffuseRadiation: diffuseRadiation,
        indoorFactor: limits.indoorFactor
    )
}

/// Hue brightness using radiance mode
static func hueRadianceBrightness(
    progress: Double,
    limits: BrightnessLimits,
    radiation: Double,
    diffuseRadiation: Double
) -> Int {
    radianceBrightness(
        progress: progress,
        min: limits.hueMin,
        max: limits.hueMax,
        radiation: radiation,
        diffuseRadiation: diffuseRadiation,
        indoorFactor: limits.indoorFactor
    )
}
```

### 3. AppState.swift

#### A. Update brightness calculation in updateCurrentValues()

Replace the brightness calculation section (around line 200-218):

```swift
// Calculate brightness
if useCurveBasedBrightness {
    if brightnessLimits.useRadianceMode && weatherAdjustmentEnabled {
        // NEW: Radiance-based brightness using actual radiation data
        currentHueBrightness = CircadianCurve.hueRadianceBrightness(
            progress: currentDayProgress,
            limits: brightnessLimits,
            radiation: currentRadiation,
            diffuseRadiation: weatherService.currentDiffuseRadiation
        )

        currentElgatoBrightness = CircadianCurve.elgatoRadianceBrightness(
            progress: currentDayProgress,
            limits: brightnessLimits,
            radiation: currentRadiation,
            diffuseRadiation: weatherService.currentDiffuseRadiation
        )
    } else {
        // Original curve-based brightness
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
    }
} else {
    // Legacy fixed schedule
    let (hueBrightness, elgatoBrightness) = brightnessSchedule.brightnessForCurrentTime()
    currentHueBrightness = hueBrightness
    currentElgatoBrightness = elgatoBrightness
}
```

### 4. SettingsView.swift - Curves Tab

Add controls for the new settings in the Curves tab:

```swift
// Add in the Curves tab section, after existing brightness limit sliders

Section("Radiance Mode") {
    Toggle("Use Radiance-Based Brightness", isOn: $appState.brightnessLimits.useRadianceMode)
        .help("Calculate brightness from actual solar radiation instead of time of day")

    if appState.brightnessLimits.useRadianceMode {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Indoor Factor")
                Spacer()
                Text(String(format: "%.1f", appState.brightnessLimits.indoorFactor))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $appState.brightnessLimits.indoorFactor, in: 0.5...2.0, step: 0.1)
            Text("Higher = brighter lights (use ~1.3 if window behind you)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        // Current readings display
        GroupBox("Current Conditions") {
            LabeledContent("Radiation", value: "\(Int(appState.currentRadiation)) W/m²")
            LabeledContent("Diffuse Ratio", value: String(format: "%.0f%%", appState.weatherService.diffuseRatio * 100))
            LabeledContent("Calculated Elgato", value: "\(appState.currentElgatoBrightness)%")
        }
        .font(.caption)
    }
}
```

### 5. Update 24-Hour Preview (Optional Enhancement)

Update `generate24HourPreview()` to use radiance mode when enabled:

```swift
// In CircadianCurve.generate24HourPreview(), around line 296-306
// Add parameters for radiance mode

let elgatoBri: Int
let hueBri: Int

if brightnessLimits.useRadianceMode, let radiation = hourlyRadiation[hour] {
    let diffuse = hourlyDiffuseRadiation[hour] ?? radiation * 0.5
    elgatoBri = elgatoRadianceBrightness(
        progress: progress,
        limits: brightnessLimits,
        radiation: radiation,
        diffuseRadiation: diffuse
    )
    hueBri = hueRadianceBrightness(
        progress: progress,
        limits: brightnessLimits,
        radiation: radiation,
        diffuseRadiation: diffuse
    )
} else {
    elgatoBri = elgatoBrightness(progress: progress, limits: brightnessLimits, radiationFactor: normalizedRadiation)
    hueBri = hueBrightness(progress: progress, limits: brightnessLimits, radiationFactor: normalizedRadiation)
}
```

This requires adding `hourlyDiffuseRadiation` to WeatherService similar to existing `hourlyRadiation`.

## Testing Checklist

1. **Build and run** - verify no compilation errors
2. **Enable radiance mode** in Settings > Curves
3. **Check current brightness** matches expected for conditions
4. **Adjust indoor factor** - verify slider affects brightness in real-time
5. **Toggle radiance mode off** - verify original behavior restored
6. **Test at different times** - dawn/dusk transitions should be smooth
7. **Test with weather disabled** - should fall back to curve-based

## Verification Scenarios

| Test | Radiation | Expected Elgato | Pass Criteria |
|------|-----------|-----------------|---------------|
| Sunny day mock | Set 900 W/m² | ~95-100% | Close to max |
| Overcast mock | Set 167 W/m² | ~8-12% | Low brightness |
| Night | Set 0 W/m² | 4% (min) | At minimum |
| Indoor factor 0.5 | Current | ~50% of default | Reduced |
| Indoor factor 2.0 | Current | ~150% of default | Increased |

## Migration Notes

- `useRadianceMode` defaults to `true` for new installs
- Existing users keep their settings (may need to enable manually)
- `indoorFactor` defaults to 1.3 (window-behind scenario)
- Original brightness calculation remains available via toggle
