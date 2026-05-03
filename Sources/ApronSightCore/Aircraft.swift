import Foundation

public struct Aircraft: Equatable, Identifiable, Sendable {
    public var id: String
    public var callsign: String
    public var coordinate: GeoCoordinate
    public var velocityMetersPerSecond: Double?
    public var trueTrackDegrees: Double?
    public var verticalRateMetersPerSecond: Double?
    public var isOnGround: Bool

    public init(
        id: String,
        callsign: String,
        coordinate: GeoCoordinate,
        velocityMetersPerSecond: Double? = nil,
        trueTrackDegrees: Double? = nil,
        verticalRateMetersPerSecond: Double? = nil,
        isOnGround: Bool = false
    ) {
        self.id = id
        self.callsign = callsign
        self.coordinate = coordinate
        self.velocityMetersPerSecond = velocityMetersPerSecond
        self.trueTrackDegrees = trueTrackDegrees
        self.verticalRateMetersPerSecond = verticalRateMetersPerSecond
        self.isOnGround = isOnGround
    }
}

public protocol AircraftProvider {
    func aircraft() -> [Aircraft]
}

public struct MockAircraftProvider: AircraftProvider {
    public init() {}

    public func aircraft() -> [Aircraft] {
        let observer = DemoScenario.defaultObserver
        let flights: [(id: String, callsign: String, east: Double, north: Double, altitude: Double, speed: Double, track: Double)] = [
            ("DEMO01", "DEMO01", 35, 31, 432, 42, 65),
            ("DEMO02", "SWR214", -420, -950, 900, 48, 28),
            ("DEMO03", "EZY83K", 760, -680, 1030, 55, 306),
            ("DEMO04", "DLH71P", -980, 210, 1280, 68, 102),
            ("DEMO05", "QTR51", 1180, 540, 1350, 72, 250),
            ("DEMO06", "AUA905", -240, 820, 810, 39, 176),
            ("DEMO07", "AFR46T", 530, 1180, 1180, 60, 334),
            ("DEMO08", "BAW773", -1280, -410, 1470, 78, 74),
            ("DEMO09", "KLM18Z", 180, -1450, 960, 50, 14),
            ("DEMO10", "EDW350", 1440, -120, 840, 44, 286)
        ]

        return flights.map { flight in
            Aircraft(
                id: flight.id,
                callsign: flight.callsign,
                coordinate: GeoMath.coordinate(
                    offsetFrom: observer,
                    eastMeters: flight.east,
                    northMeters: flight.north,
                    upMeters: flight.altitude - observer.altitudeMeters
                ),
                velocityMetersPerSecond: flight.speed,
                trueTrackDegrees: flight.track,
                isOnGround: false
            )
        }
    }
}
