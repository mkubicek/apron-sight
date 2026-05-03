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
    private let mockFlightProvider = MockFlightProvider(count: 12)
    private let state = LiveAircraftProviderState()
    private var feedTask: Task<Void, Never>?
    private var currentRegion: RadiusRegion?
    private var currentSource: FlightDataSource?

    var errorHandler: (@MainActor (String?) -> Void)?

    init(liveFlightProvider: (any FlightProvider)? = nil) {
        self.liveFlightProvider = liveFlightProvider ?? OpenSkyClient.anonymous()
    }

    @MainActor
    func start(observer: GeoCoordinate, source: FlightDataSource) {
        update(observer: observer, source: source, force: true)
    }

    @MainActor
    func update(observer: GeoCoordinate, source: FlightDataSource, force: Bool = false) {
        let region = RadiusRegion(centerOf: observer, radiusKm: 50)
        guard force || region != currentRegion || source != currentSource else {
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
            pollInterval: 10,
            minPollInterval: source == .live ? 10 : 1
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

    func aircraft(at date: Date) -> [Aircraft] {
        guard let snapshot = state.snapshot else {
            return []
        }

        let elapsedSeconds = GeoMath.deadReckoningElapsedSeconds(capturedAt: snapshot.capturedAt, date: date)
        return snapshot.flights.compactMap { flight in
            aircraft(from: flight, elapsedSeconds: elapsedSeconds)
        }
    }

    func snapshotAgeSeconds(at date: Date = Date()) -> TimeInterval? {
        state.snapshot.map { max(date.timeIntervalSince($0.capturedAt), 0) }
    }

    @MainActor
    func reset(observer: GeoCoordinate, source: FlightDataSource) {
        update(observer: observer, source: source, force: true)
    }

    private func provider(for source: FlightDataSource) -> any FlightProvider {
        switch source {
        case .mock:
            return mockFlightProvider
        case .live:
            return liveFlightProvider
        }
    }

    private func aircraft(from flight: LiveFlight, elapsedSeconds: TimeInterval) -> Aircraft? {
        guard let altitudeMeters = flight.altitudeMeters else {
            return nil
        }

        let speed = flight.velocityMetersPerSecond ?? 0
        let verticalRate = flight.verticalRateMetersPerSecond ?? 0
        let coordinate = GeoMath.deadReckonedCoordinate(
            from: GeoCoordinate(
                latitudeDegrees: flight.latitudeDegrees,
                longitudeDegrees: flight.longitudeDegrees,
                altitudeMeters: altitudeMeters
            ),
            velocityMetersPerSecond: speed,
            trueTrackDegrees: flight.trueTrackDegrees ?? 0,
            verticalRateMetersPerSecond: verticalRate,
            elapsedSeconds: elapsedSeconds
        )
        let callsign = flight.callsign.trimmingCharacters(in: .whitespacesAndNewlines)

        return Aircraft(
            id: flight.id,
            callsign: callsign.isEmpty ? flight.id.uppercased() : callsign,
            originCountry: flight.originCountry,
            coordinate: coordinate,
            velocityMetersPerSecond: speed,
            trueTrackDegrees: flight.trueTrackDegrees,
            verticalRateMetersPerSecond: flight.verticalRateMetersPerSecond,
            isOnGround: flight.isOnGround
        )
    }
}

private final class LiveAircraftProviderState: @unchecked Sendable {
    private let lock = NSLock()
    private var latestSnapshot: FlightSnapshot?
    private var generation = 0

    var snapshot: FlightSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return latestSnapshot
    }

    func startNewGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        latestSnapshot = nil
        return generation
    }

    func invalidateSnapshot() {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        latestSnapshot = nil
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

        latestSnapshot = snapshot
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
