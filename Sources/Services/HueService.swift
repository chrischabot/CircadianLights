import Foundation

/// Service for controlling Philips Hue lights via the Bridge API.
///
/// Hue Bridge API:
/// - Authentication: Press bridge button, POST to `/api` with devicetype
/// - Lights: GET/PUT `/api/{username}/lights/{id}/state`
/// - Color temp in mirek: 153 (cool) to 500 (warm)
@MainActor
final class HueService: ObservableObject {
    @Published var isAuthenticating = false
    @Published var authenticationError: String?
    @Published var discoveredLights: [HueLight] = []

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: config)
    }

    // MARK: - Authentication

    /// Attempt to authenticate with the Hue bridge.
    /// User must press the bridge button within 30 seconds before calling this.
    /// - Parameter bridgeIP: The IP address of the Hue bridge
    /// - Returns: The username token if successful, nil otherwise
    func authenticate(bridgeIP: String) async -> String? {
        guard let url = URL(string: "http://\(bridgeIP)/api") else {
            authenticationError = "Invalid bridge IP"
            return nil
        }

        isAuthenticating = true
        authenticationError = nil

        defer { isAuthenticating = false }

        let payload = ["devicetype": "CircadianLights#macOS"]

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(payload)

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                authenticationError = "Bridge not responding"
                return nil
            }

            let results = try JSONDecoder().decode([HueAPIResponse].self, from: data)

            if let success = results.first?.success {
                print("[Hue] Authenticated: \(success.username)")
                return success.username
            } else if let error = results.first?.error {
                if error.type == 101 {
                    authenticationError = "Press the bridge button first"
                } else {
                    authenticationError = error.description
                }
                print("[Hue] Auth error: \(error.description)")
                return nil
            }
        } catch {
            authenticationError = "Connection failed: \(error.localizedDescription)"
            print("[Hue] Auth failed: \(error)")
        }

        return nil
    }

    /// Test if a username is valid for a bridge
    func testConnection(bridgeIP: String, username: String) async -> Bool {
        guard let url = URL(string: "http://\(bridgeIP)/api/\(username)/lights") else {
            return false
        }

        do {
            let (data, response) = try await session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return false
            }

            // Check if response is an error array
            if let errors = try? JSONDecoder().decode([HueAPIResponse].self, from: data),
               errors.first?.error != nil {
                return false
            }

            return true
        } catch {
            return false
        }
    }

    // MARK: - Light Discovery

    /// Fetch all lights from the bridge
    func fetchLights(bridgeIP: String, username: String) async -> [HueLight] {
        guard let url = URL(string: "http://\(bridgeIP)/api/\(username)/lights") else {
            return []
        }

        do {
            let (data, response) = try await session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return []
            }

            let lightsDict = try JSONDecoder().decode([String: HueLightAPIResponse].self, from: data)

            let lights = lightsDict.compactMap { (id, apiLight) -> HueLight? in
                // Only include lights that support color temperature
                guard apiLight.type.contains("temperature") ||
                      apiLight.type.contains("Extended") ||
                      apiLight.type.contains("White") else {
                    return nil
                }

                return HueLight(
                    id: UUID(),
                    hueId: id,
                    name: apiLight.name,
                    isEnabled: true,
                    isReachable: apiLight.state.reachable,
                    isOn: apiLight.state.on,
                    brightness: apiLight.state.bri ?? 254,
                    colorTemp: apiLight.state.ct ?? 366
                )
            }.sorted { $0.hueId.localizedStandardCompare($1.hueId) == .orderedAscending }

            print("[Hue] Found \(lights.count) color temperature lights")
            discoveredLights = lights
            return lights
        } catch {
            print("[Hue] Failed to fetch lights: \(error)")
            return []
        }
    }

    // MARK: - Light Control

    /// Set the state of a single Hue light
    func setLightState(
        bridgeIP: String,
        username: String,
        lightId: String,
        on: Bool,
        brightness: Int,
        colorTemp: Int
    ) async -> Bool {
        guard let url = URL(string: "http://\(bridgeIP)/api/\(username)/lights/\(lightId)/state") else {
            return false
        }

        let clampedBrightness = max(1, min(254, brightness))
        let clampedColorTemp = max(153, min(500, colorTemp))

        var state: [String: Any] = ["on": on]
        if on {
            state["bri"] = clampedBrightness
            state["ct"] = clampedColorTemp
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: state)

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return false
            }

            // Check for errors in response
            if let results = try? JSONDecoder().decode([HueAPIResponse].self, from: data),
               results.contains(where: { $0.error != nil }) {
                print("[Hue] Error setting light \(lightId)")
                return false
            }

            print("[Hue] Set light \(lightId): on=\(on), bri=\(clampedBrightness), ct=\(clampedColorTemp)")
            return true
        } catch {
            print("[Hue] Failed to set light \(lightId): \(error)")
            return false
        }
    }

    /// Turn a Hue light on or off only
    func setOnOff(
        bridgeIP: String,
        username: String,
        lightId: String,
        on: Bool
    ) async -> Bool {
        guard let url = URL(string: "http://\(bridgeIP)/api/\(username)/lights/\(lightId)/state") else {
            return false
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["on": on])

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return false
            }

            if let results = try? JSONDecoder().decode([HueAPIResponse].self, from: data),
               results.contains(where: { $0.error != nil }) {
                return false
            }

            print("[Hue] Set light \(lightId) on=\(on)")
            return true
        } catch {
            print("[Hue] Failed to toggle light \(lightId): \(error)")
            return false
        }
    }

    /// Set light using Kelvin and percentage
    func setLight(
        bridgeIP: String,
        username: String,
        lightId: String,
        on: Bool,
        brightnessPercent: Int,
        kelvin: Int
    ) async -> Bool {
        let mirek = ColorTemperature.kelvinToMirek(kelvin)
        let hueBrightness = ColorTemperature.percentToHueBrightness(brightnessPercent)
        return await setLightState(
            bridgeIP: bridgeIP,
            username: username,
            lightId: lightId,
            on: on,
            brightness: hueBrightness,
            colorTemp: mirek
        )
    }

    /// Update multiple Hue lights with the same settings
    func updateLights(
        bridgeIP: String,
        username: String,
        lights: [HueLight],
        kelvin: Int,
        brightnessPercent: Int
    ) async -> [UUID: Bool] {
        var results: [UUID: Bool] = [:]

        await withTaskGroup(of: (UUID, Bool).self) { group in
            for light in lights where light.isEnabled {
                group.addTask {
                    let success = await self.setLight(
                        bridgeIP: bridgeIP,
                        username: username,
                        lightId: light.hueId,
                        on: true,
                        brightnessPercent: brightnessPercent,
                        kelvin: kelvin
                    )
                    return (light.id, success)
                }
            }

            for await (id, success) in group {
                results[id] = success
            }
        }

        return results
    }
}

// MARK: - API Response Models

private struct HueAPIResponse: Codable {
    var success: HueAuthSuccess?
    var error: HueAPIError?
}

private struct HueAuthSuccess: Codable {
    var username: String
}

private struct HueAPIError: Codable {
    var type: Int
    var address: String?
    var description: String
}

private struct HueLightAPIResponse: Codable {
    var name: String
    var type: String
    var state: HueLightState

    struct HueLightState: Codable {
        var on: Bool
        var bri: Int?
        var ct: Int?
        var reachable: Bool
    }
}
