import Foundation

public struct GeoCoordinate: Equatable, Hashable, Sendable {
    public var latitudeDegrees: Double
    public var longitudeDegrees: Double
    public var altitudeMeters: Double

    public init(latitudeDegrees: Double, longitudeDegrees: Double, altitudeMeters: Double = 0) {
        self.latitudeDegrees = latitudeDegrees
        self.longitudeDegrees = longitudeDegrees
        self.altitudeMeters = altitudeMeters
    }
}

public struct ECEFCoordinate: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
}

public struct ENUCoordinate: Equatable, Sendable {
    public var east: Double
    public var north: Double
    public var up: Double

    public var horizontalDistanceMeters: Double {
        hypot(east, north)
    }

    public var slantDistanceMeters: Double {
        sqrt(east * east + north * north + up * up)
    }
}

public struct LocalCoordinate: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
}

public struct GeoPlacement: Equatable, Sendable {
    public var enu: ENUCoordinate
    public var horizontalDistanceMeters: Double
    public var slantDistanceMeters: Double
    public var bearingDegrees: Double
    public var elevationDegrees: Double
}
