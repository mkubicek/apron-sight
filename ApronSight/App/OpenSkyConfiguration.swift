import Foundation
import FlightFeed

enum OpenSkyConfiguration {
    static var livePollIntervalSeconds: TimeInterval {
        credentials == nil ? 10 : 5
    }

    static func makeLiveFlightProvider() -> any FlightProvider {
        makeOpenSkyClient()
    }

    /// Returns the same `OpenSkyClient` shape used for the live feed,
    /// suitable for handing to other consumers (route history, etc.).
    /// Each consumer gets its own instance — they share credentials
    /// but maintain independent OAuth token caches, which is fine.
    static func makeOpenSkyClient() -> OpenSkyClient {
        guard let credentials else {
            return OpenSkyClient.anonymous()
        }

        return OpenSkyClient.oauth(
            clientID: credentials.clientID,
            clientSecret: credentials.clientSecret
        )
    }

    private static var credentials: Credentials? {
        bundleCredentials ?? environmentCredentials
    }

    private static var bundleCredentials: Credentials? {
        guard
            let url = Bundle.main.url(forResource: "OpenSkyCredentials", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let credentials = try? JSONDecoder().decode(Credentials.self, from: data)
        else {
            return nil
        }

        return normalized(credentials)
    }

    private static var environmentCredentials: Credentials? {
        guard
            let clientID = normalized(ProcessInfo.processInfo.environment["OPEN_SKY_CLIENT_ID"]),
            let clientSecret = normalized(ProcessInfo.processInfo.environment["OPEN_SKY_CLIENT_SECRET"])
        else {
            return nil
        }

        return Credentials(clientID: clientID, clientSecret: clientSecret)
    }

    private static func normalized(_ credentials: Credentials) -> Credentials? {
        guard
            let clientID = normalized(credentials.clientID),
            let clientSecret = normalized(credentials.clientSecret)
        else {
            return nil
        }

        return Credentials(clientID: clientID, clientSecret: clientSecret)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else {
            return nil
        }

        return trimmed
    }

    private struct Credentials: Decodable {
        let clientID: String
        let clientSecret: String

        enum CodingKeys: String, CodingKey {
            case clientID = "clientId"
            case clientSecret
        }
    }
}
