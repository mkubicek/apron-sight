import Foundation

public enum LocationPreset: Equatable, Hashable, Sendable {
    case gps
    case home
    case zrhObservationDeck
    case zrhCenter
    case custom(GeoCoordinate)

    public var coordinate: GeoCoordinate {
        switch self {
        case .gps:
            // Fallback used until the GPS provider delivers its first fix.
            // Once a fix arrives, AppModel writes the live coordinates
            // directly into observerLatitude/Longitude/Altitude.
            return DemoScenario.defaultObserver
        case .home:
            return DemoScenario.defaultObserver
        case .zrhObservationDeck:
            return GeoCoordinate(
                latitudeDegrees: 47.451210,
                longitudeDegrees: 8.557410,
                altitudeMeters: 432
            )
        case .zrhCenter:
            return GeoCoordinate(
                latitudeDegrees: 47.464700,
                longitudeDegrees: 8.549200,
                altitudeMeters: 432
            )
        case .custom(let coordinate):
            return coordinate
        }
    }

    /// Stable `UserDefaults` key for persisting calibrated yaw at this
    /// location. Returns `nil` for `.custom` because custom lat/lon isn't
    /// itself stable enough to use as a key — users on a custom coordinate
    /// have to recalibrate when they return.
    public var calibrationStorageKey: String? {
        switch self {
        case .gps:
            return "calibration.yaw.gps"
        case .home:
            return "calibration.yaw.home"
        case .zrhObservationDeck:
            return "calibration.yaw.zrhObservationDeck"
        case .zrhCenter:
            return "calibration.yaw.zrhCenter"
        case .custom:
            return nil
        }
    }

    /// Stable `UserDefaults` key for persisting the calibrated vertical
    /// scene offset (altitude calibration). Same scope rules as the yaw
    /// key — `.custom` does not persist.
    public var verticalCalibrationStorageKey: String? {
        switch self {
        case .gps:
            return "calibration.vertical.gps"
        case .home:
            return "calibration.vertical.home"
        case .zrhObservationDeck:
            return "calibration.vertical.zrhObservationDeck"
        case .zrhCenter:
            return "calibration.vertical.zrhCenter"
        case .custom:
            return nil
        }
    }
}
