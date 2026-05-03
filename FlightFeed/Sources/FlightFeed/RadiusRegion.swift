import Foundation

/// A circular query region centred on `latitude`/`longitude` with `radiusKm`.
///
/// The OpenSky `states/all` endpoint only accepts an axis-aligned lat/lon
/// bounding box, so we expand the circle to the smallest enclosing box and
/// post-filter results by true great-circle distance.
public struct RadiusRegion: Equatable, Sendable, Hashable {
    public var latitudeDegrees: Double
    public var longitudeDegrees: Double
    public var radiusKm: Double

    public init(latitudeDegrees: Double, longitudeDegrees: Double, radiusKm: Double) {
        precondition(radiusKm > 0, "radius must be positive")
        precondition((-90...90).contains(latitudeDegrees), "latitude out of range")
        precondition((-180...180).contains(longitudeDegrees), "longitude out of range")
        self.latitudeDegrees = latitudeDegrees
        self.longitudeDegrees = longitudeDegrees
        self.radiusKm = radiusKm
    }

    /// Smallest axis-aligned lat/lon box that fully contains the radius circle.
    /// Near the poles longitude collapses to the full 360° range to stay safe.
    public var boundingBox: BoundingBox {
        // 1° latitude ≈ 111.32 km everywhere. Longitude shrinks with latitude.
        let dLat = radiusKm / 111.32
        let latMin = max(latitudeDegrees - dLat, -90)
        let latMax = min(latitudeDegrees + dLat, 90)

        let cosLat = cos(latitudeDegrees * .pi / 180)
        let dLon: Double
        if cosLat < 0.01 {
            dLon = 180  // pole — full sweep
        } else {
            dLon = radiusKm / (111.32 * cosLat)
        }
        let lonMin = max(longitudeDegrees - dLon, -180)
        let lonMax = min(longitudeDegrees + dLon, 180)

        return BoundingBox(
            latMin: latMin,
            lonMin: lonMin,
            latMax: latMax,
            lonMax: lonMax
        )
    }

    /// Great-circle distance from this region's centre to a point, in metres.
    public func distanceMeters(toLatitude lat: Double, longitude lon: Double) -> Double {
        Self.haversineMeters(
            lat1: latitudeDegrees,
            lon1: longitudeDegrees,
            lat2: lat,
            lon2: lon
        )
    }

    /// True if `lat`/`lon` lies inside the radius circle (great-circle distance).
    public func contains(latitude lat: Double, longitude lon: Double) -> Bool {
        distanceMeters(toLatitude: lat, longitude: lon) <= radiusKm * 1000
    }

    static func haversineMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let r = 6_371_000.0
        let φ1 = lat1 * .pi / 180
        let φ2 = lat2 * .pi / 180
        let dφ = (lat2 - lat1) * .pi / 180
        let dλ = (lon2 - lon1) * .pi / 180
        let a = sin(dφ / 2) * sin(dφ / 2)
            + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return r * c
    }
}

public struct BoundingBox: Equatable, Sendable, Hashable {
    public var latMin: Double
    public var lonMin: Double
    public var latMax: Double
    public var lonMax: Double

    public init(latMin: Double, lonMin: Double, latMax: Double, lonMax: Double) {
        self.latMin = latMin
        self.lonMin = lonMin
        self.latMax = latMax
        self.lonMax = lonMax
    }
}
