import Foundation

/// Service for controlling Elgato Key Light devices via HTTP API.
///
/// Elgato Key Lights expose a simple HTTP API on port 9123:
/// - GET/PUT to `/elgato/lights` for light state
/// - No authentication required
@MainActor
final class ElgatoService {
    private let port = 9123
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Get the current state of an Elgato light
    func getState(ip: String) async -> ElgatoState? {
        guard let url = URL(string: "http://\(ip):\(port)/elgato/lights") else {
            return nil
        }

        do {
            let (data, response) = try await session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            let apiResponse = try JSONDecoder().decode(ElgatoAPIResponse.self, from: data)
            return apiResponse.lights.first
        } catch {
            print("[Elgato] Failed to get state from \(ip): \(error)")
            return nil
        }
    }

    /// Set the state of an Elgato light
    /// - Parameters:
    ///   - ip: The IP address of the light
    ///   - on: Whether the light should be on
    ///   - brightness: Brightness level (3-100)
    ///   - temperature: Color temperature in Elgato units (143-344)
    func setState(ip: String, on: Bool, brightness: Int, temperature: Int) async -> Bool {
        guard let url = URL(string: "http://\(ip):\(port)/elgato/lights") else {
            return false
        }

        let clampedBrightness = max(3, min(100, brightness))
        let clampedTemp = max(143, min(344, temperature))

        let state = ElgatoState(on: on ? 1 : 0, brightness: clampedBrightness, temperature: clampedTemp)
        let payload = ElgatoAPIResponse(numberOfLights: 1, lights: [state])

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(payload)

            let (_, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }

            let success = httpResponse.statusCode == 200
            if success {
                print("[Elgato] Set \(ip): on=\(on), brightness=\(clampedBrightness)%, temp=\(clampedTemp)")
            } else {
                print("[Elgato] Failed to set \(ip): HTTP \(httpResponse.statusCode)")
            }
            return success
        } catch {
            print("[Elgato] Failed to set state on \(ip): \(error)")
            return false
        }
    }

    /// Set color temperature and brightness using Kelvin and percentage
    func setLight(ip: String, on: Bool, brightnessPercent: Int, kelvin: Int) async -> Bool {
        let elgatoTemp = ColorTemperature.kelvinToElgato(kelvin)
        let elgatoBrightness = ColorTemperature.percentToElgatoBrightness(brightnessPercent)
        return await setState(ip: ip, on: on, brightness: elgatoBrightness, temperature: elgatoTemp)
    }

    /// Check if an Elgato light is reachable
    func isReachable(ip: String) async -> Bool {
        await getState(ip: ip) != nil
    }

    /// Turn an Elgato light on or off (keeps current brightness/temperature)
    func setOnOff(ip: String, on: Bool) async -> Bool {
        // Get current state to preserve brightness and temperature
        guard let currentState = await getState(ip: ip) else {
            return false
        }
        return await setState(
            ip: ip,
            on: on,
            brightness: currentState.brightness,
            temperature: currentState.temperature
        )
    }

    /// Update multiple Elgato lights with the same settings
    func updateLights(_ lights: [ElgatoLight], kelvin: Int, brightnessPercent: Int) async -> [UUID: Bool] {
        var results: [UUID: Bool] = [:]

        await withTaskGroup(of: (UUID, Bool).self) { group in
            for light in lights where light.isEnabled {
                group.addTask {
                    let success = await self.setLight(
                        ip: light.ip,
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

// MARK: - API Models

struct ElgatoState: Codable {
    var on: Int           // 0 or 1
    var brightness: Int   // 3-100
    var temperature: Int  // 143-344

    var isOn: Bool { on == 1 }
}

struct ElgatoAPIResponse: Codable {
    var numberOfLights: Int
    var lights: [ElgatoState]
}
