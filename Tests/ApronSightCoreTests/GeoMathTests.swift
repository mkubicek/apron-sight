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

    func testDeadReckonedCoordinateMovesAlongTrack() {
        let anchor = GeoCoordinate(latitudeDegrees: 47.4647, longitudeDegrees: 8.5492, altitudeMeters: 432)

        let shifted = GeoMath.deadReckonedCoordinate(
            from: anchor,
            velocityMetersPerSecond: 100,
            trueTrackDegrees: 90,
            verticalRateMetersPerSecond: 2,
            elapsedSeconds: 10
        )
        let placement = GeoMath.placement(observer: anchor, target: shifted)

        XCTAssertEqual(placement.enu.east, 1000, accuracy: 0.5)
        XCTAssertEqual(placement.enu.north, 0, accuracy: 0.5)
        XCTAssertEqual(placement.enu.up, 20, accuracy: 0.1)
    }

    func testDeadReckoningElapsedSecondsIsBounded() {
        let capturedAt = Date(timeIntervalSinceReferenceDate: 100)

        XCTAssertEqual(
            GeoMath.deadReckoningElapsedSeconds(capturedAt: capturedAt, date: capturedAt.addingTimeInterval(300)),
            GeoMath.maximumDeadReckoningSeconds,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            GeoMath.deadReckoningElapsedSeconds(capturedAt: capturedAt, date: capturedAt.addingTimeInterval(-5)),
            0,
            accuracy: 0.000_001
        )
    }

    func testDeadReckonedCoordinateClampsStaleElapsedSeconds() {
        let anchor = GeoCoordinate(latitudeDegrees: 47.4647, longitudeDegrees: 8.5492, altitudeMeters: 432)

        let shifted = GeoMath.deadReckonedCoordinate(
            from: anchor,
            velocityMetersPerSecond: 250,
            trueTrackDegrees: 0,
            verticalRateMetersPerSecond: -1,
            elapsedSeconds: 300
        )
        let placement = GeoMath.placement(observer: anchor, target: shifted)

        XCTAssertEqual(placement.enu.north, 250 * GeoMath.maximumDeadReckoningSeconds, accuracy: 10)
        XCTAssertEqual(placement.enu.east, 0, accuracy: 0.5)
        XCTAssertEqual(shifted.altitudeMeters - anchor.altitudeMeters, -GeoMath.maximumDeadReckoningSeconds, accuracy: 0.000_001)
    }

    func testLocationPresetsExposeExpectedCoordinates() {
        let home = LocationPreset.home.coordinate
        let zrhObservationDeck = LocationPreset.zrhObservationDeck.coordinate
        let zrhCenter = LocationPreset.zrhCenter.coordinate

        XCTAssertEqual(home.latitudeDegrees, 47.333580, accuracy: 0.000_001)
        XCTAssertEqual(home.longitudeDegrees, 8.519790, accuracy: 0.000_001)
        XCTAssertEqual(home.altitudeMeters, 420, accuracy: 0.001)

        XCTAssertEqual(zrhObservationDeck.latitudeDegrees, 47.451210, accuracy: 0.000_001)
        XCTAssertEqual(zrhObservationDeck.longitudeDegrees, 8.557410, accuracy: 0.000_001)
        XCTAssertEqual(zrhObservationDeck.altitudeMeters, 432, accuracy: 0.001)

        XCTAssertEqual(zrhCenter.latitudeDegrees, 47.464700, accuracy: 0.000_001)
        XCTAssertEqual(zrhCenter.longitudeDegrees, 8.549200, accuracy: 0.000_001)
        XCTAssertEqual(zrhCenter.altitudeMeters, 432, accuracy: 0.001)
    }
}
