import XCTest
@testable import ApronSightCore

final class GeoMathTests: XCTestCase {
    func testSameCoordinateProducesZeroPlacement() {
        let coordinate = GeoCoordinate(latitudeDegrees: 47.333859, longitudeDegrees: 8.520262, altitudeMeters: 432)

        let placement = GeoMath.placement(observer: coordinate, target: coordinate)

        XCTAssertEqual(placement.horizontalDistanceMeters, 0, accuracy: 0.000_001)
        XCTAssertEqual(placement.slantDistanceMeters, 0, accuracy: 0.000_001)
        XCTAssertEqual(placement.bearingDegrees, 0, accuracy: 0.000_001)
        XCTAssertEqual(placement.elevationDegrees, 0, accuracy: 0.000_001)
    }

    func testSmallEastOffsetAtEquator() {
        let observer = GeoCoordinate(latitudeDegrees: 0, longitudeDegrees: 0)
        let target = GeoCoordinate(latitudeDegrees: 0, longitudeDegrees: 0.00089831528412)

        let placement = GeoMath.placement(observer: observer, target: target)

        XCTAssertEqual(placement.enu.east, 100, accuracy: 0.1)
        XCTAssertEqual(placement.enu.north, 0, accuracy: 0.01)
        XCTAssertEqual(placement.horizontalDistanceMeters, 100, accuracy: 0.1)
        XCTAssertEqual(placement.bearingDegrees, 90, accuracy: 0.1)
    }

    func testSmallNorthOffsetAtEquator() {
        let observer = GeoCoordinate(latitudeDegrees: 0, longitudeDegrees: 0)
        let target = GeoCoordinate(latitudeDegrees: 0.000904369477, longitudeDegrees: 0)

        let placement = GeoMath.placement(observer: observer, target: target)

        XCTAssertEqual(placement.enu.east, 0, accuracy: 0.01)
        XCTAssertEqual(placement.enu.north, 100, accuracy: 0.2)
        XCTAssertEqual(placement.horizontalDistanceMeters, 100, accuracy: 0.2)
        XCTAssertEqual(placement.bearingDegrees, 0, accuracy: 0.1)
    }

    func testDefaultHomeDemoPlacementIsDeterministic() {
        let placement = DemoScenario.defaultHomePlacement

        XCTAssertEqual(placement.enu.east, 35.68, accuracy: 0.1)
        XCTAssertEqual(placement.enu.north, 31.02, accuracy: 0.1)
        XCTAssertEqual(placement.enu.up, 12.0, accuracy: 0.1)
        XCTAssertEqual(placement.horizontalDistanceMeters, 47.28, accuracy: 0.1)
        XCTAssertEqual(placement.slantDistanceMeters, 48.78, accuracy: 0.1)
        XCTAssertEqual(placement.bearingDegrees, 48.99, accuracy: 0.1)
        XCTAssertEqual(placement.elevationDegrees, 14.24, accuracy: 0.1)
    }

    func testYawOffsetMapsBearingToLocalForward() {
        let dueEast = ENUCoordinate(east: 10, north: 0, up: 2)

        let local = GeoMath.localCoordinate(for: dueEast, yawOffsetDegrees: 90)

        XCTAssertEqual(local.x, 0, accuracy: 0.000_001)
        XCTAssertEqual(local.y, 2, accuracy: 0.000_001)
        XCTAssertEqual(local.z, -10, accuracy: 0.000_001)
    }

    func testLocalHorizontalOffsetInvertsYawMapping() {
        let local = GeoMath.localCoordinate(
            for: ENUCoordinate(east: 120, north: -40, up: 0),
            yawOffsetDegrees: 37
        )
        let enu = GeoMath.enuHorizontalOffset(
            localX: local.x,
            localZ: local.z,
            yawOffsetDegrees: 37
        )

        XCTAssertEqual(enu.east, 120, accuracy: 0.001)
        XCTAssertEqual(enu.north, -40, accuracy: 0.001)
    }

    func testCoordinateOffsetProducesExpectedPlacement() {
        let anchor = GeoCoordinate(latitudeDegrees: 47.333859, longitudeDegrees: 8.520262, altitudeMeters: 432)

        let shifted = GeoMath.coordinate(offsetFrom: anchor, eastMeters: 5, northMeters: -3, upMeters: 2)
        let placement = GeoMath.placement(observer: anchor, target: shifted)

        XCTAssertEqual(placement.enu.east, 5, accuracy: 0.01)
        XCTAssertEqual(placement.enu.north, -3, accuracy: 0.01)
        XCTAssertEqual(placement.enu.up, 2, accuracy: 0.01)
    }

    func testMockAircraftProviderIncludesTenDemoAircraft() {
        let aircraft = MockAircraftProvider().aircraft()

        XCTAssertEqual(aircraft.count, 10)
        XCTAssertEqual(Set(aircraft.map(\.id)).count, 10)
        XCTAssertTrue(aircraft.allSatisfy { ($0.velocityMetersPerSecond ?? 0) > 0 })
        XCTAssertTrue(aircraft.allSatisfy { (30 ... 80).contains($0.velocityMetersPerSecond ?? 0) })
        XCTAssertTrue(aircraft.allSatisfy { $0.trueTrackDegrees != nil })
    }
}
