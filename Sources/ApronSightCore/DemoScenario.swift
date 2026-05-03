import Foundation

public enum DemoScenario {
    public static let homeDemoTargetName = "Home demo target"

    public static let homeDemoTarget = GeoCoordinate(
        latitudeDegrees: 47.333859,
        longitudeDegrees: 8.520262,
        altitudeMeters: 432
    )

    public static let homeDemoAircraft = Aircraft(
        id: "mock-home-demo",
        callsign: "DEMO01",
        coordinate: homeDemoTarget,
        velocityMetersPerSecond: 0,
        trueTrackDegrees: 90,
        isOnGround: false
    )

    public static let defaultObserver = GeoCoordinate(
        latitudeDegrees: 47.333580,
        longitudeDegrees: 8.519790,
        altitudeMeters: 420
    )

    public static var defaultHomePlacement: GeoPlacement {
        GeoMath.placement(observer: defaultObserver, target: homeDemoTarget)
    }
}
