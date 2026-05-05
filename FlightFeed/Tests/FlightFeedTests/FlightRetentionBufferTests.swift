import XCTest
@testable import FlightFeed

final class FlightRetentionBufferTests: XCTestCase {

    private let zurichRegion = RadiusRegion(
        latitudeDegrees: 47.45,
        longitudeDegrees: 8.55,
        radiusKm: 50
    )

    // MARK: - Ingest + retention

    func testFirstSnapshotPopulatesBuffer() {
        var buffer = FlightRetentionBuffer(retentionSeconds: 90)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        buffer.ingest(makeSnapshot(
            flights: [makeFlight(id: "abc123", altitude: 5000)],
            at: now
        ))

        XCTAssertEqual(buffer.count, 1)
        XCTAssertEqual(buffer.latestCapturedAt, now)
    }

    func testFlightMissingFromNextSnapshotStaysRetained() {
        var buffer = FlightRetentionBuffer(retentionSeconds: 90)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(10)

        buffer.ingest(makeSnapshot(
            flights: [
                makeFlight(id: "abc123", altitude: 5000),
                makeFlight(id: "def456", altitude: 6000)
            ],
            at: t0
        ))
        buffer.ingest(makeSnapshot(
            flights: [makeFlight(id: "abc123", altitude: 5100)],
            at: t1
        ))

        XCTAssertEqual(buffer.count, 2, "def456 should stay in the buffer through one missing poll")
        let def = buffer.entries.first { $0.flight.id == "def456" }
        XCTAssertEqual(def?.capturedAt, t0, "silent flights keep their original capturedAt")
    }

    func testFlightSilentLongerThanRetentionIsEvicted() {
        var buffer = FlightRetentionBuffer(retentionSeconds: 90)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let tFar = t0.addingTimeInterval(91)

        buffer.ingest(makeSnapshot(
            flights: [
                makeFlight(id: "abc123", altitude: 5000),
                makeFlight(id: "def456", altitude: 6000)
            ],
            at: t0
        ))
        buffer.ingest(makeSnapshot(
            flights: [makeFlight(id: "abc123", altitude: 5100)],
            at: tFar
        ))

        XCTAssertEqual(buffer.count, 1)
        XCTAssertNil(buffer.entries.first { $0.flight.id == "def456" })
    }

    func testEntriesAtFiltersStaleEntries() {
        var buffer = FlightRetentionBuffer(retentionSeconds: 90)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        buffer.ingest(makeSnapshot(
            flights: [makeFlight(id: "abc123", altitude: 5000)],
            at: t0
        ))

        XCTAssertEqual(buffer.entries(at: t0).count, 1)
        XCTAssertEqual(buffer.entries(at: t0.addingTimeInterval(89)).count, 1)
        XCTAssertEqual(buffer.entries(at: t0.addingTimeInterval(91)).count, 0,
                       "Entries beyond the retention window are filtered at read time")
    }

    func testClearEmptiesBuffer() {
        var buffer = FlightRetentionBuffer(retentionSeconds: 90)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        buffer.ingest(makeSnapshot(
            flights: [makeFlight(id: "abc123", altitude: 5000)],
            at: t0
        ))

        buffer.clear()

        XCTAssertEqual(buffer.count, 0)
        XCTAssertNil(buffer.latestCapturedAt)
    }

    // MARK: - Field preservation on merge

    func testNilAltitudeFromNewSnapshotKeepsLastKnownAltitude() {
        var buffer = FlightRetentionBuffer(retentionSeconds: 90)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(5)

        buffer.ingest(makeSnapshot(
            flights: [makeFlight(id: "abc123", altitude: 5000)],
            at: t0
        ))
        buffer.ingest(makeSnapshot(
            flights: [makeFlight(id: "abc123", altitude: nil)],
            at: t1
        ))

        let entry = buffer.entries.first { $0.flight.id == "abc123" }
        XCTAssertEqual(entry?.flight.altitudeMeters, 5000,
                       "Last known altitude must be preserved when the new snapshot reports nil")
    }

    func testNonNilAltitudeFromNewSnapshotOverwrites() {
        var buffer = FlightRetentionBuffer(retentionSeconds: 90)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(5)

        buffer.ingest(makeSnapshot(
            flights: [makeFlight(id: "abc123", altitude: 5000)],
            at: t0
        ))
        buffer.ingest(makeSnapshot(
            flights: [makeFlight(id: "abc123", altitude: 5500)],
            at: t1
        ))

        let entry = buffer.entries.first { $0.flight.id == "abc123" }
        XCTAssertEqual(entry?.flight.altitudeMeters, 5500)
    }

    func testHardFieldsAlwaysComeFromNewSnapshot() {
        var buffer = FlightRetentionBuffer(retentionSeconds: 90)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(5)

        buffer.ingest(makeSnapshot(
            flights: [makeFlight(id: "abc123", altitude: 5000, lat: 47.0, lon: 8.0)],
            at: t0
        ))
        buffer.ingest(makeSnapshot(
            flights: [makeFlight(id: "abc123", altitude: nil, lat: 47.5, lon: 8.5)],
            at: t1
        ))

        let entry = buffer.entries.first { $0.flight.id == "abc123" }
        XCTAssertEqual(entry?.flight.latitudeDegrees, 47.5,
                       "Latitude is a hard field, must take the new value")
        XCTAssertEqual(entry?.flight.longitudeDegrees, 8.5)
        XCTAssertEqual(entry?.flight.altitudeMeters, 5000,
                       "Altitude is a soft field, falls back when new is nil")
    }

    func testAllSoftFieldsPreservedTogether() {
        var buffer = FlightRetentionBuffer(retentionSeconds: 90)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(5)

        let original = LiveFlight(
            id: "abc123",
            callsign: "BAW283",
            originCountry: "United Kingdom",
            latitudeDegrees: 47.0,
            longitudeDegrees: 8.0,
            altitudeMeters: 5000,
            velocityMetersPerSecond: 240,
            trueTrackDegrees: 90,
            verticalRateMetersPerSecond: 5,
            isOnGround: false,
            positionTimestamp: t0,
            lastContact: t0
        )
        let stripped = LiveFlight(
            id: "abc123",
            callsign: "",
            originCountry: nil,
            latitudeDegrees: 47.1,
            longitudeDegrees: 8.1,
            altitudeMeters: nil,
            velocityMetersPerSecond: nil,
            trueTrackDegrees: nil,
            verticalRateMetersPerSecond: nil,
            isOnGround: false,
            positionTimestamp: t1,
            lastContact: t1
        )
        buffer.ingest(makeSnapshot(flights: [original], at: t0))
        buffer.ingest(makeSnapshot(flights: [stripped], at: t1))

        let entry = buffer.entries.first { $0.flight.id == "abc123" }!.flight
        XCTAssertEqual(entry.callsign, "BAW283")
        XCTAssertEqual(entry.originCountry, "United Kingdom")
        XCTAssertEqual(entry.altitudeMeters, 5000)
        XCTAssertEqual(entry.velocityMetersPerSecond, 240)
        XCTAssertEqual(entry.trueTrackDegrees, 90)
        XCTAssertEqual(entry.verticalRateMetersPerSecond, 5)
        XCTAssertEqual(entry.latitudeDegrees, 47.1, "Hard field always overrides")
    }

    func testGroundMergeDropsStaleAirborneKinematics() {
        var buffer = FlightRetentionBuffer(retentionSeconds: 90)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(5)

        buffer.ingest(makeSnapshot(
            flights: [
                makeFlight(
                    id: "abc123",
                    altitude: 500,
                    velocity: 74,
                    track: 140,
                    verticalRate: -4.5,
                    onGround: false
                )
            ],
            at: t0
        ))
        buffer.ingest(makeSnapshot(
            flights: [
                makeFlight(
                    id: "abc123",
                    altitude: 457.2,
                    velocity: nil,
                    track: nil,
                    verticalRate: nil,
                    onGround: true
                )
            ],
            at: t1
        ))

        let entry = buffer.entries.first { $0.flight.id == "abc123" }!.flight
        XCTAssertEqual(entry.velocityMetersPerSecond, 0)
        XCTAssertNil(entry.trueTrackDegrees)
        XCTAssertEqual(entry.verticalRateMetersPerSecond, 0)
        XCTAssertTrue(entry.isOnGround)
    }

    func testGroundMergeDoesNotKeepAirborneAltitudeWhenGroundAltitudeMissing() {
        var buffer = FlightRetentionBuffer(retentionSeconds: 90)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(5)

        buffer.ingest(makeSnapshot(
            flights: [
                makeFlight(
                    id: "abc123",
                    altitude: 900,
                    velocity: 74,
                    track: 140,
                    verticalRate: -4.5,
                    onGround: false
                )
            ],
            at: t0
        ))
        buffer.ingest(makeSnapshot(
            flights: [
                makeFlight(
                    id: "abc123",
                    altitude: nil,
                    velocity: 0,
                    track: 5.62,
                    verticalRate: nil,
                    onGround: true
                )
            ],
            at: t1
        ))

        let entry = buffer.entries.first { $0.flight.id == "abc123" }!.flight
        XCTAssertNil(entry.altitudeMeters)
        XCTAssertTrue(entry.isOnGround)
    }

    func testGroundMergeKeepsPreviousGroundAltitudeWhenGroundAltitudeMissing() {
        var buffer = FlightRetentionBuffer(retentionSeconds: 90)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(5)

        buffer.ingest(makeSnapshot(
            flights: [
                makeFlight(
                    id: "abc123",
                    altitude: 457.2,
                    velocity: 0,
                    track: 5.62,
                    verticalRate: 0,
                    onGround: true
                )
            ],
            at: t0
        ))
        buffer.ingest(makeSnapshot(
            flights: [
                makeFlight(
                    id: "abc123",
                    altitude: nil,
                    velocity: 0,
                    track: 5.62,
                    verticalRate: nil,
                    onGround: true
                )
            ],
            at: t1
        ))

        let entry = buffer.entries.first { $0.flight.id == "abc123" }!.flight
        XCTAssertEqual(entry.altitudeMeters, 457.2)
        XCTAssertTrue(entry.isOnGround)
    }

    func testStaleSnapshotRowUsesAircraftTimestampsForRetention() {
        var buffer = FlightRetentionBuffer(retentionSeconds: 90)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let staleFlight = makeFlight(
            id: "abc123",
            altitude: 457.2,
            positionTimestamp: t0,
            lastContact: t0
        )

        buffer.ingest(FlightSnapshot(
            flights: [staleFlight],
            capturedAt: t0.addingTimeInterval(120),
            region: zurichRegion
        ))

        XCTAssertEqual(buffer.count, 0)
    }

    func testOutOfOrderSnapshotDoesNotMoveExistingAircraftBackward() {
        var buffer = FlightRetentionBuffer(retentionSeconds: 90)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(10)

        buffer.ingest(makeSnapshot(
            flights: [makeFlight(id: "abc123", altitude: 5000, lat: 47.5, lon: 8.5)],
            at: t1
        ))
        buffer.ingest(makeSnapshot(
            flights: [makeFlight(id: "abc123", altitude: 4800, lat: 47.0, lon: 8.0)],
            at: t0
        ))

        let entry = buffer.entries.first { $0.flight.id == "abc123" }
        XCTAssertEqual(buffer.latestCapturedAt, t1)
        XCTAssertEqual(entry?.capturedAt, t1)
        XCTAssertEqual(entry?.flight.latitudeDegrees, 47.5)
        XCTAssertEqual(entry?.flight.longitudeDegrees, 8.5)
        XCTAssertEqual(entry?.flight.altitudeMeters, 5000)
    }

    func testOutOfOrderSnapshotCanRefreshAircraftWithoutNewerRow() {
        var buffer = FlightRetentionBuffer(retentionSeconds: 90)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(10)
        let t2 = t0.addingTimeInterval(20)

        buffer.ingest(makeSnapshot(
            flights: [
                makeFlight(id: "abc123", altitude: 5000),
                makeFlight(id: "def456", altitude: 6000, lat: 47.0, lon: 8.0)
            ],
            at: t0
        ))
        buffer.ingest(makeSnapshot(
            flights: [makeFlight(id: "abc123", altitude: 5100)],
            at: t2
        ))
        buffer.ingest(makeSnapshot(
            flights: [makeFlight(id: "def456", altitude: 6100, lat: 47.2, lon: 8.2)],
            at: t1
        ))

        let entry = buffer.entries.first { $0.flight.id == "def456" }
        XCTAssertEqual(buffer.latestCapturedAt, t2)
        XCTAssertEqual(entry?.capturedAt, t1)
        XCTAssertEqual(entry?.flight.latitudeDegrees, 47.2)
        XCTAssertEqual(entry?.flight.longitudeDegrees, 8.2)
        XCTAssertEqual(entry?.flight.altitudeMeters, 6100)
    }

    func testOutOfOrderSnapshotsRemainAvailableAsHistory() {
        var buffer = FlightRetentionBuffer(retentionSeconds: 90)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(10)
        let t2 = t0.addingTimeInterval(20)

        buffer.ingest(makeSnapshot(
            flights: [makeFlight(id: "abc123", altitude: 5200, lat: 47.2, lon: 8.2)],
            at: t2
        ))
        buffer.ingest(makeSnapshot(
            flights: [makeFlight(id: "abc123", altitude: 5100, lat: 47.1, lon: 8.1)],
            at: t1
        ))

        let track = buffer.tracks(at: t2).first { $0.id == "abc123" }
        XCTAssertEqual(track?.entries.map(\.capturedAt), [t1, t2])
        XCTAssertEqual(buffer.entries.first { $0.flight.id == "abc123" }?.capturedAt, t2)
    }

    func testLateHistoryRenormalizesLaterSoftFields() {
        var buffer = FlightRetentionBuffer(retentionSeconds: 90)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(10)
        let t2 = t0.addingTimeInterval(20)

        buffer.ingest(makeSnapshot(
            flights: [makeFlight(id: "abc123", altitude: 5000)],
            at: t0
        ))
        buffer.ingest(makeSnapshot(
            flights: [makeFlight(id: "abc123", altitude: nil)],
            at: t2
        ))
        buffer.ingest(makeSnapshot(
            flights: [makeFlight(id: "abc123", altitude: 5500)],
            at: t1
        ))

        let track = buffer.tracks(at: t2).first { $0.id == "abc123" }
        XCTAssertEqual(track?.entries.map { $0.flight.altitudeMeters }, [5000, 5500, 5500])
    }

    // MARK: - Helpers

    private func makeSnapshot(flights: [LiveFlight], at date: Date) -> FlightSnapshot {
        FlightSnapshot(
            flights: flights.map { stamp($0, at: date) },
            capturedAt: date,
            region: zurichRegion
        )
    }

    private func makeFlight(
        id: String,
        altitude: Double?,
        lat: Double = 47.45,
        lon: Double = 8.55,
        velocity: Double? = 200,
        track: Double? = 0,
        verticalRate: Double? = 0,
        onGround: Bool = false,
        positionTimestamp: Date = Date(timeIntervalSince1970: 1_700_000_000),
        lastContact: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> LiveFlight {
        LiveFlight(
            id: id,
            callsign: id.uppercased(),
            originCountry: "Test",
            latitudeDegrees: lat,
            longitudeDegrees: lon,
            altitudeMeters: altitude,
            velocityMetersPerSecond: velocity,
            trueTrackDegrees: track,
            verticalRateMetersPerSecond: verticalRate,
            isOnGround: onGround,
            positionTimestamp: positionTimestamp,
            lastContact: lastContact
        )
    }

    private func stamp(_ flight: LiveFlight, at date: Date) -> LiveFlight {
        LiveFlight(
            id: flight.id,
            callsign: flight.callsign,
            originCountry: flight.originCountry,
            latitudeDegrees: flight.latitudeDegrees,
            longitudeDegrees: flight.longitudeDegrees,
            altitudeMeters: flight.altitudeMeters,
            velocityMetersPerSecond: flight.velocityMetersPerSecond,
            trueTrackDegrees: flight.trueTrackDegrees,
            verticalRateMetersPerSecond: flight.verticalRateMetersPerSecond,
            isOnGround: flight.isOnGround,
            positionTimestamp: date,
            lastContact: date
        )
    }
}
