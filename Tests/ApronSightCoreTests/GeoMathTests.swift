import XCTest
@testable import ApronSightCore

final class GeoMathTests: XCTestCase {
    func testSceneBearingForwardIsZero() {
        let bearing = GeoMath.sceneBearingDegrees(from: .zero, to: SIMD3<Float>(0, 0, -1))
        XCTAssertEqual(bearing, 0, accuracy: 0.000_001)
    }

    func testSceneBearingRightIsNinety() {
        let bearing = GeoMath.sceneBearingDegrees(from: .zero, to: SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(bearing, 90, accuracy: 0.000_001)
    }

    func testSceneBearingBackIsOneEighty() {
        let bearing = GeoMath.sceneBearingDegrees(from: .zero, to: SIMD3<Float>(0, 0, 1))
        XCTAssertEqual(bearing, 180, accuracy: 0.000_001)
    }

    func testSceneBearingLeftIsTwoSeventy() {
        let bearing = GeoMath.sceneBearingDegrees(from: .zero, to: SIMD3<Float>(-1, 0, 0))
        XCTAssertEqual(bearing, 270, accuracy: 0.000_001)
    }

    func testSceneBearingIsRelativeToFromPoint() {
        // The user is at (5, 1.6, 5). The aircraft is one meter forward
        // of them in scene coords. Bearing should still be 0°, not whatever
        // the absolute coordinates would give.
        let user = SIMD3<Float>(5, 1.6, 5)
        let target = SIMD3<Float>(5, 1.6, 4)
        let bearing = GeoMath.sceneBearingDegrees(from: user, to: target)
        XCTAssertEqual(bearing, 0, accuracy: 0.000_001)
    }

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

    func testAngularAircraftSelectionUsesUserPositionForTapDirection() {
        let userPosition = SIMD3<Double>(2, 0, 1)
        let forward = SIMD3<Double>(0, 0, -1)
        let nearbyOffset = direction(yawDegrees: 1.5)
        let candidates = [
            AngularSelectionCandidate(
                id: "nearby",
                positionMeters: userPosition + nearbyOffset * 1_000,
                selectionRadiusMeters: 100
            ),
            AngularSelectionCandidate(
                id: "exact",
                positionMeters: userPosition + forward * 50_000,
                selectionRadiusMeters: 2_500
            )
        ]

        let selected = AngularAircraftSelector.selectedID(
            tapPositionMeters: userPosition + forward * 8,
            userPositionMeters: userPosition,
            candidates: candidates
        )

        XCTAssertEqual(selected, "exact")
    }

    func testAngularAircraftSelectionBreaksOverlapsBySmallestAngularDistance() {
        let userPosition = SIMD3<Double>(-3, 0.5, 4)
        let candidates = [
            AngularSelectionCandidate(
                id: "wider-miss",
                positionMeters: userPosition + direction(yawDegrees: 2.0) * 50_000,
                selectionRadiusMeters: 3_000
            ),
            AngularSelectionCandidate(
                id: "closest",
                positionMeters: userPosition + direction(yawDegrees: -0.4) * 50_000,
                selectionRadiusMeters: 3_000
            )
        ]

        let selected = AngularAircraftSelector.selectedID(
            tapPositionMeters: userPosition + SIMD3<Double>(0, 0, -8),
            userPositionMeters: userPosition,
            candidates: candidates
        )

        XCTAssertEqual(selected, "closest")
    }

    func testAngularAircraftSelectionRejectsOutsideCone() {
        let selected = AngularAircraftSelector.selectedID(
            tapPositionMeters: SIMD3<Double>(0, 0, -8),
            candidates: [
                AngularSelectionCandidate(
                    id: "outside",
                    positionMeters: direction(yawDegrees: 10) * 50_000,
                    selectionRadiusMeters: 2_500
                )
            ]
        )

        XCTAssertNil(selected)
    }

    func testAngularSelectionRadiusUsesSphereHalfAngle() {
        XCTAssertEqual(
            AngularAircraftSelector.angularRadiusRadians(selectionRadiusMeters: 60, distanceMeters: 60),
            .pi / 2,
            accuracy: 0.000_001
        )
    }

    private func direction(yawDegrees: Double) -> SIMD3<Double> {
        let radians = GeoMath.degreesToRadians(yawDegrees)
        return SIMD3<Double>(sin(radians), 0, -cos(radians))
    }
}
