import Foundation

/// Anything that can answer "what is currently flying inside this region?".
///
/// Concrete implementations include `OpenSkyClient` (live REST) and
/// `MockFlightProvider` (deterministic, for tests / offline UI).
public protocol FlightProvider: Sendable {
    func snapshot(for region: RadiusRegion) async throws -> FlightSnapshot
}

public enum FlightFeedError: Error, CustomStringConvertible, Sendable {
    case http(status: Int, body: String?)
    case rateLimited(retryAfter: TimeInterval?)
    case decoding(String)
    case authentication(String)
    case transport(any Error)

    public var description: String {
        switch self {
        case .http(let status, let body):
            return "http \(status)\(body.map { ": \($0)" } ?? "")"
        case .rateLimited(let retry):
            return "rate limited" + (retry.map { " (retry after \($0)s)" } ?? "")
        case .decoding(let detail):
            return "decoding failed: \(detail)"
        case .authentication(let detail):
            return "authentication failed: \(detail)"
        case .transport(let error):
            return "transport: \(error)"
        }
    }
}
