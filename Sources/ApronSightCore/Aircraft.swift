import Foundation

public struct Aircraft: Equatable, Identifiable, Sendable {
    public var id: String
    public var callsign: String
    public var originCountry: String?
    public var coordinate: GeoCoordinate
    public var velocityMetersPerSecond: Double?
    public var trueTrackDegrees: Double?
    public var verticalRateMetersPerSecond: Double?
    public var isOnGround: Bool

    public init(
        id: String,
        callsign: String,
        originCountry: String? = nil,
        coordinate: GeoCoordinate,
        velocityMetersPerSecond: Double? = nil,
        trueTrackDegrees: Double? = nil,
        verticalRateMetersPerSecond: Double? = nil,
        isOnGround: Bool = false
    ) {
        self.id = id
        self.callsign = callsign
        self.originCountry = originCountry
        self.coordinate = coordinate
        self.velocityMetersPerSecond = velocityMetersPerSecond
        self.trueTrackDegrees = trueTrackDegrees
        self.verticalRateMetersPerSecond = verticalRateMetersPerSecond
        self.isOnGround = isOnGround
    }
}

public protocol AircraftProvider {
    func aircraft(at date: Date) -> [Aircraft]
}
