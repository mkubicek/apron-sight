import Foundation

/// Origin and destination airports for a flight.
///
/// Two sources, in order of preference:
///   1. **scheduled** — adsbdb.com's volunteer-curated callsign→route
///      database. Accurate for the *current* flight when it resolves.
///      Coverage is patchy: ATC suffix-letter callsigns
///      (e.g. `EWG7DL`, `BAW2QH`) are largely missing.
///   2. **previous** — OpenSky's `/flights/aircraft` history, keyed by
///      the aircraft's icao24 hex. Returns the most recent *completed*
///      flight, so the user is shown where this airframe just came
///      from, not where it's going. The UI labels this distinction.
public struct FlightRoute: Equatable, Sendable {
    public enum Kind: Sendable, Equatable {
        case scheduled
        case previous
    }

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

    public let kind: Kind
    public let origin: Airport?
    public let destination: Airport?

    public init(kind: Kind, origin: Airport?, destination: Airport?) {
        self.kind = kind
        self.origin = origin
        self.destination = destination
    }
}

/// Process-wide cache + network adapter for flight route lookups.
///
/// Caches positive AND negative results so unknown callsigns/aircraft
/// don't retry on every selection. The OpenSky fallback is opt-in:
/// the app injects a configured client via `setOpenSkyClient(_:)` at
/// startup; without it, only the adsbdb path runs.
public actor FlightRouteLookup {
    public static let shared = FlightRouteLookup()

    private var callsignCache: [String: FlightRoute?] = [:]
    private var icao24Cache: [String: FlightRoute?] = [:]
    private let session: URLSession
    private var openSkyClient: OpenSkyClient?

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func setOpenSkyClient(_ client: OpenSkyClient?) {
        self.openSkyClient = client
    }

    /// Resolves the best available route for a flight. Tries adsbdb
    /// (scheduled, current) first; if that misses and an icao24 hex is
    /// available, falls back to the OpenSky history (previous flight).
    public func route(forCallsign callsign: String, icao24: String? = nil) async -> FlightRoute? {
        let callsignKey = callsign
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        if !callsignKey.isEmpty {
            if let cached = callsignCache[callsignKey] {
                if let cached { return cached }
            } else {
                let scheduled = await fetchScheduled(callsign: callsignKey)
                callsignCache[callsignKey] = scheduled
                if let scheduled { return scheduled }
            }
        }

        guard let icao24 = icao24?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !icao24.isEmpty
        else {
            return nil
        }

        if let cached = icao24Cache[icao24] {
            return cached
        }

        let previous = await fetchPrevious(icao24: icao24)
        icao24Cache[icao24] = previous
        return previous
    }

    public func route(forCallsign callsign: String) async -> FlightRoute? {
        await route(forCallsign: callsign, icao24: nil)
    }

    private func fetchPrevious(icao24: String) async -> FlightRoute? {
        guard let client = openSkyClient else { return nil }

        let flights: [OpenSkyFlight]
        do {
            flights = try await client.flightHistory(forICAO24: icao24)
        } catch {
            return nil
        }

        guard let mostRecent = flights.first else { return nil }
        let origin = mostRecent.estDepartureAirport.map {
            FlightRoute.Airport(icao: $0, iata: nil, name: nil)
        }
        let destination = mostRecent.estArrivalAirport.map {
            FlightRoute.Airport(icao: $0, iata: nil, name: nil)
        }
        guard origin != nil || destination != nil else { return nil }
        return FlightRoute(kind: .previous, origin: origin, destination: destination)
    }

    private func fetchScheduled(callsign: String) async -> FlightRoute? {
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
                kind: .scheduled,
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
