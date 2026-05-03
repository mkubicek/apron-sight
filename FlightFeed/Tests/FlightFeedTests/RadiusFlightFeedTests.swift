import XCTest
@testable import FlightFeed

final class RadiusFlightFeedTests: XCTestCase {

    func testEmitsSnapshotsFromMockProvider() async {
        let region = RadiusRegion(latitudeDegrees: 47.4647, longitudeDegrees: 8.5492, radiusKm: 80)
        let feed = RadiusFlightFeed(
            provider: MockFlightProvider(count: 4),
            region: region,
            pollInterval: 0.1,
            minPollInterval: 0.05
        )

        var collected: [FlightSnapshot] = []
        for await snapshot in feed.snapshots() {
            collected.append(snapshot)
            if collected.count >= 3 { break }
        }

        XCTAssertEqual(collected.count, 3)
        for snapshot in collected {
            XCTAssertEqual(snapshot.flights.count, 4)
            for flight in snapshot.flights {
                XCTAssertTrue(region.contains(latitude: flight.latitudeDegrees, longitude: flight.longitudeDegrees),
                              "mock placed flight outside the requested region")
            }
        }
    }

    func testForwardsErrorsToHandler() async {
        struct Failing: FlightProvider {
            func snapshot(for region: RadiusRegion) async throws -> FlightSnapshot {
                throw FlightFeedError.http(status: 500, body: "boom")
            }
        }
        let received = ErrorBox()
        let feed = RadiusFlightFeed(
            provider: Failing(),
            region: RadiusRegion(latitudeDegrees: 0, longitudeDegrees: 0, radiusKm: 1),
            pollInterval: 0.05,
            minPollInterval: 0.05
        ) { error in
            received.set(error)
        }

        let task = Task {
            for await _ in feed.snapshots() { /* never */ }
        }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()

        XCTAssertNotNil(received.value)
    }
}

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: (any Error)?
    func set(_ error: any Error) {
        lock.lock(); defer { lock.unlock() }
        _value = error
    }
    var value: (any Error)? {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
}
