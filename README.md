# CircadianLights

*A macOS menu bar companion that teaches your smart lights to follow the sun.*

## Quick Start

```bash
swift build
.build/debug/CircadianLights
```

Click the sun icon in your menu bar. Toggle on. Your Philips Hue and Elgato Key Lights now dance to circadian rhythms.

**Requirements:** macOS 14.0+, Swift 6

## The Problem Worth Solving

Modern humans spend 90% of their time indoors, bathed in artificial light that neither knows nor cares what hour it is. Meanwhile, our biology stubbornly insists on following a 24-hour clock calibrated over millions of years of sunrise and sunset.

The disconnect is not merely philosophical. Blue-enriched light after dusk suppresses melatonin. Dim, warm light at noon signals the wrong time to our suprachiasmatic nucleus. We have, in essence, taught our bodies to be perpetually jet-lagged.

Smart lights promised salvation but delivered complexity. This application offers a simpler bargain: tell it where you are, and it will do the rest.

## What It Does

CircadianLights automatically adjusts your smart lights throughout the day:

- **Color Temperature**: 2700K (warm amber) at night, rising to 6500K (cool daylight) at solar noon
- **Brightness**: Follows solar position with configurable limits per device type
- **Weather Awareness**: Cloudy skies boost color temperature (overcast daylight is cooler than sunny daylight)
- **Twilight Transitions**: 60-minute dawn/dusk zones for gradual changes

Supported devices:
- Philips Hue (via Bridge API)
- Elgato Key Light (via direct HTTP)

## The Curves Approach

Early versions used step functions—crude time slots that produced jarring transitions. The current implementation employs **sigmoid-transformed cosine curves**, a choice born from both research and experimentation.

### Why Sigmoid-Cosine?

A pure cosine curve peaks at noon and troughs at midnight, which matches solar intuition. However, cosine transitions are too gradual at dawn and dusk—precisely when humans notice light changes most.

The sigmoid function provides an S-curve that:
1. Accelerates through the middle transition
2. Eases into the endpoints
3. Feels more natural to human perception

Composing them: `sigmoid(cosine(progress))` gives us the best of both worlds.

### Day Progress

Time is normalized to "day progress":
- `0.0` = sunrise
- `0.5` = solar noon
- `1.0` = sunset
- Values outside 0-1 indicate night (with extended twilight zones)

This solar-relative approach means the system works correctly regardless of season or latitude.

### Cloud Cover Integration

Overcast skies don't dim the world—they shift its color. Clouds scatter blue light, making outdoor illumination cooler (higher Kelvin) even as intensity drops.

The cloud boost uses a power curve (`cloudFactor^1.5`) rather than linear scaling, because light clouds barely matter while heavy overcast dramatically shifts perception.

The boost also fades during twilight: 100% at midday, 50% at sunset (some blue sky remains), 0% an hour after dark.

## Lessons Learned

**Nested ObservableObjects don't propagate.** SwiftUI's `@Published` doesn't trigger view updates through object hierarchies. The solution: flatten state or use local `@State` bindings in views.

**Hue uses mirek, not Kelvin.** Mirek = 1,000,000 / Kelvin. The valid range (153-500) inverts our intuition: lower numbers are cooler.

**Elgato's temperature scale is proprietary.** Neither Kelvin nor mirek, it maps 143-344 to roughly 7000K-2900K. Empirical testing was required.

**Weather APIs vary wildly.** Open-Meteo provides both cloud cover and shortwave radiation, allowing us to distinguish between "overcast" and "actually dark."

**Form alignment in SwiftUI requires intention.** `LabeledContent` is your friend. Fighting the form layout system is a losing battle.

## Configuration

All settings persist automatically:

| Setting | Default | Notes |
|---------|---------|-------|
| Update Interval | 60s | How often lights adjust |
| Hue Brightness | 60-100% | Min/max range |
| Elgato Brightness | 4-100% | Key Lights go very dim |
| Color Temp | 2700-6500K | Night to noon range |
| Cloud Boost | 1000K max | Additional cooling for overcast |

## Dependencies

- [Solar](https://github.com/ceeK/Solar) — Sunrise/sunset calculations
- [OpenMeteoSdk](https://github.com/open-meteo/sdk) — Weather data
- Swift Charts (Apple) — 24-hour curve visualization

## Resources Consulted

### Circadian Lighting Research
- Figueiro, M.G. et al. "The impact of light from computer monitors on melatonin levels in college students" — Established blue light suppression thresholds
- CIE Technical Report 158:2009 "Ocular Lighting Effects on Human Physiology and Behaviour"
- WELL Building Standard v2 — Circadian Lighting Feature L03

### APIs & Protocols
- [Philips Hue API Documentation](https://developers.meethue.com/develop/hue-api/)
- [Elgato Key Light Protocol](https://github.com/adamesch/elgato-key-light-api) (community-documented)
- [Open-Meteo API](https://open-meteo.com/en/docs) — Free weather data, no API key required

### Mathematical Approaches
- Petrenko, V. "Sigmoid Functions and Their Applications" — For understanding transition curves
- Solar position algorithms from NOAA Solar Calculator

### SwiftUI & macOS
- Apple's Human Interface Guidelines — Menu Bar Extras
- Swift Concurrency documentation — `@MainActor` patterns

---

*"The sun also ariseth, and the sun goeth down, and hasteth to his place where he arose."*
*— Ecclesiastes 1:5*

*Now your lights do too.*
