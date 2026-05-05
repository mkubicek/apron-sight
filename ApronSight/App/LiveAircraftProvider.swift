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
        return state.entries(at: date).compactMap { entry in
            // Dead-reckoning is bounded by GeoMath.maximumDeadReckoningSeconds,
            // so positions of aircraft silent for >30 s are frozen at
            // their 30 s-extrapolated position rather than drifting.
            // Use the aircraft's own position timestamp rather than the
            // poll timestamp; OpenSky can repeat stale state vectors in a
            // fresh response, especially for surface traffic.
            let elapsedSeconds = GeoMath.deadReckoningElapsedSeconds(
                capturedAt: entry.flight.positionTimestamp,
                date: date
            )
            return aircraft(
                from: entry.flight,
                elapsedSeconds: elapsedSeconds,
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
    /// Surface reports are sparse and velocity/track can be stale, so avoid
    /// taxiing aircraft drifting far between OpenSky polls.
    static let maximumGroundDeadReckoningSeconds: TimeInterval = 5
    /// During landing and takeoff, stale vertical rate is the easiest way to
    /// push an aircraft through the calibrated ground plane.
    static let maximumLowAltitudeVerticalDeadReckoningSeconds: TimeInterval = 5
    /// Only apply the ground-plane altitude clamp close to the observer's
    /// calibrated ground altitude; this is a flat local approximation, not DEM.
    static let lowAltitudeGroundClampWindowMeters: Double = 150

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
        let deadReckoningSpeed = flight.trueTrackDegrees == nil ? 0 : speed
        let horizontalElapsedSeconds = flight.isOnGround
            ? min(elapsedSeconds, Self.maximumGroundDeadReckoningSeconds)
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

    private static let knownZRHGroundVehicleCallsigns: Set<String> = [
        "ATL783",
        "ATL786",
        "ORION1",
        "TE21",
        "TE22",
        "TE25",
        "VIKTOR36",
        "ZEBRA1",
        "ZEBRA7",
        "ZEBRA8"
    ]

    private static func trafficKind(for flight: LiveFlight) -> TrafficKind {
        let callsign = flight.callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if flight.isSurfaceVehicle || knownZRHGroundVehicleCallsigns.contains(callsign) {
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

    func setGroundAltitudeMeters(_ meters: Double) {
        lock.lock()
        defer { lock.unlock() }
        fallbackGroundAltitudeMeters = meters
    }

    func entries(at date: Date) -> [FlightRetentionBuffer.Entry] {
        lock.lock()
        defer { lock.unlock() }
        return buffer.entries(at: date)
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
