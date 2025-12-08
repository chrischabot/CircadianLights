import Foundation
import CoreLocation

/// Service for detecting user's location for solar calculations.
/// Uses IP geolocation by default (no permissions needed), with CoreLocation as optional upgrade.
@MainActor
final class LocationService: NSObject, ObservableObject {
    @Published var currentLocation: CLLocationCoordinate2D?
    @Published var locationName: String = "Unknown"
    @Published var status: LocationStatus = .unknown
    @Published var isDetecting: Bool = false

    // Search
    @Published var searchQuery: String = ""
    @Published var searchResults: [LocationResult] = []
    @Published var isSearching: Bool = false

    private var searchTask: Task<Void, Never>?

    struct LocationResult: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let coordinate: CLLocationCoordinate2D
        let subtitle: String

        static func == (lhs: LocationResult, rhs: LocationResult) -> Bool {
            lhs.id == rhs.id
        }
    }

    enum LocationStatus: String {
        case unknown = "Unknown"
        case detecting = "Detecting..."
        case detected = "Detected"
        case denied = "Permission Denied"
        case error = "Error"
        case usingIP = "IP Location"
        case manual = "Manual"
    }

    override init() {
        super.init()
    }

    // MARK: - Location Search

    /// Search for locations by name using Nominatim (OpenStreetMap) API
    func searchLocations(_ query: String) {
        searchTask?.cancel()

        print("[Search] Query: '\(query)'")

        guard !query.isEmpty, query.count >= 2 else {
            searchResults = []
            isSearching = false
            return
        }

        isSearching = true

        searchTask = Task {
            // Small debounce
            try? await Task.sleep(for: .milliseconds(300))

            guard !Task.isCancelled else {
                print("[Search] Task cancelled")
                return
            }

            // Use Nominatim (OpenStreetMap) - free, no API key needed
            let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            let urlString = "https://nominatim.openstreetmap.org/search?q=\(encodedQuery)&format=json&limit=5&addressdetails=1"
            print("[Search] URL: \(urlString)")

            guard let url = URL(string: urlString) else {
                print("[Search] Invalid URL")
                isSearching = false
                return
            }

            do {
                var request = URLRequest(url: url)
                request.setValue("CircadianLights/1.0", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 10

                print("[Search] Fetching...")
                let (data, response) = try await URLSession.shared.data(for: request)
                print("[Search] Got response, \(data.count) bytes")

                guard !Task.isCancelled else { return }

                guard let httpResponse = response as? HTTPURLResponse else {
                    print("[Search] Not HTTP response")
                    searchResults = []
                    isSearching = false
                    return
                }

                print("[Search] HTTP \(httpResponse.statusCode)")

                guard httpResponse.statusCode == 200 else {
                    searchResults = []
                    isSearching = false
                    return
                }

                let results = try JSONDecoder().decode([NominatimResult].self, from: data)
                print("[Search] Decoded \(results.count) results")

                searchResults = results.compactMap { result -> LocationResult? in
                    guard let lat = Double(result.lat),
                          let lon = Double(result.lon) else { return nil }

                    let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)

                    let name = result.address?.city
                        ?? result.address?.town
                        ?? result.address?.village
                        ?? result.name

                    var subtitleParts: [String] = []
                    if let state = result.address?.state {
                        subtitleParts.append(state)
                    }
                    if let country = result.address?.country {
                        subtitleParts.append(country)
                    }

                    return LocationResult(
                        name: name,
                        coordinate: coordinate,
                        subtitle: subtitleParts.joined(separator: ", ")
                    )
                }

                print("[Search] Final results: \(searchResults.count)")
                isSearching = false
            } catch {
                print("[Search] Error: \(error)")
                searchResults = []
                isSearching = false
            }
        }
    }

    /// Select a location from search results
    func selectLocation(_ result: LocationResult) {
        currentLocation = result.coordinate
        locationName = result.subtitle.isEmpty ? result.name : "\(result.name), \(result.subtitle)"
        status = .manual
        searchQuery = ""
        searchResults = []
    }

    /// Request location - uses IP geolocation (fast and reliable)
    func detectLocation() async -> CLLocationCoordinate2D? {
        guard !isDetecting else { return currentLocation }

        isDetecting = true
        status = .detecting

        // Use IP geolocation - fast, reliable, no permissions needed
        if let location = await fetchIPLocation() {
            currentLocation = location
            status = .usingIP
            isDetecting = false
            return location
        }

        // If IP fails, return nil
        status = .error
        isDetecting = false
        return nil
    }

    /// Fetch location from IP geolocation API
    private func fetchIPLocation() async -> CLLocationCoordinate2D? {
        // Try ip-api.com (free, no API key required)
        guard let url = URL(string: "http://ip-api.com/json/?fields=status,lat,lon,city,regionName,country") else {
            return nil
        }

        do {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 10
            let session = URLSession(configuration: config)

            let (data, response) = try await session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("IP API returned non-200 status")
                return nil
            }

            let apiResponse = try JSONDecoder().decode(IPAPIResponse.self, from: data)

            if apiResponse.status == "success" {
                let location = CLLocationCoordinate2D(latitude: apiResponse.lat, longitude: apiResponse.lon)

                // Build location name
                var nameParts: [String] = []
                if let city = apiResponse.city, !city.isEmpty {
                    nameParts.append(city)
                }
                if let region = apiResponse.regionName, !region.isEmpty, region != apiResponse.city {
                    nameParts.append(region)
                }
                if let country = apiResponse.country, !country.isEmpty {
                    nameParts.append(country)
                }
                locationName = nameParts.joined(separator: ", ")

                print("IP Location: \(locationName) (\(location.latitude), \(location.longitude))")
                return location
            } else {
                print("IP API status: \(apiResponse.status)")
            }
        } catch {
            print("IP geolocation failed: \(error)")
        }

        return nil
    }

    /// Set location manually
    func setManualLocation(latitude: Double, longitude: Double, name: String? = nil) {
        currentLocation = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        status = .manual
        locationName = name ?? String(format: "%.4f, %.4f", latitude, longitude)
    }
}

// MARK: - API Response Models

private struct IPAPIResponse: Codable {
    let status: String
    let lat: Double
    let lon: Double
    let city: String?
    let regionName: String?
    let country: String?
}

private struct NominatimResult: Codable {
    let lat: String
    let lon: String
    let name: String
    let displayName: String?
    let address: NominatimAddress?

    enum CodingKeys: String, CodingKey {
        case lat, lon, name
        case displayName = "display_name"
        case address
    }
}

private struct NominatimAddress: Codable {
    let city: String?
    let town: String?
    let village: String?
    let state: String?
    let country: String?
}
