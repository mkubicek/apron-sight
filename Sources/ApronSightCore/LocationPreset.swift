import Foundation

public enum LocationPreset: Equatable, Hashable, Sendable {
    case home
    case zrhObservationDeck
    case zrhCenter
    case custom(GeoCoordinate)

    public var coordinate: GeoCoordinate {
        switch self {
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
}
