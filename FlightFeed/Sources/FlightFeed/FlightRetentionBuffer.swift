import Foundation

/// Per-aircraft buffer that keeps the most recent state for each flight
/// so a brief OpenSky coverage gap doesn't make an aircraft disappear
/// from the rendered scene.
///
/// Two design rules:
///
/// 1. **Retain through silence.** If a flight is in poll N but missing
///    from poll N+1, its retained entry stays until it falls outside the
///    `retentionSeconds` window. Eviction happens at ingest time so the
///    buffer can't grow unbounded.
///
/// 2. **Preserve last-known airborne fields on merge.** OpenSky transponder data
///    occasionally drops altitude or velocity for a single poll. If the
///    new snapshot reports nil for an optional field, the old value is
///    kept so the consumer (`LiveAircraftProvider.aircraft(from:)`)
///    doesn't filter the aircraft out for a missing field.
///    Ground reports are different: once `onGround` is true, stale
///    airborne velocity, track, and vertical rate must not leak into the
///    taxi/parked state. Missing ground altitude may only fall back to a
///    previous ground altitude, never a previous airborne altitude.
///    Hard fields (lat/lon/onGround/timestamps) always come from the new
///    snapshot — those are observed each poll.
public struct FlightRetentionBuffer: Sendable {
    public let retentionSeconds: TimeInterval

    public struct Entry: Equatable, Sendable {
        public let flight: LiveFlight
        public let capturedAt: Date

        public init(flight: LiveFlight, capturedAt: Date) {
            self.flight = flight
            self.capturedAt = capturedAt
        }
    }

    private var entriesByID: [String: Entry] = [:]
    public private(set) var latestCapturedAt: Date?

    public init(retentionSeconds: TimeInterval) {
        precondition(retentionSeconds > 0, "retentionSeconds must be positive")
        self.retentionSeconds = retentionSeconds
    }

    public var count: Int { entriesByID.count }

    public var entries: [Entry] { Array(entriesByID.values) }

    public mutating func clear() {
        entriesByID.removeAll(keepingCapacity: true)
        latestCapturedAt = nil
    }

    /// Merges a snapshot into the buffer and evicts entries older than
    /// `retentionSeconds` measured against the snapshot's `capturedAt`.
    public mutating func ingest(_ snapshot: FlightSnapshot) {
        for flight in snapshot.flights {
            let merged = Self.merge(existing: entriesByID[flight.id]?.flight, with: flight)
            entriesByID[flight.id] = Entry(
                flight: merged,
                capturedAt: Self.effectiveCapturedAt(for: merged, snapshotCapturedAt: snapshot.capturedAt)
            )
        }
        latestCapturedAt = snapshot.capturedAt

        let cutoff = snapshot.capturedAt.addingTimeInterval(-retentionSeconds)
        entriesByID = entriesByID.filter { _, entry in entry.capturedAt > cutoff }
    }

    /// Returns the entries whose last-seen timestamp is within the
    /// retention window of `date`. Stale entries are filtered defensively
    /// even though `ingest` already evicts at ingest time, so a stretch
    /// without snapshots can't keep ancient entries visible.
    public func entries(at date: Date) -> [Entry] {
        let cutoff = date.addingTimeInterval(-retentionSeconds)
        return entriesByID.values.filter { $0.capturedAt > cutoff }
    }

    /// Field-level merge: hard fields come from `new`, soft fields fall
    /// back to `existing` when `new` reports nil/empty.
    static func merge(existing: LiveFlight?, with new: LiveFlight) -> LiveFlight {
        let velocity = new.isOnGround
            ? (new.velocityMetersPerSecond ?? 0)
            : (new.velocityMetersPerSecond ?? existing?.velocityMetersPerSecond)
        let trueTrack = new.isOnGround
            ? new.trueTrackDegrees
            : (new.trueTrackDegrees ?? existing?.trueTrackDegrees)
        let verticalRate = new.isOnGround
            ? 0
            : (new.verticalRateMetersPerSecond ?? existing?.verticalRateMetersPerSecond)
        let altitude = new.isOnGround
            ? (new.altitudeMeters ?? (existing?.isOnGround == true ? existing?.altitudeMeters : nil))
            : (new.altitudeMeters ?? existing?.altitudeMeters)

        return LiveFlight(
            id: new.id,
            callsign: new.callsign.isEmpty ? (existing?.callsign ?? new.callsign) : new.callsign,
            originCountry: new.originCountry ?? existing?.originCountry,
            latitudeDegrees: new.latitudeDegrees,
            longitudeDegrees: new.longitudeDegrees,
            altitudeMeters: altitude,
            velocityMetersPerSecond: velocity,
            trueTrackDegrees: trueTrack,
            verticalRateMetersPerSecond: verticalRate,
            isOnGround: new.isOnGround,
            category: new.category ?? existing?.category,
            positionTimestamp: new.positionTimestamp,
            lastContact: new.lastContact
        )
    }

    private static func effectiveCapturedAt(for flight: LiveFlight, snapshotCapturedAt: Date) -> Date {
        let sourceTimestamp = max(flight.positionTimestamp, flight.lastContact)
        return min(sourceTimestamp, snapshotCapturedAt)
    }
}
