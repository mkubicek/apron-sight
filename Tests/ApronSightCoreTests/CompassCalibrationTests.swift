import XCTest
@testable import ApronSightCore

final class CompassCalibrationTests: XCTestCase {
    func testYawIsBearingMinusGazeWhenBothInUpperHalf() {
        let yaw = CompassCalibration.yaw(forAircraftBearingDegrees: 200, gazeBearingDegrees: 50)
        XCTAssertEqual(yaw, 150, accuracy: 0.000_001)
    }

    func testYawWrapsWhenBearingIsSmallAndGazeIsLarge() {
        // Aircraft north-by-east of true north (10°), but the user is
        // currently looking near-west (350° in scene coords). Yaw must
        // rotate the world by +20° (i.e. 360° - 340° = 20°).
        let yaw = CompassCalibration.yaw(forAircraftBearingDegrees: 10, gazeBearingDegrees: 350)
        XCTAssertEqual(yaw, 20, accuracy: 0.000_001)
    }

    func testYawWrapsWhenBearingIsLargeAndGazeIsSmall() {
        // Mirror of the previous case.
        let yaw = CompassCalibration.yaw(forAircraftBearingDegrees: 350, gazeBearingDegrees: 10)
        XCTAssertEqual(yaw, 340, accuracy: 0.000_001)
    }

    func testYawIsZeroWhenAircraftIsAlreadyInGazeDirection() {
        let yaw = CompassCalibration.yaw(forAircraftBearingDegrees: 123, gazeBearingDegrees: 123)
        XCTAssertEqual(yaw, 0, accuracy: 0.000_001)
    }

    func testYawIsAlwaysInHalfOpenZeroToThreeSixty() {
        for bearing in stride(from: 0.0, to: 360.0, by: 7.5) {
            for gaze in stride(from: 0.0, to: 360.0, by: 11.25) {
                let yaw = CompassCalibration.yaw(forAircraftBearingDegrees: bearing, gazeBearingDegrees: gaze)
                XCTAssertGreaterThanOrEqual(yaw, 0, "bearing=\(bearing) gaze=\(gaze) yaw=\(yaw)")
                XCTAssertLessThan(yaw, 360, "bearing=\(bearing) gaze=\(gaze) yaw=\(yaw)")
            }
        }
    }

    // MARK: - altitudeOffset

    func testAltitudeOffsetIsZeroWhenAircraftMatchesGazeElevation() {
        // Aircraft 500m above observer, 5km away. User looks at gaze
        // direction with tan(elevation) = 500 / 5000 = 0.1. The aircraft
        // already sits at the gaze direction — no offset needed.
        let offset = CompassCalibration.altitudeOffset(
            aircraftYWithoutCalibration: 500,
            horizontalDistanceMeters: 5000,
            userY: 0,
            gazeY: 0.1,
            gazeHorizontal: 1.0
        )
        XCTAssertEqual(offset, 0, accuracy: 0.000_001)
    }

    func testAltitudeOffsetShiftsSceneToMatchGazeElevation() {
        // Same aircraft, but user looks higher: tan(elevation) = 0.14
        // (about 8°). Aircraft should appear at 5000 × 0.14 = 700m;
        // currently it's at 500m, so offset = +200m.
        let offset = CompassCalibration.altitudeOffset(
            aircraftYWithoutCalibration: 500,
            horizontalDistanceMeters: 5000,
            userY: 0,
            gazeY: 0.14,
            gazeHorizontal: 1.0
        )
        XCTAssertEqual(offset, 200, accuracy: 0.000_001)
    }

    func testAltitudeOffsetAccountsForUserY() {
        // User's eye is at scene Y = 1.6 (typical eye height above scene
        // origin). Aircraft 200m up, 1km horizontal, gaze level (gazeY=0).
        // Target scene-Y = 1.6 + 1000 × 0 = 1.6. Offset = 1.6 - 200 = -198.4.
        let offset = CompassCalibration.altitudeOffset(
            aircraftYWithoutCalibration: 200,
            horizontalDistanceMeters: 1000,
            userY: 1.6,
            gazeY: 0,
            gazeHorizontal: 1.0
        )
        XCTAssertEqual(offset, -198.4, accuracy: 0.000_001)
    }

    func testAltitudeOffsetHandlesAircraftBelowObserver() {
        // Aircraft -100m (below observer), 2km away. User at origin, gaze
        // looking down: gazeY = -0.05, gazeHorizontal = 1.0.
        // Target scene-Y = 0 + 2000 × (-0.05) = -100. Offset = -100 - (-100) = 0.
        let offset = CompassCalibration.altitudeOffset(
            aircraftYWithoutCalibration: -100,
            horizontalDistanceMeters: 2000,
            userY: 0,
            gazeY: -0.05,
            gazeHorizontal: 1.0
        )
        XCTAssertEqual(offset, 0, accuracy: 0.000_001)
    }
}
