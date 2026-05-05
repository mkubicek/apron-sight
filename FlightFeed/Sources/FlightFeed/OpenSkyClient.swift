import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Live flight data from the OpenSky Network.
///
/// OpenSky offers three access tiers:
///   1. Anonymous   — no credentials, ~10s minimum poll, ~400 calls/day per IP.
///   2. Basic auth  — legacy username/password, deprecated by OpenSky.
///   3. OAuth2 client credentials — current method, get a client ID/secret at
///      https://opensky-network.org/my-opensky/credentials.
///
/// Construct one of:
///   - `OpenSkyClient.anonymous()`
///   - `OpenSkyClient.basicAuth(username:password:)`
///   - `OpenSkyClient.oauth(clientID:clientSecret:)`
public final class OpenSkyClient: FlightProvider, @unchecked Sendable {

    public enum Credentials: Sendable {
        case anonymous
        case basic(username: String, password: String)
        case oauth(clientID: String, clientSecret: String)
    }

    public static let defaultStatesURL = URL(string: "https://opensky-network.org/api/states/all")!
    public static let defaultFlightsByAircraftURL = URL(
        string: "https://opensky-network.org/api/flights/aircraft"
    )!
    public static let defaultTokenURL = URL(
        string: "https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token"
    )!

    private let credentials: Credentials
    private let session: URLSession
    private let statesURL: URL
    private let flightsByAircraftURL: URL
    private let tokenURL: URL
    private let tokenStore = TokenStore()

    public init(
        credentials: Credentials = .anonymous,
        session: URLSession = .shared,
        statesURL: URL = OpenSkyClient.defaultStatesURL,
        flightsByAircraftURL: URL = OpenSkyClient.defaultFlightsByAircraftURL,
        tokenURL: URL = OpenSkyClient.defaultTokenURL
    ) {
        self.credentials = credentials
        self.session = session
        self.statesURL = statesURL
        self.flightsByAircraftURL = flightsByAircraftURL
        self.tokenURL = tokenURL
    }

    public static func anonymous(session: URLSession = .shared) -> OpenSkyClient {
        OpenSkyClient(credentials: .anonymous, session: session)
    }

    public static func basicAuth(username: String, password: String, session: URLSession = .shared) -> OpenSkyClient {
        OpenSkyClient(credentials: .basic(username: username, password: password), session: session)
    }

    public static func oauth(clientID: String, clientSecret: String, session: URLSession = .shared) -> OpenSkyClient {
        OpenSkyClient(credentials: .oauth(clientID: clientID, clientSecret: clientSecret), session: session)
    }

    public func snapshot(for region: RadiusRegion) async throws -> FlightSnapshot {
        let box = region.boundingBox
        var components = URLComponents(url: statesURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "lamin", value: format(box.latMin)),
            URLQueryItem(name: "lomin", value: format(box.lonMin)),
            URLQueryItem(name: "lamax", value: format(box.latMax)),
            URLQueryItem(name: "lomax", value: format(box.lonMax)),
            URLQueryItem(name: "extended", value: "1")
        ]
        guard let url = components.url else {
            throw FlightFeedError.transport(URLError(.badURL))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        try await applyAuth(to: &request)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FlightFeedError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw FlightFeedError.transport(URLError(.badServerResponse))
        }

        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw FlightFeedError.authentication("status \(http.statusCode)")
        case 429:
            let retry = retryAfterSeconds(from: http)
            throw FlightFeedError.rateLimited(retryAfter: retry)
        default:
            let body = String(data: data, encoding: .utf8)
            throw FlightFeedError.http(status: http.statusCode, body: body)
        }

        let parsed = try OpenSkyParser.parse(data: data, region: region)
        // Server-side bbox is loose; tighten to the true radius circle.
        let filtered = parsed.flights.filter {
            region.contains(latitude: $0.latitudeDegrees, longitude: $0.longitudeDegrees)
        }
        return FlightSnapshot(flights: filtered, capturedAt: parsed.capturedAt, region: region)
    }

    /// Returns up to a window of completed flights for a single aircraft,
    /// most-recent first. OpenSky rejects windows wider than ~30 days; we
    /// default to 7 to keep the response small. The endpoint only returns
    /// flights that have already landed, so for an in-flight aircraft you
    /// get the *previous* leg, not the current one.
    public func flightHistory(
        forICAO24 icao24: String,
        lookbackDays: Int = 7,
        now: Date = Date()
    ) async throws -> [OpenSkyFlight] {
        let lower = icao24.lowercased()
        let end = Int(now.timeIntervalSince1970)
        let begin = end - max(lookbackDays, 1) * 86_400

        var components = URLComponents(url: flightsByAircraftURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "icao24", value: lower),
            URLQueryItem(name: "begin", value: String(begin)),
            URLQueryItem(name: "end", value: String(end))
        ]
        guard let url = components.url else {
            throw FlightFeedError.transport(URLError(.badURL))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        try await applyAuth(to: &request)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FlightFeedError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw FlightFeedError.transport(URLError(.badServerResponse))
        }

        switch http.statusCode {
        case 200:
            break
        // OpenSky returns 404 when the aircraft has no flights in the window.
        case 404:
            return []
        case 401, 403:
            throw FlightFeedError.authentication("status \(http.statusCode)")
        case 429:
            throw FlightFeedError.rateLimited(retryAfter: retryAfterSeconds(from: http))
        default:
            let body = String(data: data, encoding: .utf8)
            throw FlightFeedError.http(status: http.statusCode, body: body)
        }

        do {
            let decoded = try JSONDecoder().decode([OpenSkyFlightDTO].self, from: data)
            return decoded
                .map { $0.toFlight() }
                .sorted { $0.lastSeen > $1.lastSeen }
        } catch {
            throw FlightFeedError.decoding("flights/aircraft response: \(error)")
        }
    }

    private func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        let headerNames = [
            "X-Rate-Limit-Retry-After-Seconds",
            "Retry-After"
        ]
        for headerName in headerNames {
            guard let value = response.value(forHTTPHeaderField: headerName) else {
                continue
            }

            if let seconds = TimeInterval(value) {
                return seconds
            }
        }

        return nil
    }

    // MARK: - Auth

    private func applyAuth(to request: inout URLRequest) async throws {
        switch credentials {
        case .anonymous:
            return
        case .basic(let username, let password):
            let credential = "\(username):\(password)"
            let encoded = Data(credential.utf8).base64EncodedString()
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        case .oauth(let clientID, let clientSecret):
            let token = try await tokenStore.token { [self] in
                try await fetchOAuthToken(clientID: clientID, clientSecret: clientSecret)
            }
            request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        }
    }

    private func fetchOAuthToken(clientID: String, clientSecret: String) async throws -> OAuthToken {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=client_credentials"
            + "&client_id=\(percentEncode(clientID))"
            + "&client_secret=\(percentEncode(clientSecret))"
        request.httpBody = Data(body.utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FlightFeedError.transport(error)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw FlightFeedError.authentication("token endpoint returned \(status)")
        }
        struct TokenResponse: Decodable {
            let access_token: String
            let expires_in: Int
        }
        do {
            let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
            // Refresh 60s early to avoid mid-flight expiry.
            let expiresAt = Date().addingTimeInterval(TimeInterval(max(decoded.expires_in - 60, 30)))
            return OAuthToken(accessToken: decoded.access_token, expiresAt: expiresAt)
        } catch {
            throw FlightFeedError.decoding("token response: \(error)")
        }
    }

    private func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }
}

/// A single completed flight returned by OpenSky's `/flights/aircraft`
/// endpoint. Departure and arrival airports are 4-letter ICAO codes
/// estimated from the track — either side can be `nil` when the
/// estimate failed.
public struct OpenSkyFlight: Equatable, Sendable {
    public let icao24: String
    public let firstSeen: Date
    public let lastSeen: Date
    public let estDepartureAirport: String?
    public let estArrivalAirport: String?
    public let callsign: String?

    public init(
        icao24: String,
        firstSeen: Date,
        lastSeen: Date,
        estDepartureAirport: String?,
        estArrivalAirport: String?,
        callsign: String?
    ) {
        self.icao24 = icao24
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.estDepartureAirport = estDepartureAirport
        self.estArrivalAirport = estArrivalAirport
        self.callsign = callsign
    }
}

private struct OpenSkyFlightDTO: Decodable {
    let icao24: String
    let firstSeen: Int
    let lastSeen: Int
    let estDepartureAirport: String?
    let estArrivalAirport: String?
    let callsign: String?

    func toFlight() -> OpenSkyFlight {
        OpenSkyFlight(
            icao24: icao24,
            firstSeen: Date(timeIntervalSince1970: TimeInterval(firstSeen)),
            lastSeen: Date(timeIntervalSince1970: TimeInterval(lastSeen)),
            estDepartureAirport: estDepartureAirport,
            estArrivalAirport: estArrivalAirport,
            callsign: callsign?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

struct OAuthToken: Sendable {
    let accessToken: String
    let expiresAt: Date
}

actor TokenStore {
    private var current: OAuthToken?

    func token(refresh: () async throws -> OAuthToken) async throws -> OAuthToken {
        if let current, current.expiresAt > Date() {
            return current
        }
        let fresh = try await refresh()
        current = fresh
        return fresh
    }
}
