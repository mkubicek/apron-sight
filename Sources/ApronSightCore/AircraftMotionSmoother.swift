import Foundation

/// Per-aircraft visual motion filter.
///
/// The upstream `AircraftProvider` should keep producing the best physical
/// estimate it can. This smoother owns only the rendered estimate: when a new
/// target arrives, it keeps the previous render position as a residual offset
/// from the target and exponentially decays that residual over a short,
/// phase-specific response time. That reduces one-frame visual jumps without
/// adding a global delay to the live feed.
public struct AircraftMotionSmoother: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var airbornePositionResponseSeconds: TimeInterval
        public var surfacePositionResponseSeconds: TimeInterval
        public var takeoffPositionResponseSeconds: TimeInterval
        public var landingPositionResponseSeconds: TimeInterval
        public var airborneTrackResponseSeconds: TimeInterval
        public var surfaceTrackResponseSeconds: TimeInterval
        public var takeoffTrackResponseSeconds: TimeInterval
        public var landingTrackResponseSeconds: TimeInterval
        public var maximumUpdateGapSeconds: TimeInterval
        public var stationaryGroundSpeedThresholdMetersPerSecond: Double

        public init(
            airbornePositionResponseSeconds: TimeInterval = 1.0,
            surfacePositionResponseSeconds: TimeInterval = 2.0,
            takeoffPositionResponseSeconds: TimeInterval = 0.65,
            landingPositionResponseSeconds: TimeInterval = 0.85,
            airborneTrackResponseSeconds: TimeInterval = 0.75,
            surfaceTrackResponseSeconds: TimeInterval = 1.5,
            takeoffTrackResponseSeconds: TimeInterval = 0.35,
            landingTrackResponseSeconds: TimeInterval = 0.9,
            maximumUpdateGapSeconds: TimeInterval = 1.0,
            stationaryGroundSpeedThresholdMetersPerSecond: Double = 2.0
        ) {
            self.airbornePositionResponseSeconds = airbornePositionResponseSeconds
            self.surfacePositionResponseSeconds = surfacePositionResponseSeconds
            self.takeoffPositionResponseSeconds = takeoffPositionResponseSeconds
            self.landingPositionResponseSeconds = landingPositionResponseSeconds
            self.airborneTrackResponseSeconds = airborneTrackResponseSeconds
            self.surfaceTrackResponseSeconds = surfaceTrackResponseSeconds
            self.takeoffTrackResponseSeconds = takeoffTrackResponseSeconds
            self.landingTrackResponseSeconds = landingTrackResponseSeconds
            self.maximumUpdateGapSeconds = maximumUpdateGapSeconds
            self.stationaryGroundSpeedThresholdMetersPerSecond = stationaryGroundSpeedThresholdMetersPerSecond
        }

        public static let `default` = Configuration()
    }

    private enum Phase: Equatable, Sendable {
        case airborne
        case surface
        case takeoff
        case landing
    }

    private struct State: Sendable {
        var aircraft: Aircraft
        var lastTarget: Aircraft
        var lastUpdateDate: Date
    }

    public var configuration: Configuration
    private var statesByID: [String: State] = [:]

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    public mutating func reset() {
        statesByID.removeAll(keepingCapacity: true)
    }

    public mutating func smooth(_ targets: [Aircraft], at date: Date = Date()) -> [Aircraft] {
        let activeIDs = Set(targets.map(\.id))
        statesByID = statesByID.filter { activeIDs.contains($0.key) }

        return targets.map { target in
            let previous = statesByID[target.id]
            let aircraft = smoothedAircraft(for: target, previous: previous, at: date)
            statesByID[target.id] = State(
                aircraft: aircraft,
                lastTarget: target,
                lastUpdateDate: date
            )
            return aircraft
        }
    }

    private func smoothedAircraft(for target: Aircraft, previous: State?, at date: Date) -> Aircraft {
        guard let previous else {
            return firstRenderedAircraft(for: target)
        }

        let elapsedSeconds = max(date.timeIntervalSince(previous.lastUpdateDate), 0)
        guard elapsedSeconds <= configuration.maximumUpdateGapSeconds else {
            return firstRenderedAircraft(for: target)
        }

        let phase = phase(for: target, previous: previous)
        let positionResponseSeconds = responseSeconds(forPositionPhase: phase)
        let trackResponseSeconds = responseSeconds(forTrackPhase: phase)
        let positionResidualScale = residualScale(elapsedSeconds: elapsedSeconds, responseSeconds: positionResponseSeconds)
        let trackBlend = responseBlend(elapsedSeconds: elapsedSeconds, responseSeconds: trackResponseSeconds)

        let predictedRenderedCoordinate = predictedRenderedCoordinate(
            from: previous,
            elapsedSeconds: elapsedSeconds
        )
        let residual = GeoMath.enuCoordinate(observer: target.coordinate, target: predictedRenderedCoordinate)
        let horizontalCoordinate = GeoMath.coordinate(
            offsetFrom: target.coordinate,
            eastMeters: residual.east * positionResidualScale,
            northMeters: residual.north * positionResidualScale,
            upMeters: verticalResidualMeters(
                residual.up,
                scale: positionResidualScale,
                phase: phase,
                target: target
            )
        )

        var smoothed = target
        smoothed.coordinate = target.isOnGround || target.trafficKind == .groundVehicle
            ? GeoCoordinate(
                latitudeDegrees: horizontalCoordinate.latitudeDegrees,
                longitudeDegrees: horizontalCoordinate.longitudeDegrees,
                altitudeMeters: target.coordinate.altitudeMeters
            )
            : horizontalCoordinate
        smoothed.velocityMetersPerSecond = smoothedSpeed(
            previous: previous.aircraft.velocityMetersPerSecond,
            target: target.velocityMetersPerSecond,
            blend: trackBlend,
            aircraft: target
        )
        smoothed.verticalRateMetersPerSecond = target.isOnGround
            ? 0
            : smoothedScalar(previous.aircraft.verticalRateMetersPerSecond, target.verticalRateMetersPerSecond, blend: trackBlend)
        smoothed.trueTrackDegrees = smoothedTrack(
            previous: previous,
            target: target,
            phase: phase,
            blend: trackBlend
        )
        return smoothed
    }

    private func firstRenderedAircraft(for target: Aircraft) -> Aircraft {
        var aircraft = target
        if aircraft.isOnGround,
           (aircraft.velocityMetersPerSecond ?? 0) < configuration.stationaryGroundSpeedThresholdMetersPerSecond {
            aircraft.velocityMetersPerSecond = 0
        }
        return aircraft
    }

    private func predictedRenderedCoordinate(from previous: State, elapsedSeconds: TimeInterval) -> GeoCoordinate {
        let target = previous.lastTarget
        guard let track = target.trueTrackDegrees else {
            return previous.aircraft.coordinate
        }

        let speed = target.velocityMetersPerSecond ?? 0
        if target.isOnGround || target.trafficKind == .groundVehicle,
           speed < configuration.stationaryGroundSpeedThresholdMetersPerSecond {
            return previous.aircraft.coordinate
        }

        return GeoMath.deadReckonedCoordinate(
            from: previous.aircraft.coordinate,
            velocityMetersPerSecond: speed,
            trueTrackDegrees: track,
            verticalRateMetersPerSecond: target.isOnGround ? 0 : (target.verticalRateMetersPerSecond ?? 0),
            elapsedSeconds: elapsedSeconds
        )
    }

    private func phase(for target: Aircraft, previous: State?) -> Phase {
        if target.isOnGround || target.trafficKind == .groundVehicle {
            return previous?.lastTarget.isOnGround == false ? .landing : .surface
        }

        if previous?.lastTarget.isOnGround == true {
            return .takeoff
        }

        return .airborne
    }

    private func responseSeconds(forPositionPhase phase: Phase) -> TimeInterval {
        switch phase {
        case .airborne:
            return configuration.airbornePositionResponseSeconds
        case .surface:
            return configuration.surfacePositionResponseSeconds
        case .takeoff:
            return configuration.takeoffPositionResponseSeconds
        case .landing:
            return configuration.landingPositionResponseSeconds
        }
    }

    private func responseSeconds(forTrackPhase phase: Phase) -> TimeInterval {
        switch phase {
        case .airborne:
            return configuration.airborneTrackResponseSeconds
        case .surface:
            return configuration.surfaceTrackResponseSeconds
        case .takeoff:
            return configuration.takeoffTrackResponseSeconds
        case .landing:
            return configuration.landingTrackResponseSeconds
        }
    }

    private func verticalResidualMeters(
        _ residualMeters: Double,
        scale: Double,
        phase: Phase,
        target: Aircraft
    ) -> Double {
        if target.isOnGround || target.trafficKind == .groundVehicle || phase == .landing {
            return 0
        }

        return residualMeters * scale
    }

    private func smoothedSpeed(
        previous: Double?,
        target: Double?,
        blend: Double,
        aircraft: Aircraft
    ) -> Double? {
        if aircraft.isOnGround || aircraft.trafficKind == .groundVehicle,
           (target ?? 0) < configuration.stationaryGroundSpeedThresholdMetersPerSecond {
            return 0
        }

        return smoothedScalar(previous, target, blend: blend)
    }

    private func smoothedScalar(_ previous: Double?, _ target: Double?, blend: Double) -> Double? {
        switch (previous, target) {
        case let (previous?, target?):
            return previous + (target - previous) * blend
        case (nil, let target?):
            return target
        case (let previous?, nil):
            return previous
        case (nil, nil):
            return nil
        }
    }

    private func smoothedTrack(
        previous: State,
        target: Aircraft,
        phase: Phase,
        blend: Double
    ) -> Double? {
        guard let targetTrack = target.trueTrackDegrees else {
            return previous.aircraft.trueTrackDegrees
        }

        if phase == .takeoff {
            return targetTrack
        }

        if target.isOnGround || target.trafficKind == .groundVehicle,
           (target.velocityMetersPerSecond ?? 0) < configuration.stationaryGroundSpeedThresholdMetersPerSecond {
            return previous.aircraft.trueTrackDegrees ?? targetTrack
        }

        guard let previousTrack = previous.aircraft.trueTrackDegrees else {
            return targetTrack
        }

        let delta = angularDeltaDegrees(from: previousTrack, to: targetTrack)
        return GeoMath.normalizedDegrees(previousTrack + delta * blend)
    }

    private func residualScale(elapsedSeconds: TimeInterval, responseSeconds: TimeInterval) -> Double {
        exp(-max(elapsedSeconds, 0) / max(responseSeconds, 0.001))
    }

    private func responseBlend(elapsedSeconds: TimeInterval, responseSeconds: TimeInterval) -> Double {
        1 - residualScale(elapsedSeconds: elapsedSeconds, responseSeconds: responseSeconds)
    }

    private func angularDeltaDegrees(from: Double, to: Double) -> Double {
        (to - from + 540).truncatingRemainder(dividingBy: 360) - 180
    }
}

public enum MotionPerceptionMetrics {
    public struct Distribution: Equatable, Sendable {
        public var count: Int
        public var median: Double
        public var p75: Double
        public var p90: Double
        public var mean: Double
    }

    public struct Summary: Equatable, Sendable {
        public var snapMeters: Distribution
        public var accuracyMeters: Distribution
        public var angularSnapDegrees: Distribution?
    }

    public struct Sample: Equatable, Sendable {
        public var before: Aircraft
        public var after: Aircraft
        public var target: Aircraft
        public var observer: GeoCoordinate?

        public init(before: Aircraft, after: Aircraft, target: Aircraft, observer: GeoCoordinate? = nil) {
            self.before = before
            self.after = after
            self.target = target
            self.observer = observer
        }
    }

    public static func summarize(_ samples: [Sample]) -> Summary? {
        guard !samples.isEmpty else {
            return nil
        }

        let snapMeters = samples.map {
            horizontalDistanceMeters(from: $0.before.coordinate, to: $0.after.coordinate)
        }
        let accuracyMeters = samples.map {
            horizontalDistanceMeters(from: $0.after.coordinate, to: $0.target.coordinate)
        }
        let angularSnaps = samples.compactMap { sample -> Double? in
            guard let observer = sample.observer else {
                return nil
            }
            return angularSnapDegrees(observer: observer, before: sample.before.coordinate, after: sample.after.coordinate)
        }

        guard let snapDistribution = distribution(snapMeters),
              let accuracyDistribution = distribution(accuracyMeters)
        else {
            return nil
        }

        return Summary(
            snapMeters: snapDistribution,
            accuracyMeters: accuracyDistribution,
            angularSnapDegrees: distribution(angularSnaps)
        )
    }

    public static func horizontalDistanceMeters(from: GeoCoordinate, to: GeoCoordinate) -> Double {
        GeoMath.enuCoordinate(observer: from, target: to).horizontalDistanceMeters
    }

    public static func angularSnapDegrees(
        observer: GeoCoordinate,
        before: GeoCoordinate,
        after: GeoCoordinate
    ) -> Double? {
        let beforeENU = GeoMath.enuCoordinate(observer: observer, target: before)
        let afterENU = GeoMath.enuCoordinate(observer: observer, target: after)
        let beforeLength = beforeENU.slantDistanceMeters
        let afterLength = afterENU.slantDistanceMeters
        guard beforeLength > 1, afterLength > 1 else {
            return nil
        }

        let dot = beforeENU.east * afterENU.east
            + beforeENU.north * afterENU.north
            + beforeENU.up * afterENU.up
        let cosine = min(max(dot / (beforeLength * afterLength), -1), 1)
        return GeoMath.radiansToDegrees(acos(cosine))
    }

    public static func distribution(_ values: [Double]) -> Distribution? {
        guard !values.isEmpty else {
            return nil
        }

        let sorted = values.sorted()
        return Distribution(
            count: sorted.count,
            median: percentile(0.5, sorted: sorted),
            p75: percentile(0.75, sorted: sorted),
            p90: percentile(0.9, sorted: sorted),
            mean: sorted.reduce(0, +) / Double(sorted.count)
        )
    }

    private static func percentile(_ fraction: Double, sorted values: [Double]) -> Double {
        let index = Int((Double(values.count - 1) * fraction).rounded())
        return values[min(max(index, 0), values.count - 1)]
    }
}
