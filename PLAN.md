# CircadianLights - macOS Menu Bar Application

A Swift 6 macOS menu bar application that synchronizes Philips Hue and Elgato Key Light color temperatures with natural daylight cycles, providing circadian-appropriate lighting for video calls.

## Table of Contents

1. [Overview](#overview)
2. [Technical Research](#technical-research)
3. [Architecture](#architecture)
4. [Implementation Phases](#implementation-phases)
5. [API Documentation](#api-documentation)
6. [Device Configuration](#device-configuration)
7. [Sources](#sources)

---

## Overview

### Problem Statement

When on video calls with a window behind you, mismatched lighting color temperature creates an unnatural appearance. If the ambient daylight is warm (sunset) but your key lights are cool (daylight), the lighting looks artificial and unflattering.

### Solution

CircadianLights automatically adjusts connected smart lights to match the natural color temperature of daylight throughout the day, based on sunrise/sunset calculations for your location. It also provides time-based brightness scheduling so lights can be dimmer at night.

### Features

- **Menu bar icon** with on/off toggle state
- **Automatic color temperature** matching based on solar position
- **Time-based brightness scheduling** for Hue and Elgato lights independently
- **Device discovery** for both Philips Hue and Elgato Key Lights
- **Manual device configuration** with IP address entry
- **Right-click menu** for quick access to settings
- **Launch at login** support

---

## Technical Research

### macOS Menu Bar Apps (Swift 6 / SwiftUI)

#### MenuBarExtra (macOS 13+)

With macOS 13 Ventura, Apple introduced `MenuBarExtra` for native SwiftUI menu bar apps. This replaces the older `NSStatusItem` approach for pure SwiftUI apps.

```swift
@main
struct CircadianLightsApp: App {
    var body: some Scene {
        MenuBarExtra {
            ContentView()
        } label: {
            Image(systemName: "sun.max.fill")
        }
        .menuBarExtraStyle(.window)  // Popover style

        Settings {
            SettingsView()
        }
    }
}
```

#### Key Configuration

**Info.plist entries:**
- `LSUIElement = YES` - Makes app an "agent" (no dock icon)
- `NSBonjourServices` - Array of Bonjour service types for discovery
- `NSLocalNetworkUsageDescription` - Required for local network access

#### Settings Window Challenge

As of macOS 14 Sonoma, `NSApp.sendAction` with `showSettingsWindow:` no longer works. Must use `SettingsLink` or `@Environment(\.openSettings)`.

For MenuBarExtra apps, opening settings requires:
```swift
@Environment(\.openSettings) var openSettings

Button("Settings...") {
    openSettings()
    NSApp.activate(ignoringOtherApps: true)  // Bring to front
}
```

### Color Temperature Science

#### Kelvin Scale

| Temperature | Description | Use Case |
|-------------|-------------|----------|
| 2000K | Candlelight | Very warm, relaxing |
| 2700K | Incandescent bulb | Warm, cozy |
| 3000K | Warm white LED | Residential |
| 4000K | Cool white | Office lighting |
| 5000K | Daylight | Neutral |
| 5600K | Midday sun | Photography |
| 6500K | Overcast sky | Cool, alert |
| 7000K+ | Blue sky | Very cool |

#### Natural Daylight Progression

| Time of Day | Approximate Kelvin |
|-------------|-------------------|
| Sunrise | 2000-3000K |
| Early morning | 3500-4500K |
| Mid-morning | 5000-5500K |
| Solar noon | 5600-6500K |
| Afternoon | 5500-6000K |
| Late afternoon | 4500-5000K |
| Sunset | 2500-3500K |
| Dusk | 2700-3000K |
| Night | 2700K (artificial) |

#### Circadian Rhythm Impact

- **Warm light (2700-3000K)**: Promotes melatonin production, signals rest
- **Cool light (5000-6500K)**: Suppresses melatonin, promotes alertness
- **Blue light content** increases with higher Kelvin values

### Sunrise/Sunset Calculation

#### Solar Library (Swift)

The [Solar](https://github.com/ceeK/Solar) library provides local sunrise/sunset calculations using NOAA algorithms. No network required.

```swift
import Solar
import CoreLocation

let coordinate = CLLocationCoordinate2D(latitude: 51.5, longitude: -0.1)
let solar = Solar(coordinate: coordinate)

let sunrise = solar?.sunrise  // Date?
let sunset = solar?.sunset    // Date?
let isDaytime = solar?.isDaytime  // Bool
```

**Calculation Types:**
- **Official** (~0°): Standard sunrise/sunset
- **Civil** (6° below): Civil twilight
- **Nautical** (12° below): Maritime navigation
- **Astronomical** (18° below): Full darkness

### Swift 6 Concurrency

Swift 6 enforces strict concurrency checking by default.

#### Key Concepts

- **Actors**: Thread-safe isolation for mutable state
- **@MainActor**: UI updates must be on main thread
- **Sendable**: Types that can safely cross concurrency boundaries
- **async/await**: Structured concurrency

```swift
actor LightService {
    private var lights: [Light] = []

    func updateLight(_ light: Light) async throws {
        // Actor-isolated, thread-safe
    }
}

@MainActor
class AppState: ObservableObject {
    @Published var isEnabled = false
    // All UI state updates are main-actor isolated
}
```

### Launch at Login (macOS 13+)

Use `SMAppService` for modern login item management:

```swift
import ServiceManagement

// Register
try SMAppService.mainApp.register()

// Unregister
try SMAppService.mainApp.unregister()

// Check status
let isEnabled = SMAppService.mainApp.status == .enabled
```

---

## Architecture

### Project Structure

```
CircadianLights/
├── CircadianLightsApp.swift      # App entry point with MenuBarExtra
├── Models/
│   ├── LightDevice.swift         # Protocol for light devices
│   ├── HueLight.swift            # Philips Hue light model
│   ├── HueBridge.swift           # Hue bridge connection
│   ├── ElgatoLight.swift         # Elgato Key Light model
│   ├── BrightnessSchedule.swift  # Time-based brightness config
│   └── AppSettings.swift         # Persisted settings
├── Services/
│   ├── SolarService.swift        # Sunrise/sunset calculations
│   ├── HueService.swift          # Hue API client
│   ├── ElgatoService.swift       # Elgato API client
│   ├── DiscoveryService.swift    # Bonjour/mDNS discovery
│   └── LightOrchestrator.swift   # Coordinates light updates
├── Views/
│   ├── MenuBarView.swift         # Main menu bar popover
│   ├── SettingsView.swift        # Settings window
│   ├── DevicesTab.swift          # Device configuration
│   ├── ScheduleTab.swift         # Brightness schedule
│   └── Components/
│       ├── LightStatusRow.swift
│       ├── TimeSlotEditor.swift
│       └── ColorTempPreview.swift
└── Utilities/
    ├── ColorTemperature.swift    # Kelvin conversions
    └── NetworkClient.swift       # Async HTTP helpers
```

### Data Flow

```
┌─────────────────┐
│  SolarService   │ ─── Calculates color temp based on time/location
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│LightOrchestrator│ ─── Combines solar data + brightness schedule
└────────┬────────┘
         │
    ┌────┴────┐
    ▼         ▼
┌───────┐ ┌────────┐
│HueSvc │ │ElgatoSvc│ ─── Send commands to devices
└───────┘ └────────┘
```

### State Management

```swift
@MainActor
class AppState: ObservableObject {
    // UI State
    @Published var isEnabled: Bool = false
    @Published var currentColorTemp: Int = 4000
    @Published var currentHueBrightness: Int = 100
    @Published var currentElgatoBrightness: Int = 100

    // Device State
    @Published var hueLights: [HueLight] = []
    @Published var elgatoLights: [ElgatoLight] = []
    @Published var hueConnectionStatus: ConnectionStatus = .disconnected

    // Settings (persisted)
    @AppStorage("hueBridgeIP") var hueBridgeIP = ""
    @AppStorage("hueUsername") var hueUsername = ""

    // Services
    let orchestrator: LightOrchestrator
    let solarService: SolarService
}
```

---

## Implementation Phases

### Phase 1: Foundation

**Goals:**
- Create Xcode project with proper configuration
- Implement MenuBarExtra with on/off toggle
- Set up Solar library for sunrise/sunset
- Create color temperature calculation logic
- Basic data models

**Deliverables:**
- Working menu bar icon that toggles state
- Console output showing calculated color temperature
- Project structure established

### Phase 2: Device Integration

**Goals:**
- Implement Elgato Key Light REST API client
- Test with lights at 192.168.0.47 and 192.168.0.88
- Implement Philips Hue authentication flow
- Connect to bridge at 192.168.0.80
- Create NWBrowser-based discovery for Elgato

**Deliverables:**
- Can control Elgato lights (on/off, brightness, temperature)
- Can authenticate with Hue bridge
- Can control Hue lights
- Device discovery working

### Phase 3: UI & Configuration

**Goals:**
- Build settings window with tabs
- Create brightness schedule editor
- Implement device configuration views
- Add manual IP entry for devices

**Deliverables:**
- Full settings UI
- Editable brightness schedule
- Device management interface

### Phase 4: Orchestration

**Goals:**
- Implement LightOrchestrator with async update loop
- Integrate brightness schedule with updates
- Add proper error handling
- Implement retry logic for failed updates

**Deliverables:**
- Automatic light updates every minute
- Brightness varies by time of day
- Graceful handling of offline devices

### Phase 5: Polish

**Goals:**
- Add Launch at Login via SMAppService
- Improve error states and user feedback
- Add status indicators in menu
- Test edge cases thoroughly

**Deliverables:**
- Production-ready application
- Reliable operation
- Good user experience

---

## API Documentation

### Philips Hue API

#### Discovery

**Option 1: Broker Service**
```
GET https://discovery.meethue.com
Response: [{"id":"xxx","internalipaddress":"192.168.0.80"}]
```

**Option 2: mDNS**
Service type: `_hue._tcp`

#### Authentication

```
POST http://<bridge_ip>/api
Body: {"devicetype":"circadian_lights#macos"}
```

First call returns error 101 (link button not pressed). User must press bridge button, then retry. Success returns:
```json
[{"success":{"username":"generated-username-string"}}]
```

#### Get All Lights

```
GET http://<bridge_ip>/api/<username>/lights
```

Response:
```json
{
  "1": {
    "state": {
      "on": true,
      "bri": 254,
      "ct": 366,
      "colormode": "ct",
      "reachable": true
    },
    "name": "Living Room"
  }
}
```

#### Set Light State

```
PUT http://<bridge_ip>/api/<username>/lights/<id>/state
Content-Type: application/json

{
  "on": true,
  "bri": 254,
  "ct": 366
}
```

#### Parameters

| Parameter | Range | Description |
|-----------|-------|-------------|
| `on` | true/false | Power state |
| `bri` | 0-254 | Brightness (0=off, 254=max) |
| `ct` | 153-500 | Color temp in Mirek |
| `transitiontime` | 0-65535 | Transition in 100ms units |

#### Color Temperature Conversion

**Mirek (Mired) = 1,000,000 / Kelvin**

| Kelvin | Mirek | Description |
|--------|-------|-------------|
| 6500K | 153 | Cool daylight |
| 5000K | 200 | Neutral |
| 4000K | 250 | Cool white |
| 3000K | 333 | Warm white |
| 2700K | 370 | Incandescent |
| 2200K | 454 | Candle |
| 2000K | 500 | Warmest |

### Elgato Key Light API

#### Connection

- **Port:** 9123
- **Protocol:** HTTP (no HTTPS)
- **Authentication:** None required

#### Discovery

mDNS service type: `_elg._tcp`

#### Get Light Status

```
GET http://<ip>:9123/elgato/lights
```

Response:
```json
{
  "numberOfLights": 1,
  "lights": [{
    "on": 1,
    "brightness": 100,
    "temperature": 200
  }]
}
```

#### Set Light State

```
PUT http://<ip>:9123/elgato/lights
Content-Type: application/json

{
  "numberOfLights": 1,
  "lights": [{
    "on": 1,
    "brightness": 50,
    "temperature": 200
  }]
}
```

#### Parameters

| Parameter | Range | Description |
|-----------|-------|-------------|
| `on` | 0/1 | Power state |
| `brightness` | 3-100 | Brightness percentage |
| `temperature` | 143-344 | Color temp (inverse Mirek) |

#### Color Temperature Conversion

**Elgato Value = round(1,000,000 / Kelvin)**

| Kelvin | Elgato Value | Description |
|--------|--------------|-------------|
| 7000K | 143 | Coolest |
| 6500K | 154 | Daylight |
| 5000K | 200 | Neutral |
| 4000K | 250 | Cool white |
| 3500K | 286 | Warm white |
| 2900K | 344 | Warmest |

#### Other Endpoints

```
GET  /elgato/accessory-info  # Hardware info
GET  /elgato/settings        # Device settings
POST /elgato/identify        # Flash the light
```

---

## Device Configuration

### Your Setup

| Device | IP Address | Type |
|--------|------------|------|
| Philips Hue Bridge | 192.168.0.80 | Hub |
| Elgato Key Light 1 | 192.168.0.47 | Light |
| Elgato Key Light 2 | 192.168.0.88 | Light |

### Default Brightness Schedule

| Time | Hue Brightness | Elgato Brightness | Notes |
|------|----------------|-------------------|-------|
| 06:00-09:00 | 70% | 50% | Morning ramp-up |
| 09:00-17:00 | 100% | 80% | Full work day |
| 17:00-21:00 | 60% | 30% | Evening wind-down |
| 21:00-06:00 | 50% | 3% | Night (minimal) |

---

## Sources

### Menu Bar Development
- [8th Light - Menu Bar Tutorial](https://8thlight.com/insights/tutorial-add-a-menu-bar-extra-to-a-macos-app)
- [AppCoda - Status Bar Apps](https://www.appcoda.com/macos-status-bar-apps/)
- [SwiftUI MenuBarExtra for Ventura](https://blog.schurigeln.com/menu-bar-apps-swift-ui/)
- [Medium - Left/Right Click Handling](https://medium.com/@clyapp/implementing-left-click-and-right-click-for-menu-bar-status-button-in-macos-app-c3fc0b981cf0)
- [SettingsAccess Library](https://github.com/orchetect/SettingsAccess)
- [Peter Steinberger - Settings from Menu Bar](https://steipete.me/posts/2025/showing-settings-from-macos-menu-bar-items)

### Philips Hue
- [Philips Hue Developer Program](https://developers.meethue.com/develop/get-started-2/)
- [Unofficial Hue API Reference](https://www.burgestrand.se/hue-api/)
- [OpenHue API Spec](https://github.com/openhue/openhue-api)
- [HueBlog - Color Temperature](https://hueblog.com/2024/02/14/displaying-the-exact-colour-temperature-for-philips-hue-in-kelvin/)

### Elgato Key Light
- [Elgato Key Light API](https://github.com/adamesch/elgato-key-light-api)
- [API Handyman - Elgato Postman](https://apihandyman.io/hacking-elgato-key-light-with-postman/)
- [Sebastian Daschner - Command Line Control](https://blog.sebastian-daschner.com/entries/control-elgato-lights-command-line)
- [Adafruit - CircuitPython Controller](https://learn.adafruit.com/circuitpython-elgato-wifi-light-controller)
- [Go keylight package](https://github.com/mdlayher/keylight)

### Solar/Sunrise Calculations
- [Solar Swift Library](https://github.com/ceeK/Solar)
- [Sunrise-Sunset.org API](https://sunrise-sunset.org/api)
- [SunriseSunset.io API](https://sunrisesunset.io/api/)
- [Marco Arment's Sun.swift Gist](https://gist.github.com/marcoarment/94b173faba12f6ca3a7de9e3f1a73fa1)

### Color Temperature
- [Alcon Lighting - Color Temperature Guide](https://www.alconlighting.com/blog/learning-lab/color-temperature-guide/)
- [Wikipedia - Color Temperature](https://en.wikipedia.org/wiki/Color_temperature)
- [TrueLight - Circadian Lighting](https://shoptruelight.com/kelvin-color-temperature/)
- [Globo Lighting - Kelvin Guide](https://www.globo-lighting.com/en/blog/colour-temperature-and-light-colour)

### Swift 6 & Concurrency
- [Hacking with Swift - Swift 6 Concurrency](https://www.hackingwithswift.com/swift/6.0/concurrency)
- [Medium - Swift 6 Migration](https://medium.com/@learningwithsude/swift-6-migration-masterclass-concurrency-safety-typed-throws-and-the-path-to-future-proof-apps-ff5b4b33ccf4)
- [Donny Wals - Swift 6.2 Concurrency](https://www.donnywals.com/exploring-concurrency-changes-in-swift-6-2/)

### Launch at Login
- [Nil Coalescing - LaunchAtLogin Setting](https://nilcoalescing.com/blog/LaunchAtLoginSetting/)
- [sindresorhus/LaunchAtLogin](https://github.com/sindresorhus/LaunchAtLogin)
- [Jogendra - Login Items](https://jogendra.dev/implementing-launch-at-login-feature-in-macos-apps)

### Bonjour/mDNS Discovery
- [Apple Developer Forums - NWBrowser](https://developer.apple.com/forums/thread/118388)
- [Stack Overflow - NetService Deprecation](https://stackoverflow.com/questions/68384119/if-netservice-is-deprecated-how-should-i-do-mdns-on-macos)
- [GitHub - mDNS_Browser Example](https://github.com/Wazambe/mDNS_Browser)

### Data Persistence
- [Hacking with Swift - @AppStorage](https://www.hackingwithswift.com/quick-start/swiftui/what-is-the-appstorage-property-wrapper)
- [Use Your Loaf - SceneStorage Custom Types](https://useyourloaf.com/blog/scenestorage-for-custom-types/)
