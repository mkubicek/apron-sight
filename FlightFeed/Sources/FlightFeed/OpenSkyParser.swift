import Foundation

/// Parses the OpenSky Network `/states/all` JSON envelope.
///
/// OpenSky returns each state as a heterogeneous array of 17 fields, which is
/// awkward for `Codable`. We use `JSONSerialization` and decode by index using
/// the documented schema:
/// https://openskynetwork.github.io/opensky-api/rest.html#response
enum OpenSkyParser {

    struct ParseResult {
        let flights: [LiveFlight]
        let capturedAt: Date
    }

    static func parse(data: Data, region: RadiusRegion) throws -> ParseResult {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw FlightFeedError.decoding("invalid JSON: \(error)")
        }
        guard let object = json as? [String: Any] else {
            throw FlightFeedError.decoding("expected top-level object")
        }
        let serverTime = (object["time"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        let states = object["states"] as? [Any] ?? []  // null when no traffic in box

        var flights: [LiveFlight] = []
        flights.reserveCapacity(states.count)

        for raw in states {
            guard let row = raw as? [Any?], row.count >= 11 else { continue }
            guard let icao = row[0] as? String else { continue }

            // Drop aircraft with no current position fix — they would render
            // at (0, 0) which is worse than dropping them.
            guard let lon = row[5] as? Double else { continue }
            guard let lat = row[6] as? Double else { continue }

            let callsign = (row[1] as? String).map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            let originCountry = row[2] as? String
            let timePosition = (row[3] as? Double).map { Date(timeIntervalSince1970: $0) }
            let lastContact = (row[4] as? Double).map { Date(timeIntervalSince1970: $0) } ?? serverTime
            let baroAltitude = row[7] as? Double
            let onGround = (row[8] as? Bool) ?? false
            let velocity = row[9] as? Double
            let trueTrack = row[10] as? Double
            let reportedVerticalRate = row.count > 11 ? row[11] as? Double : nil
            let geoAltitude = row.count > 13 ? row[13] as? Double : nil
            let altitude = geoAltitude ?? baroAltitude
            let verticalRate = onGround ? 0 : reportedVerticalRate

            flights.append(
                LiveFlight(
                    id: icao.lowercased(),
                    callsign: callsign,
                    originCountry: originCountry,
                    latitudeDegrees: lat,
                    longitudeDegrees: lon,
                    altitudeMeters: altitude,
                    velocityMetersPerSecond: velocity,
                    trueTrackDegrees: trueTrack,
                    verticalRateMetersPerSecond: verticalRate,
                    isOnGround: onGround,
                    positionTimestamp: timePosition ?? lastContact,
                    lastContact: lastContact
                )
            )
        }

        return ParseResult(flights: flights, capturedAt: serverTime)
    }
}
