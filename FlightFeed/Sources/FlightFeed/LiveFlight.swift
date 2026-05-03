import Foundation

/// A single aircraft observation, normalised across upstream providers.
///
/// All units are SI: metres, metres/second, degrees true. `nil` means the
/// upstream did not supply that field for this observation — most commonly
/// for aircraft that have just appeared in coverage.
public struct LiveFlight: Equatable, Identifiable, Sendable, Hashable {
    /// ICAO 24-bit transponder address, lowercase hex. Stable per airframe.
    public var id: String
    /// Airline + flight number as broadcast (e.g. "SWR214"). Trimmed; may be empty
    /// for aircraft transmitting no callsign.
    public var callsign: String
    /// ISO 3166-1 alpha-2-ish origin country reported by the receiver network.
    public var originCountry: String?
    public var latitudeDegrees: Double
    public var longitudeDegrees: Double
    /// Barometric altitude when available, geometric altitude as fallback.
    public var altitudeMeters: Double?
    public var velocityMetersPerSecond: Double?
    /// True track over ground, 0° = north, clockwise.
    public var trueTrackDegrees: Double?
    public var verticalRateMetersPerSecond: Double?
    public var isOnGround: Bool
    /// Wall-clock time of the position fix (UTC).
    public var positionTimestamp: Date
    /// Time the upstream last received any signal from this aircraft (UTC).
    public var lastContact: Date

    public init(
        id: String,
        callsign: String,
        originCountry: String? = nil,
        latitudeDegrees: Double,
        longitudeDegrees: Double,
        altitudeMeters: Double? = nil,
        velocityMetersPerSecond: Double? = nil,
        trueTrackDegrees: Double? = nil,
        verticalRateMetersPerSecond: Double? = nil,
        isOnGround: Bool = false,
        positionTimestamp: Date,
        lastContact: Date
    ) {
        self.id = id
        self.callsign = callsign
        self.originCountry = originCountry
        self.latitudeDegrees = latitudeDegrees
        self.longitudeDegrees = longitudeDegrees
        self.altitudeMeters = altitudeMeters
        self.velocityMetersPerSecond = velocityMetersPerSecond
        self.trueTrackDegrees = trueTrackDegrees
        self.verticalRateMetersPerSecond = verticalRateMetersPerSecond
        self.isOnGround = isOnGround
        self.positionTimestamp = positionTimestamp
        self.lastContact = lastContact
    }
}

/// A snapshot of every flight visible inside a query region at a given moment.
public struct FlightSnapshot: Equatable, Sendable {
    public var flights: [LiveFlight]
    /// Server-reported time the snapshot was assembled.
    public var capturedAt: Date
    public var region: RadiusRegion

    public init(flights: [LiveFlight], capturedAt: Date, region: RadiusRegion) {
        self.flights = flights
        self.capturedAt = capturedAt
        self.region = region
    }
}
