import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openSettings) var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with toggle
            headerSection
                .padding(.bottom, 12)

            Divider()

            // Status section (only when enabled)
            if appState.isEnabled {
                statusSection
                    .padding(.vertical, 12)
                Divider()
            }

            // Devices
            deviceSummarySection
                .padding(.vertical, 12)

            Divider()

            // Actions
            actionsSection
                .padding(.top, 8)
        }
        .padding(16)
        .frame(width: 260)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("CircadianLights")
                    .font(.headline)
                Text(appState.isEnabled ? "Active" : "Inactive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: $appState.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    // MARK: - Status Section

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Color temperature
            HStack(spacing: 8) {
                Image(systemName: "thermometer.medium")
                    .foregroundStyle(.orange)
                    .frame(width: 16)
                Text("Color Temp")
                Spacer()
                if appState.cloudAdjustment > 0 {
                    Text("+\(appState.cloudAdjustment)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(appState.currentColorTemperature)K")
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
            }

            // Weather (only show during daytime with adjustment enabled)
            if appState.weatherAdjustmentEnabled && appState.solarService.isDaytime() {
                HStack(spacing: 8) {
                    Image(systemName: cloudCoverIcon)
                        .foregroundStyle(.cyan)
                        .frame(width: 16)
                    Text(appState.weatherService.cloudCoverDescription)
                    Spacer()
                    Text("\(appState.currentCloudCover)%")
                        .fontWeight(.medium)
                }
            }

            // Hue brightness
            HStack(spacing: 8) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(.yellow)
                    .frame(width: 16)
                Text("Hue")
                Spacer()
                Text("\(appState.currentHueBrightness)%")
                    .fontWeight(.medium)
            }

            // Elgato brightness
            HStack(spacing: 8) {
                Image(systemName: "light.panel.fill")
                    .foregroundStyle(.blue)
                    .frame(width: 16)
                Text("Elgato")
                Spacer()
                Text("\(appState.currentElgatoBrightness)%")
                    .fontWeight(.medium)
            }

            // Solar info
            if let sunrise = appState.solarService.todaySunrise(),
               let sunset = appState.solarService.todaySunset() {
                HStack(spacing: 8) {
                    Image(systemName: "sunrise.fill")
                        .foregroundStyle(.orange)
                        .frame(width: 16)
                    Text(sunrise, style: .time)
                    Spacer()
                    Image(systemName: "sunset.fill")
                        .foregroundStyle(.orange)
                    Text(sunset, style: .time)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    // MARK: - Device Summary

    private var deviceSummarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Devices")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer()
                if let lastUpdate = appState.lastUpdateTime {
                    Text(lastUpdate, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                // Hue status
                HStack(spacing: 8) {
                    Circle()
                        .fill(hueStatusColor)
                        .frame(width: 8, height: 8)
                    Text("Hue")
                    Spacer()
                    Text(hueStatusText)
                        .foregroundStyle(.secondary)
                }

                // Elgato status
                HStack(spacing: 8) {
                    Circle()
                        .fill(elgatoStatusColor)
                        .frame(width: 8, height: 8)
                    Text("Elgato")
                    Spacer()
                    Text(elgatoStatusText)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
    }

    private var hueStatusColor: Color {
        let reachable = appState.hueLights.filter(\.isReachable).count
        if appState.hueUsername.isEmpty { return .gray }
        if reachable == 0 { return .orange }
        return .green
    }

    private var hueStatusText: String {
        if appState.hueUsername.isEmpty { return "Not connected" }
        let reachable = appState.hueLights.filter(\.isReachable).count
        let enabled = appState.hueLights.filter(\.isEnabled).count
        if enabled == 0 { return "No lights enabled" }
        return "\(reachable)/\(enabled) online"
    }

    private var elgatoStatusColor: Color {
        let reachable = appState.elgatoLights.filter(\.isReachable).count
        let enabled = appState.elgatoLights.filter(\.isEnabled).count
        if enabled == 0 { return .gray }
        if reachable == 0 { return .orange }
        if reachable < enabled { return .yellow }
        return .green
    }

    private var elgatoStatusText: String {
        let reachable = appState.elgatoLights.filter(\.isReachable).count
        let enabled = appState.elgatoLights.filter(\.isEnabled).count
        if enabled == 0 { return "No lights configured" }
        return "\(reachable)/\(enabled) online"
    }

    private var cloudCoverIcon: String {
        switch appState.currentCloudCover {
        case 0..<20: return "sun.max"
        case 20..<40: return "cloud.sun"
        case 40..<60: return "cloud"
        case 60..<80: return "cloud.fill"
        default: return "smoke.fill"
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuButton(
                icon: "arrow.clockwise",
                title: "Refresh Now",
                shortcut: nil
            ) {
                Task { await appState.refreshNow() }
            }
            .disabled(!appState.isEnabled)

            MenuButton(
                icon: "gear",
                title: "Settings...",
                shortcut: ","
            ) {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()
                .padding(.vertical, 4)

            MenuButton(
                icon: "power",
                title: "Quit CircadianLights",
                shortcut: "Q"
            ) {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

// MARK: - Menu Button Component

struct MenuButton: View {
    let icon: String
    let title: String
    let shortcut: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                Text(title)
                Spacer()
                if let shortcut = shortcut {
                    Text("\u{2318}\(shortcut)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuButtonStyle())
    }
}

struct MenuButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.1) : Color.clear)
            )
            .foregroundStyle(configuration.isPressed ? .primary : .primary)
    }
}

#Preview {
    MenuBarView()
        .environmentObject(AppState())
}
