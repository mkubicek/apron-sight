import Foundation
import simd
import SwiftUI

struct AircraftStatus {
    let aircraft: Aircraft
    let relativeDistanceMeters: Double
    let heightAboveGroundMeters: Double
    let groundSpeedMetersPerSecond: Double
    let bearingDegrees: Double
    let relativeBearingDegrees: Double
    let elevationDegrees: Double
    let originCountry: String?
    let verticalRateMetersPerSecond: Double?
}

enum LocationPresetOption: String, CaseIterable, Identifiable {
    case home
    case zrhObservationDeck
    case zrhCenter
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .home:
            return "Home"
        case .zrhObservationDeck:
            return "ZRH deck"
        case .zrhCenter:
            return "ZRH center"
        case .custom:
            return "Custom"
        }
    }

    func preset(currentObserver: GeoCoordinate) -> LocationPreset {
        switch self {
        case .home:
            return .home
        case .zrhObservationDeck:
            return .zrhObservationDeck
        case .zrhCenter:
            return .zrhCenter
        case .custom:
            return .custom(currentObserver)
        }
    }

    static func option(for preset: LocationPreset) -> Self {
        switch preset {
        case .home:
            return .home
        case .zrhObservationDeck:
            return .zrhObservationDeck
        case .zrhCenter:
            return .zrhCenter
        case .custom:
            return .custom
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let a350900LengthMeters = 66.8
    static let importedAircraftLengthMeters = 5.0
    static let demoMarkerLengthMeters = 8.0
    static let defaultObserverHeightAboveGroundMeters = 1.6
    private static let selectionAngularRadiusDegrees = 2.5
    private static let maximumSelectionRadiusMeters = 2_500.0
    private static let minimumMarkerAngularLengthDegrees = 0.9

    @Published var observerLatitude: Double {
        didSet { observerCoordinateDidChange() }
    }
    @Published var observerLongitude: Double {
        didSet { observerCoordinateDidChange() }
    }
    @Published var observerAltitude: Double {
        didSet { observerCoordinateDidChange() }
    }
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
    @Published var flightDataSource: FlightDataSource {
        didSet { reconfigureFlightProvider(force: true) }
    }
    @Published var locationPresetOption: LocationPresetOption
    @Published var lastFlightError: String?
    @Published private(set) var aircraft: [Aircraft]

    private let aircraftProvider: LiveAircraftProvider
    private var flightUpdateTask: Task<Void, Never>?
    private var isApplyingPreset = false

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
        flightDataSource: FlightDataSource = .mock,
        locationPresetOption: LocationPresetOption = .home,
        aircraftProvider: LiveAircraftProvider? = nil
    ) {
        let resolvedAircraftProvider = aircraftProvider ?? LiveAircraftProvider()

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
        self.flightDataSource = flightDataSource
        self.locationPresetOption = locationPresetOption
        self.lastFlightError = nil
        self.aircraft = []
        self.aircraftProvider = resolvedAircraftProvider
        self.aircraftProvider.errorHandler = { [weak self] message in
            guard let self, self.lastFlightError != message else {
                return
            }

            self.lastFlightError = message
        }
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

    var primaryAircraft: Aircraft {
        selectedAircraft ?? aircraft.first ?? DemoScenario.homeDemoAircraft
    }

    var target: Aircraft {
        primaryAircraft
    }

    var placement: GeoPlacement {
        placement(for: primaryAircraft)
    }

    var targetLocalCoordinate: LocalCoordinate {
        GeoMath.localCoordinate(for: placement, yawOffsetDegrees: yawOffsetDegrees)
    }

    var geospatialRealityPosition: SIMD3<Float> {
        realityPosition(for: primaryAircraft, includingTuning: false)
    }

    var localPlacementOffset: SIMD3<Float> {
        SIMD3<Float>(
            Float(localRightOffsetMeters),
            0,
            Float(-localForwardOffsetMeters)
        )
    }

    var targetRealityPosition: SIMD3<Float> {
        realityPosition(for: primaryAircraft)
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
        scale(forAircraftLengthMeters: aircraftLengthMeters)
    }

    var aircraftRealityYawDegrees: Double {
        aircraftRealityYawDegrees(for: primaryAircraft)
    }

    var tunedDistanceMeters: Double {
        relativeDistanceMeters(for: primaryAircraft)
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
        relativeBearingDegrees(for: primaryAircraft)
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
        displayCoordinate(for: primaryAircraft)
    }

    var calibrationStatus: String {
        yawOffsetDegrees == 0 ? "Manual yaw: 0 deg" : "Manual yaw set"
    }

    var flightSnapshotAgeSeconds: TimeInterval? {
        aircraftProvider.snapshotAgeSeconds()
    }

    func displayCoordinate(for aircraft: Aircraft) -> GeoCoordinate {
        guard aircraft.id == selectedAircraftID else {
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
        if includingTuning && aircraft.id == selectedAircraftID {
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
        let placement = placement(for: aircraft)
        return AircraftStatus(
            aircraft: aircraft,
            relativeDistanceMeters: relativeDistanceMeters(for: aircraft),
            heightAboveGroundMeters: heightAboveGroundMeters(for: aircraft),
            groundSpeedMetersPerSecond: aircraft.velocityMetersPerSecond ?? 0,
            bearingDegrees: placement.bearingDegrees,
            relativeBearingDegrees: relativeBearingDegrees(for: aircraft),
            elevationDegrees: placement.elevationDegrees,
            originCountry: aircraft.originCountry,
            verticalRateMetersPerSecond: aircraft.verticalRateMetersPerSecond
        )
    }

    func selectionRadiusMeters(for aircraft: Aircraft) -> Double {
        // Far targets need enough angular area to gaze-select. Overlapping
        // spheres are resolved by the renderer's angular tap tiebreaker.
        let distance = relativeDistanceMeters(for: aircraft)
        let angularRadius = distance * tan(GeoMath.degreesToRadians(Self.selectionAngularRadiusDegrees))
        return min(max(angularRadius, aircraftLengthMeters * 0.45, 24), Self.maximumSelectionRadiusMeters)
    }

    func markerVisualScale(for aircraft: Aircraft) -> SIMD3<Float> {
        let distance = max(relativeDistanceMeters(for: aircraft), 1)
        let minimumAngularLengthRadians = GeoMath.degreesToRadians(Self.minimumMarkerAngularLengthDegrees)
        let minimumVisibleLength = 2 * distance * tan(minimumAngularLengthRadians / 2)
        return scale(forAircraftLengthMeters: max(aircraftLengthMeters, minimumVisibleLength))
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

    func applyPreset(_ preset: LocationPreset) {
        isApplyingPreset = true
        let coordinate = preset.coordinate
        observerLatitude = coordinate.latitudeDegrees
        observerLongitude = coordinate.longitudeDegrees
        observerAltitude = coordinate.altitudeMeters
        groundCalibrationOffsetMeters = 0
        locationPresetOption = LocationPresetOption.option(for: preset)
        isApplyingPreset = false
        reconfigureFlightProvider(force: true)
    }

    func applyPresetOption(_ option: LocationPresetOption) {
        applyPreset(option.preset(currentObserver: observer))
    }

    func reloadAircraft() {
        publishCurrentAircraft()
    }

    /// Aircraft positions evaluated at `date`. Pure function — does not touch
    /// `@Published` state, so the per-frame renderer can call this on every
    /// frame without invalidating SwiftUI.
    func currentAircraft(at date: Date = Date()) -> [Aircraft] {
        aircraftProvider.aircraft(at: date)
    }

    func resetAircraftPositions() {
        refreshFlights()
    }

    func refreshFlights() {
        aircraftProvider.reset(observer: observer, source: flightDataSource)
        publishCurrentAircraft()
    }

    func startSimulation() {
        guard flightUpdateTask == nil else {
            return
        }

        aircraftProvider.start(observer: observer, source: flightDataSource)
        flightUpdateTask = Task { [weak self] in
            guard let self else {
                return
            }

            await self.runFlightUpdates()
        }
    }

    func stopSimulation() {
        flightUpdateTask?.cancel()
        flightUpdateTask = nil
        aircraftProvider.stop()
    }

    /// Slow tick: keeps `@Published aircraft` fresh enough for the debug panel
    /// and selection lookup, without hammering SwiftUI invalidation. Per-frame
    /// motion is driven by `currentAircraft(at:)` from the RealityKit renderer.
    private func runFlightUpdates() async {
        while !Task.isCancelled {
            publishCurrentAircraft()
            try? await Task.sleep(for: .milliseconds(1000))
        }
    }

    private func observerCoordinateDidChange() {
        guard !isApplyingPreset else {
            return
        }

        locationPresetOption = .custom
        reconfigureFlightProvider()
    }

    private func reconfigureFlightProvider(force: Bool = false) {
        aircraftProvider.update(observer: observer, source: flightDataSource, force: force)
    }

    private func publishCurrentAircraft() {
        let current = currentAircraft()
        aircraft = current
        if let selectedAircraftID, !current.contains(where: { $0.id == selectedAircraftID }) {
            self.selectedAircraftID = nil
        }
    }

    private func scale(forAircraftLengthMeters lengthMeters: Double) -> SIMD3<Float> {
        let scale = Float(max(lengthMeters, 1) / Self.importedAircraftLengthMeters)
        return SIMD3<Float>(repeating: scale)
    }
}
