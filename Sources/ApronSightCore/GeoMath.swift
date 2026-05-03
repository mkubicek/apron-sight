import Foundation

public enum GeoMath {
    private static let earthSemiMajorAxisMeters = 6_378_137.0
    private static let earthFlattening = 1.0 / 298.257_223_563
    private static let earthFirstEccentricitySquared = earthFlattening * (2.0 - earthFlattening)

    public static func degreesToRadians(_ degrees: Double) -> Double {
        degrees * .pi / 180.0
    }

    public static func radiansToDegrees(_ radians: Double) -> Double {
        radians * 180.0 / .pi
    }

    public static func normalizedDegrees(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360.0)
        if value < 0 {
            value += 360.0
        }
        return value
    }

    public static func ecefCoordinate(from coordinate: GeoCoordinate) -> ECEFCoordinate {
        let latitude = degreesToRadians(coordinate.latitudeDegrees)
        let longitude = degreesToRadians(coordinate.longitudeDegrees)
        let altitude = coordinate.altitudeMeters

        let sinLatitude = sin(latitude)
        let cosLatitude = cos(latitude)
        let sinLongitude = sin(longitude)
        let cosLongitude = cos(longitude)

        let primeVerticalRadius = earthSemiMajorAxisMeters / sqrt(1.0 - earthFirstEccentricitySquared * sinLatitude * sinLatitude)

        return ECEFCoordinate(
            x: (primeVerticalRadius + altitude) * cosLatitude * cosLongitude,
            y: (primeVerticalRadius + altitude) * cosLatitude * sinLongitude,
            z: (primeVerticalRadius * (1.0 - earthFirstEccentricitySquared) + altitude) * sinLatitude
        )
    }

    public static func enuCoordinate(observer: GeoCoordinate, target: GeoCoordinate) -> ENUCoordinate {
        let observerECEF = ecefCoordinate(from: observer)
        let targetECEF = ecefCoordinate(from: target)

        let deltaX = targetECEF.x - observerECEF.x
        let deltaY = targetECEF.y - observerECEF.y
        let deltaZ = targetECEF.z - observerECEF.z

        let latitude = degreesToRadians(observer.latitudeDegrees)
        let longitude = degreesToRadians(observer.longitudeDegrees)

        let sinLatitude = sin(latitude)
        let cosLatitude = cos(latitude)
        let sinLongitude = sin(longitude)
        let cosLongitude = cos(longitude)

        return ENUCoordinate(
            east: -sinLongitude * deltaX + cosLongitude * deltaY,
            north: -sinLatitude * cosLongitude * deltaX - sinLatitude * sinLongitude * deltaY + cosLatitude * deltaZ,
            up: cosLatitude * cosLongitude * deltaX + cosLatitude * sinLongitude * deltaY + sinLatitude * deltaZ
        )
    }

    public static func placement(observer: GeoCoordinate, target: GeoCoordinate) -> GeoPlacement {
        let enu = enuCoordinate(observer: observer, target: target)
        let horizontalDistance = enu.horizontalDistanceMeters
        let slantDistance = enu.slantDistanceMeters

        let bearing: Double
        if horizontalDistance.isAlmostZero {
            bearing = 0
        } else {
            bearing = normalizedDegrees(radiansToDegrees(atan2(enu.east, enu.north)))
        }

        let elevation: Double
        if horizontalDistance.isAlmostZero && enu.up.isAlmostZero {
            elevation = 0
        } else {
            elevation = radiansToDegrees(atan2(enu.up, horizontalDistance))
        }

        return GeoPlacement(
            enu: enu,
            horizontalDistanceMeters: horizontalDistance,
            slantDistanceMeters: slantDistance,
            bearingDegrees: bearing,
            elevationDegrees: elevation
        )
    }

    public static func coordinate(
        offsetFrom coordinate: GeoCoordinate,
        eastMeters: Double,
        northMeters: Double,
        upMeters: Double
    ) -> GeoCoordinate {
        let latitude = degreesToRadians(coordinate.latitudeDegrees)
        let sinLatitude = sin(latitude)
        let cosLatitude = cos(latitude)
        let primeVerticalRadius = earthSemiMajorAxisMeters / sqrt(1.0 - earthFirstEccentricitySquared * sinLatitude * sinLatitude)
        let meridianRadius = earthSemiMajorAxisMeters * (1.0 - earthFirstEccentricitySquared) / pow(1.0 - earthFirstEccentricitySquared * sinLatitude * sinLatitude, 1.5)

        let latitudeDelta = northMeters / (meridianRadius + coordinate.altitudeMeters)
        let longitudeDelta: Double
        if abs(cosLatitude) < 1e-9 {
            longitudeDelta = 0
        } else {
            longitudeDelta = eastMeters / ((primeVerticalRadius + coordinate.altitudeMeters) * cosLatitude)
        }

        return GeoCoordinate(
            latitudeDegrees: coordinate.latitudeDegrees + radiansToDegrees(latitudeDelta),
            longitudeDegrees: coordinate.longitudeDegrees + radiansToDegrees(longitudeDelta),
            altitudeMeters: coordinate.altitudeMeters + upMeters
        )
    }

    /// Converts ENU meters into the app's local RealityKit-style frame.
    /// x is right, y is up, and negative z is forward. The yaw offset is the
    /// real-world bearing currently aligned with the user's forward direction.
    public static func localCoordinate(for enu: ENUCoordinate, yawOffsetDegrees: Double) -> LocalCoordinate {
        let yaw = degreesToRadians(yawOffsetDegrees)
        let cosYaw = cos(yaw)
        let sinYaw = sin(yaw)

        return LocalCoordinate(
            x: enu.east * cosYaw - enu.north * sinYaw,
            y: enu.up,
            z: -(enu.east * sinYaw + enu.north * cosYaw)
        )
    }

    public static func localCoordinate(for placement: GeoPlacement, yawOffsetDegrees: Double) -> LocalCoordinate {
        localCoordinate(for: placement.enu, yawOffsetDegrees: yawOffsetDegrees)
    }

    public static func enuHorizontalOffset(localX: Double, localZ: Double, yawOffsetDegrees: Double) -> (east: Double, north: Double) {
        let yaw = degreesToRadians(yawOffsetDegrees)
        let cosYaw = cos(yaw)
        let sinYaw = sin(yaw)
        let forward = -localZ

        return (
            east: localX * cosYaw + forward * sinYaw,
            north: -localX * sinYaw + forward * cosYaw
        )
    }
}

private extension Double {
    var isAlmostZero: Bool {
        abs(self) < 1e-9
    }
}
