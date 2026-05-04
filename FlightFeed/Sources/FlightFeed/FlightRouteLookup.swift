import Foundation

/// Origin and destination airports for a flight, looked up from
/// adsbdb.com's community-maintained callsign→route database.
///
/// adsbdb has good coverage for scheduled airlines (the callsign→route
/// mapping is volunteer-curated), and weak coverage for GA, military,
/// and unusual callsigns. Either side can be `nil` even when the
/// other resolves.
public struct FlightRoute: Equatable, Sendable {
    public struct Airport: Equatable, Sendable {
        public let icao: String?
        public let iata: String?
        public let name: String?

        public init(icao: String?, iata: String?, name: String?) {
            self.icao = icao
            self.iata = iata
            self.name = name
        }
    }

    public let origin: Airport?
    public let destination: Airport?

    public init(origin: Airport?, destination: Airport?) {
        self.origin = origin
        self.destination = destination
    }
}

/// Process-wide cache + network adapter for adsbdb callsign lookups.
///
/// adsbdb is a free community service with no published rate limits.
/// We cache by uppercased callsign for the lifetime of the actor so
/// repeat selections of the same flight don't hit the network. A `nil`
/// result is also cached (negative cache) so unknown callsigns don't
/// retry on every selection.
public actor FlightRouteLookup {
    public static let shared = FlightRouteLookup()

    private var cache: [String: FlightRoute?] = [:]
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func route(forCallsign callsign: String) async -> FlightRoute? {
        let key = callsign
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !key.isEmpty else { return nil }

        if let cached = cache[key] {
            return cached
        }

        let route = await fetch(callsign: key)
        cache[key] = route
        return route
    }

    private func fetch(callsign: String) async -> FlightRoute? {
        guard
            let escaped = callsign.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let url = URL(string: "https://api.adsbdb.com/v0/callsign/\(escaped)")
        else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("apron-sight/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8

        do {
            let (data, response) = try await session.data(for: request)
            guard
                let http = response as? HTTPURLResponse,
                200 ..< 300 ~= http.statusCode
            else {
                return nil
            }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let payload = try decoder.decode(ADSBDBResponse.self, from: data)
            guard let flightroute = payload.response?.flightroute else {
                return nil
            }

            return FlightRoute(
                origin: flightroute.origin?.toAirport(),
                destination: flightroute.destination?.toAirport()
            )
        } catch {
            return nil
        }
    }
}

private struct ADSBDBResponse: Decodable {
    let response: Inner?

    struct Inner: Decodable {
        let flightroute: Flightroute?
    }

    struct Flightroute: Decodable {
        let origin: Airport?
        let destination: Airport?
    }

    struct Airport: Decodable {
        let icaoCode: String?
        let iataCode: String?
        let name: String?

        func toAirport() -> FlightRoute.Airport {
            FlightRoute.Airport(icao: icaoCode, iata: iataCode, name: name)
        }
    }
}
