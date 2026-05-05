import XCTest
@testable import FlightFeed

final class OpenSkyParserTests: XCTestCase {

    func testParsesRepresentativeResponse() throws {
        let payload = """
        {
          "time": 1714723200,
          "states": [
            ["abc123", "SWR214  ", "Switzerland", 1714723195, 1714723199, 8.5500, 47.4700, 950.0, false, 120.0, 90.0, 1.5, null, 970.0, "1234", false, 0],
            ["def456", null, "Germany", null, 1714723199, 8.5800, 47.4500, null, true, null, null, null, null, null, "0000", false, 0]
          ]
        }
        """
        let region = RadiusRegion(latitudeDegrees: 47.4647, longitudeDegrees: 8.5492, radiusKm: 50)
        let result = try OpenSkyParser.parse(data: Data(payload.utf8), region: region)

        XCTAssertEqual(result.flights.count, 2)
        XCTAssertEqual(result.capturedAt.timeIntervalSince1970, 1714723200, accuracy: 0.001)

        let first = result.flights[0]
        XCTAssertEqual(first.id, "abc123")
        XCTAssertEqual(first.callsign, "SWR214")  // trimmed
        XCTAssertEqual(first.originCountry, "Switzerland")
        XCTAssertEqual(first.altitudeMeters, 970.0)
        XCTAssertEqual(first.velocityMetersPerSecond, 120.0)
        XCTAssertEqual(first.trueTrackDegrees, 90.0)
        XCTAssertEqual(first.verticalRateMetersPerSecond, 1.5)
        XCTAssertFalse(first.isOnGround)

        let second = result.flights[1]
        XCTAssertEqual(second.callsign, "")
        XCTAssertTrue(second.isOnGround)
        XCTAssertNil(second.altitudeMeters)
        XCTAssertEqual(second.verticalRateMetersPerSecond, 0)
    }

    func testGroundStateZeroesReportedVerticalRate() throws {
        let payload = """
        {
          "time": 1714723200,
          "states": [
            ["abc123", "AUA147  ", "Austria", 1714723195, 1714723199, 8.5570, 47.4536, 457.2, true, 0.0, 5.62, -4.88, null, null, "1000", false, 0]
          ]
        }
        """
        let region = RadiusRegion(latitudeDegrees: 47.4647, longitudeDegrees: 8.5492, radiusKm: 50)
        let result = try OpenSkyParser.parse(data: Data(payload.utf8), region: region)

        XCTAssertEqual(result.flights.first?.verticalRateMetersPerSecond, 0)
    }

    func testHandlesNullStatesArray() throws {
        let payload = """
        { "time": 1714723200, "states": null }
        """
        let region = RadiusRegion(latitudeDegrees: 0, longitudeDegrees: 0, radiusKm: 10)
        let result = try OpenSkyParser.parse(data: Data(payload.utf8), region: region)
        XCTAssertEqual(result.flights.count, 0)
    }

    func testDropsRowsWithoutPositionFix() throws {
        let payload = """
        {
          "time": 1714723200,
          "states": [
            ["nopos", "GHOST", "Nowhere", null, 1714723199, null, null, null, false, null, null, null, null, null, null, false, 0]
          ]
        }
        """
        let region = RadiusRegion(latitudeDegrees: 0, longitudeDegrees: 0, radiusKm: 10000)
        let result = try OpenSkyParser.parse(data: Data(payload.utf8), region: region)
        XCTAssertEqual(result.flights.count, 0)
    }

    func testRejectsNonJSON() {
        let region = RadiusRegion(latitudeDegrees: 0, longitudeDegrees: 0, radiusKm: 10)
        XCTAssertThrowsError(try OpenSkyParser.parse(data: Data("not json".utf8), region: region)) { error in
            guard case FlightFeedError.decoding = error else {
                return XCTFail("expected decoding error, got \(error)")
            }
        }
    }
}
