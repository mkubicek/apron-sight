import Foundation
import FlightFeed

enum FlightDataSource: String, CaseIterable, Identifiable {
    case mock
    case live

    var id: Self { self }

    var title: String {
        switch self {
        case .mock:
            return "Mock"
        case .live:
            return "Live"
        }
    }
}

final class LiveAircraftProvider: AircraftProvider, @unchecked Sendable {
    private let liveFlightProvider: any FlightProvider
    private let livePollInterval: TimeInterval
    private let mockFlightProvider = MockFlightProvider(count: 12)
    private let state = LiveAircraftProviderState()
    private var feedTask: Task<Void, Never>?
    private var currentRegion: RadiusRegion?
    private var currentSource: FlightDataSource?

    var errorHandler: (@MainActor (String?) -> Void)?

    init(liveFlightProvider: (any FlightProvider)? = nil, livePollInterval: TimeInterval? = nil) {
        if let liveFlightProvider {
            self.liveFlightProvider = liveFlightProvider
            self.livePollInterval = livePollInterval ?? 10
        } else {
            self.liveFlightProvider = OpenSkyConfiguration.makeLiveFlightProvider()
            self.livePollInterval = livePollInterval ?? OpenSkyConfiguration.livePollIntervalSeconds
        }
    }

    @MainActor
    func start(observer: GeoCoordinate, groundAltitudeMeters: Double, source: FlightDataSource) {
        update(observer: observer, groundAltitudeMeters: groundAltitudeMeters, source: source, force: true)
    }

    @MainActor
    func update(
        observer: GeoCoordinate,
        groundAltitudeMeters: Double,
        source: FlightDataSource,
        force: Bool = false
    ) {
        state.setGroundAltitudeMeters(groundAltitudeMeters)
        state.setMotionInterpolationDelaySeconds(
            source == .live ? Self.liveInterpolationDelaySeconds : 0
        )
        let region = RadiusRegion(centerOf: observer, radiusKm: 50)
        let regionMovedSignificantly = region.centerMoved(
            beyondMeters: Self.regionRestartThresholdMeters,
            from: currentRegion
        )
        guard force || regionMovedSignificantly || source != currentSource else {
            // Small GPS jitter is below the hysteresis threshold; the
            // existing feed keeps running and the retention buffer stays
            // intact. Aircraft don't flicker just because the observer
            // shifted a few metres.
            return
        }

        stop()
        currentRegion = region
        currentSource = source
        let generation = state.startNewGeneration()
        errorHandler?(nil)

        let feed = RadiusFlightFeed(
            provider: provider(for: source),
            region: region,
            pollInterval: source == .live ? livePollInterval : 10,
            minPollInterval: source == .live ? livePollInterval : 1
        ) { [weak self] error in
            guard self?.state.isCurrentGeneration(generation) == true else {
                return
            }

            Task { @MainActor [weak self] in
                guard self?.state.isCurrentGeneration(generation) == true else {
                    return
                }

                self?.errorHandler?(String(describing: error))
            }
        }

        feedTask = Task { [weak self] in
            for await snapshot in feed.snapshots() {
                guard !Task.isCancelled else {
                    break
                }

                guard self?.state.setSnapshot(snapshot, generation: generation) == true else {
                    continue
                }

                await MainActor.run { [weak self] in
                    guard self?.state.isCurrentGeneration(generation) == true else {
                        return
                    }

                    self?.errorHandler?(nil)
                }
            }
        }
    }

    @MainActor
    func stop() {
        feedTask?.cancel()
        feedTask = nil
        state.invalidateSnapshot()
    }

    /// How long an aircraft stays visible after its last appearance in
    /// an OpenSky poll. Decoupled from `GeoMath.maximumDeadReckoningSeconds`
    /// (the safety bound on position extrapolation) so an aircraft can
    /// stay rendered through 60–90 s coverage gaps even though its
    /// predicted position freezes at the 30 s extrapolation limit.
    static let retentionSeconds: TimeInterval = 90

    func aircraft(at date: Date) -> [Aircraft] {
        let fallbackGroundAltitudeMeters = state.groundAltitudeMeters
        let evaluationDate = date.addingTimeInterval(-state.motionInterpolationDelaySeconds)
        return state.tracks(at: date).compactMap { track in
            aircraft(
                from: track,
                at: evaluationDate,
                fallbackGroundAltitudeMeters: fallbackGroundAltitudeMeters
            )
        }
    }

    func snapshotAgeSeconds(at date: Date = Date()) -> TimeInterval? {
        state.latestSnapshotCapturedAt.map { max(date.timeIntervalSince($0), 0) }
    }

    @MainActor
    func reset(observer: GeoCoordinate, groundAltitudeMeters: Double, source: FlightDataSource) {
        update(observer: observer, groundAltitudeMeters: groundAltitudeMeters, source: source, force: true)
    }

    private func provider(for source: FlightDataSource) -> any FlightProvider {
        switch source {
        case .mock:
            return mockFlightProvider
        case .live:
            return liveFlightProvider
        }
    }

    /// Hysteresis threshold for restarting the OpenSky feed when the
    /// observer moves. The bbox is 50 km radius, so a 1 km shift in
    /// the centre doesn't meaningfully change which aircraft are in
    /// range. Sub-threshold GPS jitter no longer wipes the retention
    /// buffer.
    static let regionRestartThresholdMeters: Double = 1_000
    /// The ZRH motion study on 2026-05-06 showed that delaying live traffic
    /// adds more visible spatial error than it removes: OpenSky's reported
    /// speed/track was the best short-horizon predictor for arrivals,
    /// departures, and taxiing, while delayed interpolation lagged real motion.
    /// Keep interpolation available for genuinely bracketed late rows, but
    /// render live traffic at wall-clock time by default.
    static let liveInterpolationDelaySeconds: TimeInterval = 0
    /// Avoid slow-motion interpolation across long OpenSky coverage gaps.
    static let maximumInterpolationGapSeconds: TimeInterval = 20
    /// Surface reports are sparse and velocity/track can be stale. Taxi
    /// prediction runs at full speed briefly, then eases toward a bounded
    /// distance instead of freezing abruptly at one timestamp.
    static let fullSpeedGroundDeadReckoningSeconds: TimeInterval = 5
    static let groundDeadReckoningDecaySeconds: TimeInterval = 5
    static let maximumGroundDeadReckoningSeconds: TimeInterval = 12
    /// During landing and takeoff, stale vertical rate is the easiest way to
    /// push an aircraft through the calibrated ground plane.
    static let maximumLowAltitudeVerticalDeadReckoningSeconds: TimeInterval = 5
    /// Only apply the ground-plane altitude clamp close to the observer's
    /// calibrated ground altitude; this is a flat local approximation, not DEM.
    static let lowAltitudeGroundClampWindowMeters: Double = 150
    /// Fitted from the same ZRH sample. These are intentionally conservative:
    /// reported OpenSky kinematics beat position-derived velocity, so the app
    /// only applies a tiny damping factor and snaps near-stationary surface
    /// reports to zero to avoid slow drift around stands and taxiway holds.
    static let airborneDeadReckoningSpeedScale: Double = 0.99
    static let groundDeadReckoningSpeedScale: Double = 0.99
    static let stationaryGroundSpeedThresholdMetersPerSecond: Double = 2

    private func aircraft(
        from track: FlightRetentionBuffer.Track,
        at evaluationDate: Date,
        fallbackGroundAltitudeMeters: Double?
    ) -> Aircraft? {
        let samples = track.entries
        guard !samples.isEmpty else {
            return nil
        }

        let positionSamples = positionTimestampSamples(from: samples)
        if let interpolated = interpolatedAircraft(
            from: positionSamples,
            at: evaluationDate,
            fallbackGroundAltitudeMeters: fallbackGroundAltitudeMeters
        ) {
            return interpolated
        }

        let predictionEntry = positionSamples.last {
            $0.flight.positionTimestamp <= evaluationDate
        } ?? positionSamples.first ?? samples[0]
        // Dead-reckoning is bounded by GeoMath.maximumDeadReckoningSeconds,
        // so positions of aircraft silent for >30 s are frozen at their
        // 30 s-extrapolated position rather than drifting. Use the aircraft's
        // own position timestamp rather than the poll timestamp; OpenSky can
        // repeat stale state vectors in a fresh response, especially for
        // surface traffic.
        let elapsedSeconds = GeoMath.deadReckoningElapsedSeconds(
            capturedAt: predictionEntry.flight.positionTimestamp,
            date: evaluationDate
        )
        return aircraft(
            from: predictionEntry.flight,
            elapsedSeconds: elapsedSeconds,
            fallbackGroundAltitudeMeters: fallbackGroundAltitudeMeters
        )
    }

    private func interpolatedAircraft(
        from positionSamples: [FlightRetentionBuffer.Entry],
        at evaluationDate: Date,
        fallbackGroundAltitudeMeters: Double?
    ) -> Aircraft? {
        guard let upperIndex = positionSamples.firstIndex(where: { $0.flight.positionTimestamp > evaluationDate }),
              upperIndex > positionSamples.startIndex else {
            return nil
        }

        let lowerIndex = positionSamples.index(before: upperIndex)
        let before = positionSamples[lowerIndex]
        let after = positionSamples[upperIndex]
        let gapSeconds = after.flight.positionTimestamp.timeIntervalSince(before.flight.positionTimestamp)
        guard gapSeconds > 0,
              gapSeconds <= Self.maximumInterpolationGapSeconds else {
            return nil
        }

        let fraction = min(max(evaluationDate.timeIntervalSince(before.flight.positionTimestamp) / gapSeconds, 0), 1)
        guard let beforeCoordinate = observedCoordinate(
            for: before.flight,
            fallbackGroundAltitudeMeters: fallbackGroundAltitudeMeters
        ),
              let afterCoordinate = observedCoordinate(
                for: after.flight,
                fallbackGroundAltitudeMeters: fallbackGroundAltitudeMeters
              )
        else {
            return nil
        }

        let offset = GeoMath.enuCoordinate(observer: beforeCoordinate, target: afterCoordinate)
        var coordinate = GeoMath.coordinate(
            offsetFrom: beforeCoordinate,
            eastMeters: offset.east * fraction,
            northMeters: offset.north * fraction,
            upMeters: offset.up * fraction
        )
        if let fallbackGroundAltitudeMeters,
           coordinate.altitudeMeters <= fallbackGroundAltitudeMeters + Self.lowAltitudeGroundClampWindowMeters {
            coordinate.altitudeMeters = max(coordinate.altitudeMeters, fallbackGroundAltitudeMeters)
        }

        let horizontalDistanceMeters = offset.horizontalDistanceMeters
        let observedTrack = horizontalDistanceMeters > 2
            ? GeoMath.placement(observer: beforeCoordinate, target: afterCoordinate).bearingDegrees
            : nil
        let speed = interpolatedScalar(
            before.flight.velocityMetersPerSecond,
            after.flight.velocityMetersPerSecond,
            fraction: fraction
        ) ?? (horizontalDistanceMeters / gapSeconds)
        let isOnGround = interpolatedOnGround(
            before: before.flight,
            after: after.flight,
            coordinate: coordinate,
            fallbackGroundAltitudeMeters: fallbackGroundAltitudeMeters
        )
        let verticalRate = isOnGround ? 0 : offset.up / gapSeconds
        let callsign = interpolatedCallsign(before: before.flight, after: after.flight, fraction: fraction)
        let displayFlight = fraction < 0.5 ? before.flight : after.flight

        return Aircraft(
            id: displayFlight.id,
            callsign: callsign,
            originCountry: after.flight.originCountry ?? before.flight.originCountry,
            coordinate: coordinate,
            velocityMetersPerSecond: speed,
            trueTrackDegrees: observedTrack
                ?? interpolatedAngle(before.flight.trueTrackDegrees, after.flight.trueTrackDegrees, fraction: fraction),
            verticalRateMetersPerSecond: verticalRate,
            isOnGround: isOnGround,
            trafficKind: Self.trafficKind(for: displayFlight)
        )
    }

    private func positionTimestampSamples(
        from samples: [FlightRetentionBuffer.Entry]
    ) -> [FlightRetentionBuffer.Entry] {
        let sorted = samples.sorted {
            if $0.flight.positionTimestamp == $1.flight.positionTimestamp {
                return $0.capturedAt < $1.capturedAt
            }

            return $0.flight.positionTimestamp < $1.flight.positionTimestamp
        }

        return sorted.reduce(into: []) { result, entry in
            guard result.last?.flight.positionTimestamp == entry.flight.positionTimestamp else {
                result.append(entry)
                return
            }

            // Repeated OpenSky rows often advance lastContact while carrying
            // the same position fix. Keep the freshest metadata, but do not
            // let duplicate position timestamps create interpolation brackets.
            result[result.index(before: result.endIndex)] = entry
        }
    }

    private func aircraft(
        from flight: LiveFlight,
        elapsedSeconds: TimeInterval,
        fallbackGroundAltitudeMeters: Double?
    ) -> Aircraft? {
        let altitudeMeters: Double
        if flight.isOnGround {
            guard let fallbackGroundAltitudeMeters else {
                return nil
            }
            altitudeMeters = fallbackGroundAltitudeMeters
        } else if let reportedAltitude = flight.altitudeMeters {
            altitudeMeters = reportedAltitude
        } else {
            return nil
        }

        let speed = flight.velocityMetersPerSecond ?? 0
        let verticalRate = flight.isOnGround ? 0 : (flight.verticalRateMetersPerSecond ?? 0)
        let deadReckoningSpeed = Self.deadReckoningSpeed(for: flight)
        let horizontalElapsedSeconds = flight.isOnGround
            ? Self.groundDeadReckoningElapsedSeconds(elapsedSeconds)
            : elapsedSeconds
        let lowAltitude = fallbackGroundAltitudeMeters.map {
            altitudeMeters <= $0 + Self.lowAltitudeGroundClampWindowMeters
        } ?? false
        let verticalElapsedSeconds = lowAltitude
            ? min(elapsedSeconds, Self.maximumLowAltitudeVerticalDeadReckoningSeconds)
            : elapsedSeconds

        let horizontalCoordinate = GeoMath.deadReckonedCoordinate(
            from: GeoCoordinate(
                latitudeDegrees: flight.latitudeDegrees,
                longitudeDegrees: flight.longitudeDegrees,
                altitudeMeters: altitudeMeters
            ),
            velocityMetersPerSecond: deadReckoningSpeed,
            trueTrackDegrees: flight.trueTrackDegrees ?? 0,
            verticalRateMetersPerSecond: 0,
            elapsedSeconds: horizontalElapsedSeconds
        )
        let predictedAltitudeMeters = altitudeMeters + verticalRate * verticalElapsedSeconds
        let coordinateAltitudeMeters = fallbackGroundAltitudeMeters.map { groundAltitudeMeters in
            lowAltitude ? max(predictedAltitudeMeters, groundAltitudeMeters) : predictedAltitudeMeters
        } ?? predictedAltitudeMeters
        let coordinate = GeoCoordinate(
            latitudeDegrees: horizontalCoordinate.latitudeDegrees,
            longitudeDegrees: horizontalCoordinate.longitudeDegrees,
            altitudeMeters: coordinateAltitudeMeters
        )
        let callsign = flight.callsign.trimmingCharacters(in: .whitespacesAndNewlines)

        return Aircraft(
            id: flight.id,
            callsign: callsign.isEmpty ? flight.id.uppercased() : callsign,
            originCountry: flight.originCountry,
            coordinate: coordinate,
            velocityMetersPerSecond: speed,
            trueTrackDegrees: flight.trueTrackDegrees,
            verticalRateMetersPerSecond: flight.isOnGround ? 0 : flight.verticalRateMetersPerSecond,
            isOnGround: flight.isOnGround,
            trafficKind: Self.trafficKind(for: flight)
        )
    }

    private func observedCoordinate(
        for flight: LiveFlight,
        fallbackGroundAltitudeMeters: Double?
    ) -> GeoCoordinate? {
        let altitudeMeters: Double
        if flight.isOnGround {
            guard let fallbackGroundAltitudeMeters else {
                return nil
            }
            altitudeMeters = fallbackGroundAltitudeMeters
        } else if let reportedAltitude = flight.altitudeMeters {
            altitudeMeters = reportedAltitude
        } else {
            return nil
        }

        return GeoCoordinate(
            latitudeDegrees: flight.latitudeDegrees,
            longitudeDegrees: flight.longitudeDegrees,
            altitudeMeters: altitudeMeters
        )
    }

    private static func groundDeadReckoningElapsedSeconds(_ elapsedSeconds: TimeInterval) -> TimeInterval {
        guard elapsedSeconds > fullSpeedGroundDeadReckoningSeconds else {
            return elapsedSeconds
        }

        let taperedSeconds = elapsedSeconds - fullSpeedGroundDeadReckoningSeconds
        let easedSeconds = groundDeadReckoningDecaySeconds
            * (1 - exp(-taperedSeconds / groundDeadReckoningDecaySeconds))
        return min(
            fullSpeedGroundDeadReckoningSeconds + easedSeconds,
            maximumGroundDeadReckoningSeconds
        )
    }

    private static func deadReckoningSpeed(for flight: LiveFlight) -> Double {
        guard flight.trueTrackDegrees != nil else {
            return 0
        }

        let speed = flight.velocityMetersPerSecond ?? 0
        if flight.isOnGround {
            guard speed >= stationaryGroundSpeedThresholdMetersPerSecond else {
                return 0
            }

            return speed * groundDeadReckoningSpeedScale
        }

        return speed * airborneDeadReckoningSpeedScale
    }

    private func interpolatedScalar(_ before: Double?, _ after: Double?, fraction: Double) -> Double? {
        switch (before, after) {
        case let (before?, after?):
            return before + (after - before) * fraction
        case let (before?, nil):
            return before
        case let (nil, after?):
            return after
        case (nil, nil):
            return nil
        }
    }

    private func interpolatedAngle(_ before: Double?, _ after: Double?, fraction: Double) -> Double? {
        switch (before, after) {
        case let (before?, after?):
            let delta = (after - before + 540).truncatingRemainder(dividingBy: 360) - 180
            return GeoMath.normalizedDegrees(before + delta * fraction)
        case let (before?, nil):
            return before
        case let (nil, after?):
            return after
        case (nil, nil):
            return nil
        }
    }

    private func interpolatedOnGround(
        before: LiveFlight,
        after: LiveFlight,
        coordinate: GeoCoordinate,
        fallbackGroundAltitudeMeters: Double?
    ) -> Bool {
        guard before.isOnGround != after.isOnGround else {
            return before.isOnGround
        }

        guard let fallbackGroundAltitudeMeters else {
            return false
        }

        return coordinate.altitudeMeters <= fallbackGroundAltitudeMeters + 3
    }

    private func interpolatedCallsign(before: LiveFlight, after: LiveFlight, fraction: Double) -> String {
        let preferred = fraction < 0.5 ? before.callsign : after.callsign
        let fallback = fraction < 0.5 ? after.callsign : before.callsign
        let callsign = preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fallback
            : preferred
        let trimmed = callsign.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? before.id.uppercased() : trimmed
    }

    private static let knownZRHGroundVehicleCallsignPrefixes = [
        "ATL",
        "ORION",
        "TE",
        "URSULA",
        "VIKTOR",
        "ZEBRA"
    ]

    private static func trafficKind(for flight: LiveFlight) -> TrafficKind {
        let callsign = flight.callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if flight.isSurfaceVehicle || knownZRHGroundVehicleCallsignPrefixes.contains(where: callsign.hasPrefix) {
            return .groundVehicle
        }

        return .aircraft
    }
}

private final class LiveAircraftProviderState: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = FlightRetentionBuffer(retentionSeconds: LiveAircraftProvider.retentionSeconds)
    private var generation = 0
    private var fallbackGroundAltitudeMeters: Double?
    private var interpolationDelaySeconds: TimeInterval = 0

    var latestSnapshotCapturedAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return buffer.latestCapturedAt
    }

    var groundAltitudeMeters: Double? {
        lock.lock()
        defer { lock.unlock() }
        return fallbackGroundAltitudeMeters
    }

    var motionInterpolationDelaySeconds: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return interpolationDelaySeconds
    }

    func setGroundAltitudeMeters(_ meters: Double) {
        lock.lock()
        defer { lock.unlock() }
        fallbackGroundAltitudeMeters = meters
    }

    func setMotionInterpolationDelaySeconds(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        interpolationDelaySeconds = max(seconds, 0)
    }

    func tracks(at date: Date) -> [FlightRetentionBuffer.Track] {
        lock.lock()
        defer { lock.unlock() }
        return buffer.tracks(at: date)
    }

    func startNewGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        buffer.clear()
        return generation
    }

    func invalidateSnapshot() {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        buffer.clear()
    }

    func isCurrentGeneration(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.generation == generation
    }

    func setSnapshot(_ snapshot: FlightSnapshot, generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.generation == generation else {
            return false
        }

        buffer.ingest(snapshot)
        return true
    }
}

private extension RadiusRegion {
    init(centerOf coordinate: GeoCoordinate, radiusKm: Double) {
        self.init(
            latitudeDegrees: coordinate.latitudeDegrees,
            longitudeDegrees: coordinate.longitudeDegrees,
            radiusKm: radiusKm
        )
    }
}
