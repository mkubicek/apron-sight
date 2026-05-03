import Foundation
import simd
import SwiftUI

struct AircraftStatus {
    let aircraft: Aircraft
    let relativeDistanceMeters: Double
    let heightAboveGroundMeters: Double
    let groundSpeedMetersPerSecond: Double
}

@MainActor
final class AppModel: ObservableObject {
    static let a350900LengthMeters = 66.8
    static let importedAircraftLengthMeters = 5.0
    static let demoMarkerLengthMeters = 8.0
    static let defaultObserverHeightAboveGroundMeters = 1.6

    @Published var observerLatitude: Double
    @Published var observerLongitude: Double
    @Published var observerAltitude: Double
    @Published var observerHeightAboveGroundMeters: Double
    @Published var yawOffsetDegrees: Double
    @Published var targetEastOffsetMeters: Double
    @Published var targetNorthOffsetMeters: Double
    @Published var targetAltitudeOffsetMeters: Double
    @Published var localRightOffsetMeters: Double
    @Published var localForwardOffsetMeters: Double
    @Published var aircraftYawOffsetDegrees: Double
    @Published var aircraftLengthMeters: Double
    @Published var groundCalibrationOffsetMeters: Double
    @Published var showGroundCursor: Bool
    @Published var groundCursorRightOffsetMeters: Double
    @Published var groundCursorForwardOffsetMeters: Double
    @Published var showCompassOverlay: Bool
    @Published var showDistanceOverlay: Bool
    @Published var showProjectionShadow: Bool
    @Published var selectedAircraftID: String?
    @Published private(set) var simulationElapsedSeconds: TimeInterval
    @Published private(set) var aircraft: [Aircraft]

    private let aircraftProvider: any AircraftProvider
    private var simulationTask: Task<Void, Never>?
    private var simulationStartDate: Date = Date()

    init(
        observer: GeoCoordinate = DemoScenario.defaultObserver,
        observerHeightAboveGroundMeters: Double = AppModel.defaultObserverHeightAboveGroundMeters,
        yawOffsetDegrees: Double = 0,
        targetEastOffsetMeters: Double = 0,
        targetNorthOffsetMeters: Double = 0,
        targetAltitudeOffsetMeters: Double = 0,
        localRightOffsetMeters: Double = 0,
        localForwardOffsetMeters: Double = 0,
        aircraftYawOffsetDegrees: Double = 0,
        aircraftLengthMeters: Double = AppModel.a350900LengthMeters,
        groundCalibrationOffsetMeters: Double = 0,
        showGroundCursor: Bool = true,
        groundCursorRightOffsetMeters: Double = 0,
        groundCursorForwardOffsetMeters: Double = 25,
        showCompassOverlay: Bool = true,
        showDistanceOverlay: Bool = true,
        showProjectionShadow: Bool = true,
        selectedAircraftID: String? = nil,
        aircraftProvider: any AircraftProvider = MockAircraftProvider()
    ) {
        self.observerLatitude = observer.latitudeDegrees
        self.observerLongitude = observer.longitudeDegrees
        self.observerAltitude = observer.altitudeMeters
        self.observerHeightAboveGroundMeters = observerHeightAboveGroundMeters
        self.yawOffsetDegrees = yawOffsetDegrees
        self.targetEastOffsetMeters = targetEastOffsetMeters
        self.targetNorthOffsetMeters = targetNorthOffsetMeters
        self.targetAltitudeOffsetMeters = targetAltitudeOffsetMeters
        self.localRightOffsetMeters = localRightOffsetMeters
        self.localForwardOffsetMeters = localForwardOffsetMeters
        self.aircraftYawOffsetDegrees = aircraftYawOffsetDegrees
        self.aircraftLengthMeters = aircraftLengthMeters
        self.groundCalibrationOffsetMeters = groundCalibrationOffsetMeters
        self.showGroundCursor = showGroundCursor
        self.groundCursorRightOffsetMeters = groundCursorRightOffsetMeters
        self.groundCursorForwardOffsetMeters = groundCursorForwardOffsetMeters
        self.showCompassOverlay = showCompassOverlay
        self.showDistanceOverlay = showDistanceOverlay
        self.showProjectionShadow = showProjectionShadow
        self.selectedAircraftID = selectedAircraftID
        self.aircraftProvider = aircraftProvider
        self.simulationElapsedSeconds = 0
        self.aircraft = aircraftProvider.aircraft()
    }

    var observer: GeoCoordinate {
        GeoCoordinate(
            latitudeDegrees: observerLatitude,
            longitudeDegrees: observerLongitude,
            altitudeMeters: observerAltitude
        )
    }

    var observerGroundElevationMeters: Double {
        observerAltitude - observerHeightAboveGroundMeters + groundCalibrationOffsetMeters
    }

    var observerGroundRealityPosition: SIMD3<Float> {
        SIMD3<Float>(0, Float(observerGroundElevationMeters - observerAltitude), 0)
    }

    var placement: GeoPlacement {
        placement(for: target)
    }

    var targetLocalCoordinate: LocalCoordinate {
        GeoMath.localCoordinate(for: placement, yawOffsetDegrees: yawOffsetDegrees)
    }

    var geospatialRealityPosition: SIMD3<Float> {
        realityPosition(for: target, includingTuning: false)
    }

    var localPlacementOffset: SIMD3<Float> {
        SIMD3<Float>(
            Float(localRightOffsetMeters),
            0,
            Float(-localForwardOffsetMeters)
        )
    }

    var targetRealityPosition: SIMD3<Float> {
        realityPosition(for: target)
    }

    var targetProjectionPosition: SIMD3<Float> {
        groundRealityPosition(under: targetRealityPosition)
    }

    var targetGroundRealityPosition: SIMD3<Float> {
        targetProjectionPosition
    }

    var targetGroundElevationMeters: Double {
        observerGroundElevationMeters
    }

    var aircraftGroundElevationMeters: Double {
        observerGroundElevationMeters
    }

    var aircraftScale: SIMD3<Float> {
        let scale = Float(max(aircraftLengthMeters, 1) / Self.importedAircraftLengthMeters)
        return SIMD3<Float>(repeating: scale)
    }

    var aircraftRealityYawDegrees: Double {
        aircraftRealityYawDegrees(for: target)
    }

    var tunedDistanceMeters: Double {
        relativeDistanceMeters(for: target)
    }

    var estimatedAircraftAngularLengthDegrees: Double {
        let distance = max(tunedDistanceMeters, 0.001)
        return GeoMath.radiansToDegrees(2 * atan((aircraftLengthMeters / 2) / distance))
    }

    var groundCursorENUOffset: (east: Double, north: Double) {
        GeoMath.enuHorizontalOffset(
            localX: groundCursorRightOffsetMeters,
            localZ: -groundCursorForwardOffsetMeters,
            yawOffsetDegrees: yawOffsetDegrees
        )
    }

    var groundCursorDistanceMeters: Double {
        hypot(groundCursorRightOffsetMeters, groundCursorForwardOffsetMeters)
    }

    var groundCursorWorldBearingDegrees: Double {
        guard groundCursorDistanceMeters > 0 else {
            return yawOffsetDegrees
        }

        let relativeBearing = GeoMath.radiansToDegrees(atan2(groundCursorRightOffsetMeters, groundCursorForwardOffsetMeters))
        return GeoMath.normalizedDegrees(yawOffsetDegrees + relativeBearing)
    }

    var groundCursorCoordinate: GeoCoordinate {
        let offset = groundCursorENUOffset
        var coordinate = GeoMath.coordinate(
            offsetFrom: GeoCoordinate(
                latitudeDegrees: observerLatitude,
                longitudeDegrees: observerLongitude,
                altitudeMeters: observerGroundElevationMeters
            ),
            eastMeters: offset.east,
            northMeters: offset.north,
            upMeters: 0
        )
        coordinate.altitudeMeters = observerGroundElevationMeters
        return coordinate
    }

    var groundCursorRealityPosition: SIMD3<Float> {
        SIMD3<Float>(
            Float(groundCursorRightOffsetMeters),
            observerGroundRealityPosition.y,
            Float(-groundCursorForwardOffsetMeters)
        )
    }

    var relativeBearingDegrees: Double {
        relativeBearingDegrees(for: target)
    }

    var target: Aircraft {
        aircraft.first ?? DemoScenario.homeDemoAircraft
    }

    var selectedAircraft: Aircraft? {
        guard let selectedAircraftID else {
            return nil
        }

        return aircraft.first(where: { $0.id == selectedAircraftID })
    }

    var selectedAircraftStatus: AircraftStatus? {
        guard let selectedAircraft else {
            return nil
        }

        return status(for: selectedAircraft)
    }

    var targetCoordinate: GeoCoordinate {
        displayCoordinate(for: target)
    }

    var calibrationStatus: String {
        yawOffsetDegrees == 0 ? "Manual yaw: 0 deg" : "Manual yaw set"
    }

    func displayCoordinate(for aircraft: Aircraft) -> GeoCoordinate {
        guard aircraft.id == target.id else {
            return aircraft.coordinate
        }

        return GeoMath.coordinate(
            offsetFrom: aircraft.coordinate,
            eastMeters: targetEastOffsetMeters,
            northMeters: targetNorthOffsetMeters,
            upMeters: targetAltitudeOffsetMeters
        )
    }

    func placement(for aircraft: Aircraft) -> GeoPlacement {
        GeoMath.placement(observer: observer, target: displayCoordinate(for: aircraft))
    }

    func realityPosition(for aircraft: Aircraft, includingTuning: Bool = true) -> SIMD3<Float> {
        let coordinate = GeoMath.localCoordinate(for: placement(for: aircraft), yawOffsetDegrees: yawOffsetDegrees)
        var position = SIMD3<Float>(Float(coordinate.x), Float(coordinate.y), Float(coordinate.z))
        if includingTuning && aircraft.id == target.id {
            position += localPlacementOffset
        }
        return position
    }

    func groundRealityPosition(under position: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(position.x, observerGroundRealityPosition.y, position.z)
    }

    func relativeDistanceMeters(for aircraft: Aircraft) -> Double {
        let position = realityPosition(for: aircraft)
        return Double(sqrt(position.x * position.x + position.y * position.y + position.z * position.z))
    }

    func heightAboveGroundMeters(for aircraft: Aircraft) -> Double {
        let position = realityPosition(for: aircraft)
        return Double(position.y - observerGroundRealityPosition.y)
    }

    func relativeBearingDegrees(for aircraft: Aircraft) -> Double {
        GeoMath.normalizedDegrees(placement(for: aircraft).bearingDegrees - yawOffsetDegrees)
    }

    func aircraftRealityYawDegrees(for aircraft: Aircraft) -> Double {
        let track = aircraft.trueTrackDegrees ?? placement(for: aircraft).bearingDegrees
        return GeoMath.normalizedDegrees(yawOffsetDegrees - track + aircraftYawOffsetDegrees)
    }

    func status(for aircraft: Aircraft) -> AircraftStatus {
        AircraftStatus(
            aircraft: aircraft,
            relativeDistanceMeters: relativeDistanceMeters(for: aircraft),
            heightAboveGroundMeters: heightAboveGroundMeters(for: aircraft),
            groundSpeedMetersPerSecond: aircraft.velocityMetersPerSecond ?? 0
        )
    }

    func selectionRadiusMeters(for aircraft: Aircraft) -> Double {
        // Hold the tap target at ~2.5° of visual angle (tan 2.5° ≈ 0.044) so a
        // distant aircraft is not a pinprick. Floor is the aircraft length so
        // close-up taps still cover the visible airframe; ceiling stops giant
        // aircraft on the horizon from blanketing their neighbours.
        let distance = relativeDistanceMeters(for: aircraft)
        let angularRadius = distance * 0.044
        return min(max(angularRadius, aircraftLengthMeters * 0.7, 60), 1200)
    }

    func statusWindowPosition(for aircraft: Aircraft) -> SIMD3<Float> {
        let position = realityPosition(for: aircraft)
        let distance = max(Float(relativeDistanceMeters(for: aircraft)), 1)
        return position + SIMD3<Float>(
            max(18, distance * 0.025),
            max(22, distance * 0.035),
            0
        )
    }

    func statusWindowScale(for aircraft: Aircraft) -> SIMD3<Float> {
        let scale = max(Float(relativeDistanceMeters(for: aircraft)) * 0.012, 1.0)
        return SIMD3<Float>(repeating: scale)
    }

    func selectAircraft(id: String) {
        selectedAircraftID = id
    }

    func clearSelectedAircraft() {
        selectedAircraftID = nil
    }

    func resetTargetTuning() {
        targetEastOffsetMeters = 0
        targetNorthOffsetMeters = 0
        targetAltitudeOffsetMeters = 0
        localRightOffsetMeters = 0
        localForwardOffsetMeters = 0
        aircraftYawOffsetDegrees = 0
    }

    func useRealA350Size() {
        aircraftLengthMeters = Self.a350900LengthMeters
    }

    func useDemoMarkerSize() {
        aircraftLengthMeters = Self.demoMarkerLengthMeters
    }

    func resetGroundCursor() {
        groundCursorRightOffsetMeters = 0
        groundCursorForwardOffsetMeters = 25
    }

    func alignTargetStraightAhead() {
        yawOffsetDegrees = placement.bearingDegrees.rounded()
    }

    func reloadAircraft() {
        aircraft = aircraftProvider.aircraft()
    }

    /// Aircraft positions evaluated at `date`. Pure function — does not touch
    /// `@Published` state, so the per-frame renderer can call this on every
    /// frame without invalidating SwiftUI.
    func currentAircraft(at date: Date = Date()) -> [Aircraft] {
        let elapsed = date.timeIntervalSince(simulationStartDate)
        return Self.simulationSeeds.map { seed in
            simulatedAircraft(seed: seed, elapsedSeconds: elapsed)
        }
    }

    /// Snap the simulation back to t=0 so the cluster sits near the observer
    /// again after aircraft have drifted to the edge of their loop.
    func resetAircraftPositions() {
        simulationStartDate = Date()
        simulationElapsedSeconds = 0
        aircraft = currentAircraft()
    }

    func startSimulation() {
        guard simulationTask == nil else {
            return
        }

        simulationStartDate = Date().addingTimeInterval(-simulationElapsedSeconds)
        simulationTask = Task { [weak self] in
            guard let self else {
                return
            }

            await self.runSimulation()
        }
    }

    func stopSimulation() {
        simulationTask?.cancel()
        simulationTask = nil
    }

    /// Slow tick: keeps `@Published aircraft` fresh enough for the debug panel
    /// and for selection lookup, without hammering SwiftUI invalidation. Per-
    /// frame motion is driven by `currentAircraft(at:)` from the RealityKit
    /// renderer, so this loop does *not* need to run at frame rate.
    private func runSimulation() async {
        while !Task.isCancelled {
            let elapsed = Date().timeIntervalSince(simulationStartDate)
            simulationElapsedSeconds = elapsed
            aircraft = Self.simulationSeeds.map { seed in
                simulatedAircraft(seed: seed, elapsedSeconds: elapsed)
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func simulatedAircraft(seed: FlightSeed, elapsedSeconds: TimeInterval) -> Aircraft {
        let trackRadians = GeoMath.degreesToRadians(seed.trackDegrees)
        let forwardEast = sin(trackRadians)
        let forwardNorth = cos(trackRadians)
        let rightEast = cos(trackRadians)
        let rightNorth = -sin(trackRadians)
        let travelled = (elapsedSeconds * seed.speedMetersPerSecond + seed.phaseMeters)
            .truncatingRemainder(dividingBy: seed.pathLengthMeters)
        let along = travelled - seed.pathLengthMeters / 2
        let east = along * forwardEast + seed.crossTrackMeters * rightEast
        let north = along * forwardNorth + seed.crossTrackMeters * rightNorth
        let ground = GeoCoordinate(
            latitudeDegrees: observerLatitude,
            longitudeDegrees: observerLongitude,
            altitudeMeters: observerGroundElevationMeters
        )

        return Aircraft(
            id: seed.id,
            callsign: seed.callsign,
            coordinate: GeoMath.coordinate(
                offsetFrom: ground,
                eastMeters: east,
                northMeters: north,
                upMeters: seed.heightAboveGroundMeters
            ),
            velocityMetersPerSecond: seed.speedMetersPerSecond,
            trueTrackDegrees: seed.trackDegrees,
            verticalRateMetersPerSecond: 0,
            isOnGround: false
        )
    }

    private static let simulationSeeds: [FlightSeed] = [
        FlightSeed(id: "DEMO01", callsign: "SWR214", trackDegrees: 64, speedMetersPerSecond: 42, heightAboveGroundMeters: 320, crossTrackMeters: -35, pathLengthMeters: 12000, phaseMeters: 6200),
        FlightSeed(id: "DEMO02", callsign: "EZY83K", trackDegrees: 306, speedMetersPerSecond: 48, heightAboveGroundMeters: 480, crossTrackMeters: 160, pathLengthMeters: 14000, phaseMeters: 6400),
        FlightSeed(id: "DEMO03", callsign: "DLH71P", trackDegrees: 102, speedMetersPerSecond: 55, heightAboveGroundMeters: 610, crossTrackMeters: -280, pathLengthMeters: 15000, phaseMeters: 8450),
        FlightSeed(id: "DEMO04", callsign: "QTR51", trackDegrees: 250, speedMetersPerSecond: 68, heightAboveGroundMeters: 930, crossTrackMeters: 420, pathLengthMeters: 18000, phaseMeters: 7650),
        FlightSeed(id: "DEMO05", callsign: "AUA905", trackDegrees: 176, speedMetersPerSecond: 39, heightAboveGroundMeters: 390, crossTrackMeters: 260, pathLengthMeters: 13000, phaseMeters: 7350),
        FlightSeed(id: "DEMO06", callsign: "AFR46T", trackDegrees: 334, speedMetersPerSecond: 60, heightAboveGroundMeters: 760, crossTrackMeters: -520, pathLengthMeters: 17000, phaseMeters: 9900),
        FlightSeed(id: "DEMO07", callsign: "BAW773", trackDegrees: 74, speedMetersPerSecond: 72, heightAboveGroundMeters: 1050, crossTrackMeters: 660, pathLengthMeters: 21000, phaseMeters: 8600),
        FlightSeed(id: "DEMO08", callsign: "KLM18Z", trackDegrees: 14, speedMetersPerSecond: 50, heightAboveGroundMeters: 540, crossTrackMeters: -380, pathLengthMeters: 15000, phaseMeters: 7050),
        FlightSeed(id: "DEMO09", callsign: "EDW350", trackDegrees: 286, speedMetersPerSecond: 44, heightAboveGroundMeters: 420, crossTrackMeters: 90, pathLengthMeters: 13000, phaseMeters: 5580),
        FlightSeed(id: "DEMO10", callsign: "UAL89", trackDegrees: 42, speedMetersPerSecond: 78, heightAboveGroundMeters: 1180, crossTrackMeters: -760, pathLengthMeters: 22000, phaseMeters: 13400)
    ]
}

private struct FlightSeed {
    let id: String
    let callsign: String
    let trackDegrees: Double
    let speedMetersPerSecond: Double
    let heightAboveGroundMeters: Double
    let crossTrackMeters: Double
    let pathLengthMeters: Double
    let phaseMeters: Double
}
