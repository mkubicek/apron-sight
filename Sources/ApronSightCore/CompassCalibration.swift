import Foundation

public enum CompassCalibration {
    /// Yaw offset that aligns an aircraft's known world bearing with the
    /// direction the user is currently looking (their gaze bearing in the
    /// scene, also measured clockwise from north). Result is in `[0, 360)`.
    public static func yaw(
        forAircraftBearingDegrees bearing: Double,
        gazeBearingDegrees gaze: Double
    ) -> Double {
        GeoMath.normalizedDegrees(bearing - gaze)
    }

    /// Vertical-scene offset that aligns the selected aircraft's rendered
    /// scene-Y with the user's gaze elevation. Applied uniformly to BOTH
    /// the rendered ground and every aircraft's Y coordinate, so the
    /// aircraft-to-ground geometry is preserved.
    ///
    /// `aircraftYWithoutCalibration` is the aircraft's scene-Y as currently
    /// computed from `(aircraftAltitude - observerAltitude)` (i.e.,
    /// `placement.enu.up`), before this offset is applied.
    /// `horizontalDistanceMeters` is the aircraft's ground distance from
    /// the observer (yaw-invariant). `userY`, `gazeY`, `gazeHorizontal`
    /// describe the user's head position and the gaze ray direction in
    /// scene coordinates.
    ///
    /// Caller must guard `gazeHorizontal > 0` — for near-vertical gaze the
    /// formula is singular.
    public static func altitudeOffset(
        aircraftYWithoutCalibration: Double,
        horizontalDistanceMeters: Double,
        userY: Double,
        gazeY: Double,
        gazeHorizontal: Double
    ) -> Double {
        let targetSceneY = userY + horizontalDistanceMeters * (gazeY / gazeHorizontal)
        return targetSceneY - aircraftYWithoutCalibration
    }
}
