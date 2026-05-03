import Foundation

/// Deterministic provider for offline / test use. Returns a fixed set of
/// flights placed on a circle around the region centre, slowly rotating.
public final class MockFlightProvider: FlightProvider, @unchecked Sendable {

    private let count: Int
    private let startDate: Date

    public init(count: Int = 12, startDate: Date = Date()) {
        precondition(count > 0)
        self.count = count
        self.startDate = startDate
    }

    public func snapshot(for region: RadiusRegion) async throws -> FlightSnapshot {
        let now = Date()
        let secondsElapsed = now.timeIntervalSince(startDate)
        // Full revolution every 10 minutes.
        let rotationDegrees = (secondsElapsed / 600) * 360

        let radiusKm = region.radiusKm * 0.6
        var flights: [LiveFlight] = []
        flights.reserveCapacity(count)

        for i in 0..<count {
            let bearing = Double(i) * (360.0 / Double(count)) + rotationDegrees
            let (lat, lon) = Self.point(
                fromLat: region.latitudeDegrees,
                lon: region.longitudeDegrees,
                bearingDegrees: bearing,
                distanceKm: radiusKm
            )
            flights.append(
                LiveFlight(
                    id: String(format: "mock%03d", i),
                    callsign: String(format: "MOCK%03d", i),
                    originCountry: "Mockistan",
                    latitudeDegrees: lat,
                    longitudeDegrees: lon,
                    altitudeMeters: 1500 + Double(i) * 120,
                    velocityMetersPerSecond: 200,
                    trueTrackDegrees: bearing.truncatingRemainder(dividingBy: 360) + 90,
                    verticalRateMetersPerSecond: 0,
                    isOnGround: false,
                    positionTimestamp: now,
                    lastContact: now
                )
            )
        }
        return FlightSnapshot(flights: flights, capturedAt: now, region: region)
    }

    /// Forward geodesic on a sphere — good enough for a few hundred km.
    static func point(
        fromLat lat: Double,
        lon: Double,
        bearingDegrees bearing: Double,
        distanceKm: Double
    ) -> (Double, Double) {
        let r = 6371.0
        let δ = distanceKm / r
        let θ = bearing * .pi / 180
        let φ1 = lat * .pi / 180
        let λ1 = lon * .pi / 180
        let sinφ2 = sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ)
        let φ2 = asin(sinφ2)
        let y = sin(θ) * sin(δ) * cos(φ1)
        let x = cos(δ) - sin(φ1) * sinφ2
        let λ2 = λ1 + atan2(y, x)
        return (φ2 * 180 / .pi, λ2 * 180 / .pi)
    }
}
