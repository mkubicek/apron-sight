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

    public struct Track: Equatable, Sendable {
        public let id: String
        public let entries: [Entry]

        public init(id: String, entries: [Entry]) {
            self.id = id
            self.entries = entries
        }
    }

    private var historiesByID: [String: [Entry]] = [:]
    public private(set) var latestCapturedAt: Date?

    public init(retentionSeconds: TimeInterval) {
        precondition(retentionSeconds > 0, "retentionSeconds must be positive")
        self.retentionSeconds = retentionSeconds
    }

    public var count: Int { historiesByID.count }

    public var entries: [Entry] {
        historiesByID.values.compactMap { Self.normalizedHistory($0).last }
    }

    public mutating func clear() {
        historiesByID.removeAll(keepingCapacity: true)
        latestCapturedAt = nil
    }

    /// Merges a snapshot into the buffer and evicts entries older than
    /// `retentionSeconds` measured against the latest snapshot watermark.
    /// OpenSky can deliver response timestamps out of order, so recency is
    /// enforced per aircraft: a late response may fill a gap for an aircraft
    /// that has no newer row yet, but it cannot rewind an existing entry.
    public mutating func ingest(_ snapshot: FlightSnapshot) {
        for flight in snapshot.flights {
            let capturedAt = Self.effectiveCapturedAt(for: flight, snapshotCapturedAt: snapshot.capturedAt)
            var history = historiesByID[flight.id] ?? []
            if let duplicateIndex = history.firstIndex(where: { $0.capturedAt == capturedAt }) {
                history[duplicateIndex] = Entry(
                    flight: Self.merge(existing: history[duplicateIndex].flight, with: flight),
                    capturedAt: capturedAt
                )
            } else {
                history.append(Entry(flight: flight, capturedAt: capturedAt))
                history.sort { $0.capturedAt < $1.capturedAt }
            }
            historiesByID[flight.id] = history
        }
        latestCapturedAt = max(latestCapturedAt ?? snapshot.capturedAt, snapshot.capturedAt)

        pruneHistories(referenceDate: latestCapturedAt ?? snapshot.capturedAt)
    }

    /// Returns the entries whose last-seen timestamp is within the
    /// retention window of `date`. Stale entries are filtered defensively
    /// even though `ingest` already evicts at ingest time, so a stretch
    /// without snapshots can't keep ancient entries visible.
    public func entries(at date: Date) -> [Entry] {
        tracks(at: date).compactMap { $0.entries.last }
    }

    /// Returns per-aircraft sample histories sorted by observation time.
    /// Entries are field-normalized in chronological order so late-arriving
    /// samples can still improve interpolation without making latest-state
    /// consumers move backwards.
    public func tracks(at date: Date) -> [Track] {
        let cutoff = date.addingTimeInterval(-retentionSeconds)
        return historiesByID.compactMap { id, history in
            let normalized = Self.normalizedHistory(history)
                .filter { $0.capturedAt > cutoff }
            guard !normalized.isEmpty else {
                return nil
            }
            return Track(id: id, entries: normalized)
        }
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

    private mutating func pruneHistories(referenceDate: Date) {
        let cutoff = referenceDate.addingTimeInterval(-retentionSeconds)
        historiesByID = historiesByID.compactMapValues { history in
            let retained = history.filter { $0.capturedAt > cutoff }
            return retained.isEmpty ? nil : retained
        }
    }

    private static func normalizedHistory(_ history: [Entry]) -> [Entry] {
        history.reduce(into: []) { normalized, entry in
            let merged = merge(existing: normalized.last?.flight, with: entry.flight)
            normalized.append(Entry(flight: merged, capturedAt: entry.capturedAt))
        }
    }
}
