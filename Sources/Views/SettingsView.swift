import SwiftUI
import ServiceManagement
import CoreLocation
import Charts

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            CurvesTab()
                .tabItem {
                    Label("Curves", systemImage: "chart.line.uptrend.xyaxis")
                }

            DevicesTab()
                .tabItem {
                    Label("Devices", systemImage: "lightbulb")
                }

            AdvancedTab()
                .tabItem {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }
        }
        .environmentObject(appState)
        .frame(width: 560, height: 480)
    }
}

// MARK: - General Tab

struct GeneralTab: View {
    @EnvironmentObject var appState: AppState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var showLocationSearch = false
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    // Local state to force UI updates
    @State private var searchResults: [LocationService.LocationResult] = []
    @State private var isSearching = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        updateLaunchAtLogin(enabled: newValue)
                    }

                LabeledContent("Update Interval") {
                    Picker("", selection: $appState.updateIntervalSeconds) {
                        Text("30 seconds").tag(30)
                        Text("1 minute").tag(60)
                        Text("2 minutes").tag(120)
                        Text("5 minutes").tag(300)
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }

                Toggle("Weather-based adjustment", isOn: $appState.weatherAdjustmentEnabled)

                if appState.weatherAdjustmentEnabled {
                    Text("Adjusts color temperature based on cloud cover. Cloudy skies have cooler natural light.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Settings")
            }

            Section {
                // Current location display
                HStack {
                    Text("Location")
                    Spacer()
                    if appState.locationService.isDetecting {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text("Detecting...")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(appState.locationService.locationName)
                            .foregroundStyle(.secondary)
                    }
                }

                if let location = appState.locationService.currentLocation {
                    HStack {
                        Text("Coordinates")
                        Spacer()
                        Text(String(format: "%.4f, %.4f", location.latitude, location.longitude))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                // Action buttons
                HStack {
                    Button("Auto-Detect") {
                        Task {
                            await appState.detectLocation()
                        }
                    }
                    .disabled(appState.locationService.isDetecting)

                    Button(showLocationSearch ? "Cancel" : "Search City") {
                        showLocationSearch.toggle()
                        if !showLocationSearch {
                            searchText = ""
                            appState.locationService.searchResults = []
                        }
                    }
                }

                // Location search
                if showLocationSearch {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("Type a city name...", text: $searchText)
                                .textFieldStyle(.roundedBorder)
                                .focused($isSearchFocused)
                                .onSubmit {
                                    if let first = searchResults.first {
                                        selectSearchResult(first)
                                    }
                                }
                            Button("Search") {
                                performSearch()
                            }
                            .disabled(searchText.count < 2 || isSearching)
                        }
                        .onChange(of: searchText) { _, _ in
                            performSearch()
                        }
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                isSearchFocused = true
                            }
                        }

                        // Search results
                        if isSearching {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.6)
                                Text("Searching...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.leading, 4)
                        } else if !searchResults.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(searchResults) { result in
                                    Button {
                                        selectSearchResult(result)
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(result.name)
                                                    .fontWeight(.medium)
                                                if !result.subtitle.isEmpty {
                                                    Text(result.subtitle)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            Spacer()
                                            Image(systemName: "arrow.right.circle")
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(.vertical, 6)
                                        .padding(.horizontal, 8)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    if result.id != searchResults.last?.id {
                                        Divider()
                                    }
                                }
                            }
                            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
                        } else if searchText.count >= 2 {
                            Text("No results found")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 4)
                        }
                    }
                }
            } header: {
                Text("Location")
            }

            Section {
                HStack {
                    Text("Current Color Temperature")
                    Spacer()
                    Text("\(appState.currentColorTemperature)K")
                        .fontWeight(.medium)
                    Text(ColorTemperature.description(for: appState.currentColorTemperature))
                        .foregroundStyle(.secondary)
                }

                if let sunrise = appState.solarService.todaySunrise(),
                   let sunset = appState.solarService.todaySunset() {
                    HStack {
                        Text("Sunrise")
                        Spacer()
                        Text(sunrise, style: .time)
                    }
                    HStack {
                        Text("Sunset")
                        Spacer()
                        Text(sunset, style: .time)
                    }
                    HStack {
                        Text("Day Length")
                        Spacer()
                        let dayLength = sunset.timeIntervalSince(sunrise)
                        let hours = Int(dayLength) / 3600
                        let minutes = (Int(dayLength) % 3600) / 60
                        Text("\(hours)h \(minutes)m")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Solar Information")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else {
            searchResults = []
            isSearching = false
            return
        }

        isSearching = true

        Task {
            // Debounce
            try? await Task.sleep(for: .milliseconds(400))

            let geocoder = CLGeocoder()

            do {
                let placemarks = try await geocoder.geocodeAddressString(query)

                let mapped: [LocationService.LocationResult] = placemarks.compactMap { placemark in
                    guard let location = placemark.location else { return nil }

                    // Build name from locality or name
                    let name = placemark.locality ?? placemark.name ?? query

                    // Build subtitle from admin area and country
                    var subtitleParts: [String] = []
                    if let admin = placemark.administrativeArea {
                        subtitleParts.append(admin)
                    }
                    if let country = placemark.country {
                        subtitleParts.append(country)
                    }

                    return LocationService.LocationResult(
                        name: name,
                        coordinate: location.coordinate,
                        subtitle: subtitleParts.joined(separator: ", ")
                    )
                }

                await MainActor.run {
                    searchResults = mapped
                    isSearching = false
                }
            } catch {
                print("Geocoder error: \(error)")
                await MainActor.run {
                    searchResults = []
                    isSearching = false
                }
            }
        }
    }

    private func selectSearchResult(_ result: LocationService.LocationResult) {
        appState.locationService.selectLocation(result)
        appState.solarService.updateLocation(
            latitude: result.coordinate.latitude,
            longitude: result.coordinate.longitude
        )
        appState.currentColorTemperature = appState.solarService.currentColorTemperature()
        showLocationSearch = false
        searchText = ""
        searchResults = []
    }

    private func updateLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to update launch at login: \(error)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Devices Tab

struct DevicesTab: View {
    @EnvironmentObject var appState: AppState
    @State private var newElgatoIP = ""
    @State private var isAuthenticating = false
    @State private var authError: String?
    @State private var testingLightId: UUID?

    var body: some View {
        Form {
            // Philips Hue Section
            Section {
                LabeledContent("Bridge IP") {
                    TextField("IP Address", text: $appState.hueBridgeIP)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                }

                if appState.hueUsername.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Text("Not connected")
                                .foregroundStyle(.secondary)
                            Spacer()
                            if isAuthenticating {
                                ProgressView()
                                    .scaleEffect(0.7)
                            }
                            Button("Connect") {
                                Task {
                                    isAuthenticating = true
                                    authError = nil
                                    let success = await appState.authenticateHue()
                                    isAuthenticating = false
                                    if !success {
                                        authError = appState.hueService.authenticationError
                                    }
                                }
                            }
                            .disabled(isAuthenticating)
                        }

                        Text("Press the button on your Hue bridge, then click Connect")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let error = authError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                } else {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Connected")
                        Text("(\(appState.hueLights.count) lights)")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Refresh") {
                            Task {
                                await appState.refreshHueLights()
                            }
                        }
                        Button("Disconnect") {
                            appState.disconnectHue()
                        }
                    }

                    // Show discovered Hue lights in scrollable list
                    if !appState.hueLights.isEmpty {
                        ScrollView {
                            VStack(spacing: 4) {
                                ForEach($appState.hueLights) { $light in
                                    HStack {
                                        Toggle("", isOn: $light.isEnabled)
                                            .labelsHidden()
                                            .onChange(of: light.isEnabled) { _, newValue in
                                                appState.saveHueLights()
                                                // Turn the physical light on/off
                                                Task {
                                                    _ = await appState.setHueLightOnOff(lightId: light.hueId, on: newValue)
                                                }
                                            }

                                        Text(light.name)

                                        Spacer()

                                        // Reachability indicator
                                        Image(systemName: light.isReachable ? "checkmark.circle.fill" : "xmark.circle.fill")
                                            .foregroundStyle(light.isReachable ? .green : .red)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                        .frame(height: 120)  // ~5 lights visible
                    }
                }
            } header: {
                Text("Philips Hue")
            }

            // Elgato Section
            Section {
                ForEach($appState.elgatoLights) { $light in
                    LabeledContent {
                        HStack {
                            TextField("IP Address", text: $light.ip)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 140)
                                .onChange(of: light.ip) { _, _ in
                                    appState.saveElgatoLights()
                                }

                            // Status indicator or testing spinner
                            if testingLightId == light.id {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 20)
                            } else {
                                Image(systemName: light.isReachable ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(light.isReachable ? .green : .red)
                            }

                            // Only show refresh button if not reachable
                            if !light.isReachable && testingLightId != light.id {
                                Button {
                                    Task {
                                        testingLightId = light.id
                                        let reachable = await appState.testElgatoLight(ip: light.ip)
                                        if let index = appState.elgatoLights.firstIndex(where: { $0.id == light.id }) {
                                            appState.elgatoLights[index].isReachable = reachable
                                        }
                                        testingLightId = nil
                                    }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .buttonStyle(.borderless)
                            }

                            Button {
                                appState.elgatoLights.removeAll { $0.id == light.id }
                                appState.saveElgatoLights()
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                    } label: {
                        Toggle(light.name, isOn: $light.isEnabled)
                            .onChange(of: light.isEnabled) { _, newValue in
                                appState.saveElgatoLights()
                                // Turn the physical light on/off
                                Task {
                                    _ = await appState.setElgatoLightOnOff(ip: light.ip, on: newValue)
                                }
                            }
                    }
                }

                LabeledContent("Add Light") {
                    HStack {
                        TextField("IP Address", text: $newElgatoIP)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)

                        Button("Add") {
                            guard !newElgatoIP.isEmpty else { return }
                            let newLight = ElgatoLight(
                                id: UUID(),
                                name: "Key Light \(appState.elgatoLights.count + 1)",
                                ip: newElgatoIP,
                                isEnabled: true
                            )
                            appState.elgatoLights.append(newLight)
                            appState.saveElgatoLights()
                            newElgatoIP = ""
                            // Test the new light immediately
                            Task {
                                if let index = appState.elgatoLights.firstIndex(where: { $0.id == newLight.id }) {
                                    let reachable = await appState.testElgatoLight(ip: newLight.ip)
                                    appState.elgatoLights[index].isReachable = reachable
                                }
                            }
                        }
                        .disabled(newElgatoIP.isEmpty)
                    }
                }
            } header: {
                Text("Elgato Key Lights")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Curves Tab

struct CurvesTab: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedChart: ChartType = .brightness

    enum ChartType: String, CaseIterable {
        case brightness = "Brightness"
        case colorTemp = "Color Temp"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Chart selector
            Picker("Chart", selection: $selectedChart) {
                ForEach(ChartType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 12)

            // Chart
            Group {
                if selectedChart == .brightness {
                    BrightnessChartView(preview: appState.hourlyPreview)
                } else {
                    ColorTempChartView(preview: appState.hourlyPreview)
                }
            }
            .frame(height: 160)
            .padding(.horizontal)
            .padding(.top, 8)

            Divider()
                .padding(.top, 4)
                .padding(.bottom, 2)

            // Settings
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Brightness Limits
                    GroupBox("Brightness Limits") {
                        VStack(spacing: 12) {
                            BrightnessSliderRow(
                                label: "Hue Max",
                                value: $appState.brightnessLimits.hueMax,
                                range: 10...100,
                                color: .yellow
                            )
                            BrightnessSliderRow(
                                label: "Hue Min",
                                value: $appState.brightnessLimits.hueMin,
                                range: 1...100,
                                color: .yellow.opacity(0.5)
                            )
                            BrightnessSliderRow(
                                label: "Elgato Max",
                                value: $appState.brightnessLimits.elgatoMax,
                                range: 10...100,
                                color: .blue
                            )
                            BrightnessSliderRow(
                                label: "Elgato Min",
                                value: $appState.brightnessLimits.elgatoMin,
                                range: 3...100,
                                color: .blue.opacity(0.5)
                            )
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: appState.brightnessLimits) { _, _ in
                        appState.updateHourlyPreview()
                        // Update lights immediately if enabled
                        if appState.isEnabled {
                            Task {
                                await appState.refreshNow()
                            }
                        }
                    }

                    // Color Temperature Limits
                    GroupBox("Color Temperature") {
                        VStack(spacing: 12) {
                            HStack {
                                Text("Warmest (Night)")
                                    .frame(width: 110, alignment: .leading)
                                Slider(
                                    value: Binding(
                                        get: { Double(appState.colorTempLimits.warmest) },
                                        set: { appState.colorTempLimits.warmest = Int($0) }
                                    ),
                                    in: 2000...4000,
                                    step: 100
                                )
                                .tint(.orange)
                                Text("\(appState.colorTempLimits.warmest)K")
                                    .frame(width: 50, alignment: .trailing)
                                    .monospacedDigit()
                            }
                            HStack {
                                Text("Coolest (Day)")
                                    .frame(width: 110, alignment: .leading)
                                Slider(
                                    value: Binding(
                                        get: { Double(appState.colorTempLimits.coolest) },
                                        set: { appState.colorTempLimits.coolest = Int($0) }
                                    ),
                                    in: 5000...7500,
                                    step: 100
                                )
                                .tint(.cyan)
                                Text("\(appState.colorTempLimits.coolest)K")
                                    .frame(width: 50, alignment: .trailing)
                                    .monospacedDigit()
                            }
                            HStack {
                                Text("Cloud Boost")
                                    .frame(width: 110, alignment: .leading)
                                Slider(
                                    value: Binding(
                                        get: { Double(appState.colorTempLimits.cloudBoostMax) },
                                        set: { appState.colorTempLimits.cloudBoostMax = Int($0) }
                                    ),
                                    in: 0...1500,
                                    step: 100
                                )
                                .tint(.gray)
                                Text("+\(appState.colorTempLimits.cloudBoostMax)K")
                                    .frame(width: 50, alignment: .trailing)
                                    .monospacedDigit()
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: appState.colorTempLimits) { _, _ in
                        appState.updateHourlyPreview()
                        // Update lights immediately if enabled
                        if appState.isEnabled {
                            Task {
                                await appState.refreshNow()
                            }
                        }
                    }

                    // Current Status
                    GroupBox("Current Status") {
                        HStack(spacing: 20) {
                            StatusItem(
                                label: "Progress",
                                value: String(format: "%.0f%%", appState.currentDayProgress * 100)
                            )
                            StatusItem(
                                label: "Color",
                                value: "\(appState.currentColorTemperature)K"
                            )
                            StatusItem(
                                label: "Hue",
                                value: "\(appState.currentHueBrightness)%"
                            )
                            StatusItem(
                                label: "Elgato",
                                value: "\(appState.currentElgatoBrightness)%"
                            )
                            if appState.weatherAdjustmentEnabled {
                                StatusItem(
                                    label: "Clouds",
                                    value: "\(appState.currentCloudCover)%"
                                )
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
        }
        .onAppear {
            appState.updateHourlyPreview()
        }
    }
}

struct BrightnessSliderRow: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let color: Color

    var body: some View {
        HStack {
            Text(label)
                .frame(width: 80, alignment: .leading)
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { value = Int($0) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1
            )
            .tint(color)
            Text("\(value)%")
                .frame(width: 40, alignment: .trailing)
                .monospacedDigit()
        }
    }
}

struct StatusItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline)
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Charts

struct BrightnessChartView: View {
    let preview: [CircadianCurve.HourlyPreview]

    var body: some View {
        Chart {
            ForEach(preview) { item in
                LineMark(
                    x: .value("Hour", item.hour),
                    y: .value("Brightness", item.hueBrightness),
                    series: .value("Type", "Hue")
                )
                .foregroundStyle(.yellow)
                .lineStyle(StrokeStyle(lineWidth: 2))

                LineMark(
                    x: .value("Hour", item.hour),
                    y: .value("Brightness", item.elgatoBrightness),
                    series: .value("Type", "Elgato")
                )
                .foregroundStyle(.blue)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }

            // Current time indicator
            if let currentHour = Calendar.current.dateComponents([.hour], from: Date()).hour {
                RuleMark(x: .value("Now", currentHour))
                    .foregroundStyle(.red.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 2]))
            }
        }
        .chartXScale(domain: 0...23)
        .chartYScale(domain: 0...100)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let hour = value.as(Int.self) {
                        Text(String(format: "%02d", hour))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let pct = value.as(Int.self) {
                        Text("\(pct)%")
                    }
                }
            }
        }
        .chartLegend(position: .top) {
            HStack(spacing: 16) {
                Label("Hue", systemImage: "circle.fill")
                    .foregroundStyle(.yellow)
                Label("Elgato", systemImage: "circle.fill")
                    .foregroundStyle(.blue)
            }
            .font(.caption)
        }
    }
}

struct ColorTempChartView: View {
    let preview: [CircadianCurve.HourlyPreview]

    var body: some View {
        Chart {
            ForEach(preview) { item in
                AreaMark(
                    x: .value("Hour", item.hour),
                    y: .value("Kelvin", item.colorTemp)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [.orange.opacity(0.3), .cyan.opacity(0.3)],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                )

                LineMark(
                    x: .value("Hour", item.hour),
                    y: .value("Kelvin", item.colorTemp)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [.orange, .cyan],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                )
                .lineStyle(StrokeStyle(lineWidth: 2.5))
            }

            // Current time indicator
            if let currentHour = Calendar.current.dateComponents([.hour], from: Date()).hour {
                RuleMark(x: .value("Now", currentHour))
                    .foregroundStyle(.red.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 2]))
            }
        }
        .chartXScale(domain: 0...23)
        .chartYScale(domain: 2500...7500)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let hour = value.as(Int.self) {
                        Text(String(format: "%02d", hour))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: [2700, 4000, 5500, 6500]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let k = value.as(Int.self) {
                        Text("\(k)K")
                    }
                }
            }
        }
        .chartLegend(position: .top) {
            HStack(spacing: 8) {
                Circle().fill(.orange).frame(width: 8, height: 8)
                Text("Warm")
                Circle().fill(.cyan).frame(width: 8, height: 8)
                Text("Cool")
            }
            .font(.caption)
        }
    }
}

// MARK: - Advanced Tab

struct AdvancedTab: View {
    @EnvironmentObject var appState: AppState
    @State private var previewData: [(hour: Int, kelvin: Int, description: String)] = []

    var body: some View {
        Form {
            Section {
                Text("Preview of color temperatures throughout the day based on current solar calculations.")
                    .foregroundStyle(.secondary)
                    .font(.callout)

                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.fixed(60)),
                        GridItem(.fixed(70)),
                        GridItem(.flexible())
                    ], spacing: 4) {
                        Text("Time").fontWeight(.medium)
                        Text("Kelvin").fontWeight(.medium)
                        Text("Description").fontWeight(.medium)

                        ForEach(previewData, id: \.hour) { item in
                            Text(String(format: "%02d:00", item.hour))
                            Text("\(item.kelvin)K")
                            Text(item.description)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                }
                .frame(height: 200)
            } header: {
                Text("Color Temperature Preview")
            }

            Section {
                Button("Print Debug Info") {
                    print("=== CircadianLights Debug ===")
                    print("Enabled: \(appState.isEnabled)")
                    print("Current Temp: \(appState.currentColorTemperature)K")
                    print("Hue Bridge: \(appState.hueBridgeIP)")
                    print("Hue Auth: \(appState.hueUsername.isEmpty ? "No" : "Yes")")
                    print("Elgato Lights: \(appState.elgatoLights.count)")
                    for light in appState.elgatoLights {
                        print("  - \(light.name): \(light.ip) (enabled: \(light.isEnabled))")
                    }
                }
            } header: {
                Text("Debugging")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            previewData = appState.solarService.dailyTemperaturePreview()
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
