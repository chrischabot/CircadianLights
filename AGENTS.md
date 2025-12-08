# CircadianLights

A macOS menu bar app that automatically adjusts smart light color temperature based on sunrise/sunset times.

## Project Overview

- **Platform**: macOS 14.0+
- **Build System**: Swift Package Manager (not Xcode)
- **Swift Version**: Swift 6 with strict concurrency
- **UI Framework**: SwiftUI with AppKit integration for menu bar

## Building & Running

```bash
swift build                    # Build the project
swift build -c release         # Release build
.build/debug/CircadianLights   # Run the debug build
```

## Project Structure

```
Sources/
├── CircadianLightsApp.swift      # App entry, AppDelegate, NSStatusItem, NSPopover
├── Info.plist                    # Bundle config, network entitlements
├── Models/
│   ├── AppState.swift            # Main state container (@MainActor ObservableObject)
│   ├── BrightnessSchedule.swift  # Legacy time-slot brightness (kept for backwards compat)
│   ├── CircadianCurve.swift      # Sigmoid-cosine math for smooth lighting curves
│   └── LightDevices.swift        # HueLight, ElgatoLight models
├── Services/
│   ├── ElgatoService.swift       # HTTP API control for Elgato Key Lights
│   ├── HueService.swift          # REST API control for Philips Hue
│   ├── LocationService.swift     # IP geolocation, CLGeocoder city search
│   ├── SolarService.swift        # Sunrise/sunset calculations
│   └── WeatherService.swift      # Open-Meteo API for cloud/radiation data
├── Utilities/
│   └── ColorTemperature.swift    # Kelvin ↔ Mirek ↔ Elgato conversions
└── Views/
    ├── MenuBarView.swift         # Popover content (quick controls)
    └── SettingsView.swift        # Settings window with tabs (includes Curves tab)
```

## Architecture

### Menu Bar Implementation
Uses `NSStatusItem` with `NSPopover` (not `MenuBarExtra`) to support:
- Left-click: Show/hide popover
- Right-click: Quick toggle on/off
- Custom icon states (sun.max.fill when enabled)

### State Management
- `AppState` is the central `@MainActor ObservableObject`
- Uses `@AppStorage` for persisted settings
- Services (`LocationService`, `SolarService`) are also `@MainActor ObservableObject`
- **Note**: Nested ObservableObject changes don't propagate to SwiftUI views - use local `@State` in views when needed

### Color Temperature
- Range: 2700K (warm/night) to 6500K (cool/day)
- **Philips Hue**: Uses mirek (1,000,000 / Kelvin), range 153-500
- **Elgato Key Light**: Uses proprietary scale 143-344

## External APIs

### Philips Hue
- Bridge discovery: `https://discovery.meethue.com/`
- Authentication: Press bridge button, POST to `/api` with `{"devicetype":"CircadianLights#macOS"}`
- Control: PUT to `/api/{username}/lights/{id}/state` with `{"ct": mirek, "bri": 1-254}`

### Elgato Key Light
- Port: 9123
- No authentication required
- GET/PUT to `http://{ip}:9123/elgato/lights`
- Payload: `{"lights":[{"on":1,"brightness":3-100,"temperature":143-344}]}`

### IP Geolocation
- Uses `ip-api.com` (free, no API key)
- Endpoint: `http://ip-api.com/json/?fields=status,lat,lon,city,regionName,country`

### City Search
- Uses Apple's `CLGeocoder.geocodeAddressString()`

## Dependencies

- **Solar** (github.com/ceeK/Solar): Sunrise/sunset calculations
- **OpenMeteoSdk** (github.com/open-meteo/sdk): Weather data (cloud cover, radiation)
- **Swift Charts** (Apple framework): 24-hour curve visualization

## Key Implementation Details

### Light Device IPs (configured in app)
- Elgato Key Light 1: 192.168.0.47
- Elgato Key Light 2: 192.168.0.88
- Philips Hue Bridge: 192.168.0.80

### Circadian Curves System

The app uses sigmoid-transformed cosine curves for smooth, natural-feeling lighting transitions based on solar position:

**Day Progress**: 0 = sunrise, 0.5 = solar noon, 1 = sunset
- Extended with 60-minute twilight zones before sunrise and after sunset
- Values <0 or >1 indicate night time

**Brightness Curve** (`CircadianCurve.brightness()`):
- Uses `sigmoidCosine()` for smooth S-curve transitions at dawn/dusk
- Configurable limits per device type (Hue vs Elgato)
- Optional radiation factor blending (up to 30% influence at peak)
- Default limits: Hue max 100%/min 60%, Elgato max 100%/min 4%

**Color Temperature Curve** (`CircadianCurve.colorTemperature()`):
- Range: 2700K (warm/night) to 6500K (cool/midday)
- Cloud boost: Up to 1000K increase for 100% cloud cover (daytime only)
- Uses power curve (cloudFactor^1.5) for natural cloud response

### Legacy Brightness Schedule (deprecated)
Time slots with separate Hue and Elgato brightness percentages:
- Morning (06:00-09:00): Hue 70%, Elgato 50%
- Day (09:00-17:00): Hue 100%, Elgato 80%
- Evening (17:00-21:00): Hue 80%, Elgato 60%
- Night (21:00-06:00): Hue 40%, Elgato 30%

Can be enabled via `useCurveBasedBrightness` toggle (curves are default).

## Swift/SwiftUI Guidelines

### Concurrency
- All shared state classes marked `@MainActor`
- Use `async/await` and `Task {}` for async work
- Use `Task.sleep(for:)` not `Task.sleep(nanoseconds:)`
- Never use `DispatchQueue.main.async` - use `@MainActor` or `await MainActor.run {}`

### SwiftUI
- Use `foregroundStyle()` not `foregroundColor()`
- Use `clipShape(.rect(cornerRadius:))` not `cornerRadius()`
- Use two-parameter `onChange(of:)` variant
- Separate view structs instead of computed properties
- Avoid `AnyView` and `GeometryReader` when possible

### Code Style
- Avoid force unwraps and force try
- Prefer Swift-native string methods (`replacing(_:with:)`)
- Use modern Foundation APIs (`URL.documentsDirectory`, `appending(path:)`)

## Current Status

### Implemented (All Phases)
- Menu bar icon with on/off state
- Right-click quick toggle
- Solar calculations for color temperature
- IP-based location detection
- City search with CLGeocoder
- Settings UI with tabs
- **Elgato Key Light control** (ElgatoService)
- **Philips Hue light control** (HueService)
- **Hue bridge authentication flow** (press button + connect)
- **Light reachability status indicators**
- **Test connection buttons for Elgato lights**
- **Weather-based adjustments** (WeatherService)
  - Uses Open-Meteo API for cloud cover AND radiation data
  - Caches weather data, refreshes every 5 minutes
  - Cloud cover boosts color temp (up to 1000K configurable)
  - Radiation data influences brightness calculations
  - Toggle in Settings to enable/disable
- **Circadian Curves System** (CircadianCurve)
  - Sigmoid-transformed cosine curves for smooth transitions
  - Configurable brightness limits (Hue/Elgato separate)
  - Configurable color temperature range and cloud boost
  - 24-hour visualization chart in Settings > Curves tab
  - Real-time preview with weather forecast data

### Cloud Cover Adjustment (Smooth Curve)
Uses `cloudFactor^1.5 * cloudBoostMax` for natural response:
| Cloud Cover | Approximate Boost (1000K max) |
|-------------|-------------------------------|
| 25% | ~125K |
| 50% | ~350K |
| 75% | ~650K |
| 100% | 1000K |

### TODO (Future)
- mDNS device discovery for auto-detecting lights
- Retry logic for failed light updates
- Graceful error handling and user notifications
- Light groups support
