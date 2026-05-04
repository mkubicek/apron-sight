import CoreLocation
import Foundation
import simd
import SwiftUI

/// Which axis of compass calibration is currently armed. The same gaze
/// pinch is consumed differently depending on this value.
enum CalibrationAxis: Equatable {
    case yaw
    case altitude
}

/// Current GPS provider state. `lastLocationError` carries the message for
/// the error path; this enum just describes whether we have a fix or are
/// still waiting. Orthogonal to the error state so a stale `.fixed` can
/// coexist with a transient error string.
enum GPSStatus: Equatable {
    /// Not using the GPS preset.
    case idle
    /// GPS preset selected, awaiting first valid fix.
    case locating
    /// At least one valid fix received since the preset was activated.
    case fixed
}

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
    case gps
    case home
    case zrhObservationDeck
    case zrhCenter
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .gps:
            return "GPS"
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
        case .gps:
            return .gps
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
        case .gps:
            return .gps
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
    @Published var yawOffsetDegrees: Double {
        didSet { persistYawIfNeeded() }
    }
    @Published var targetEastOffsetMeters: Double
    @Published var targetNorthOffsetMeters: Double
    @Published var targetAltitudeOffsetMeters: Double
    @Published var localRightOffsetMeters: Double
    @Published var localForwardOffsetMeters: Double
    @Published var aircraftYawOffsetDegrees: Double
    @Published var aircraftLengthMeters: Double
    @Published var verticalCalibrationOffsetMeters: Double {
        didSet { persistVerticalCalibrationIfNeeded() }
    }
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
    @Published var lastLocationError: String?
    @Published private(set) var gpsStatus: GPSStatus = .idle
    /// When non-nil, the next gaze pinch in the immersive scene is consumed
    /// as a calibration sample for the named axis (yaw or altitude) against
    /// the currently selected aircraft. Nil = normal selection behavior.
    @Published var armedCalibrationAxis: CalibrationAxis?
    @Published private(set) var aircraft: [Aircraft]

    private let aircraftProvider: LiveAircraftProvider
    private let gpsProvider = GPSLocationProvider()
    private var flightUpdateTask: Task<Void, Never>?
    private var calibrationDisarmTask: Task<Void, Never>?
    private var gpsTimeoutTask: Task<Void, Never>?
    private var isApplyingPreset = false
    private var isApplyingGPSUpdate = false

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
        verticalCalibrationOffsetMeters: Double = 0,
        showGroundCursor: Bool = true,
        groundCursorRightOffsetMeters: Double = 0,
        groundCursorForwardOffsetMeters: Double = 25,
        showCompassOverlay: Bool = true,
        showDistanceOverlay: Bool = true,
        showProjectionShadow: Bool = true,
        selectedAircraftID: String? = nil,
        flightDataSource: FlightDataSource = .live,
        locationPresetOption: LocationPresetOption = .gps,
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
        self.verticalCalibrationOffsetMeters = verticalCalibrationOffsetMeters
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

        // Restore the last calibrated yaw and vertical offset for the
        // current preset, if any. Swift does not fire property observers
        // during a class's own initializer, so the persistence `didSet`
        // won't run from these assignments.
        let initialPreset = locationPresetOption.preset(currentObserver: observer)
        if let key = initialPreset.calibrationStorageKey,
           UserDefaults.standard.object(forKey: key) != nil {
            self.yawOffsetDegrees = UserDefaults.standard.double(forKey: key)
        }
        if let verticalKey = initialPreset.verticalCalibrationStorageKey,
           UserDefaults.standard.object(forKey: verticalKey) != nil {
            self.verticalCalibrationOffsetMeters = UserDefaults.standard.double(forKey: verticalKey)
        }

        // Start GPS updates if the initial preset is `.gps`. Permission
        // prompt fires here on first run.
        updateGPSStatus()
    }

    var observer: GeoCoordinate {
        GeoCoordinate(
            latitudeDegrees: observerLatitude,
            longitudeDegrees: observerLongitude,
            altitudeMeters: observerAltitude
        )
    }

    var observerGroundElevationMeters: Double {
        observerAltitude - observerHeightAboveGroundMeters + verticalCalibrationOffsetMeters
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
        // Vertical calibration applies to aircraft AND ground equally, so the
        // aircraft-to-ground geometry stays constant. `observerGroundElevationMeters`
        // already includes this offset on the ground side.
        position.y += Float(verticalCalibrationOffsetMeters)
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

    /// Arms compass calibration on the named axis. The next gaze pinch in
    /// the immersive scene is consumed by `completeCalibration(...)`,
    /// which uses the selected aircraft's known WGS84 position as the
    /// reference. Auto-disarms after 30 seconds so a stale arming can't
    /// hijack a much later pinch. Defensive no-op when no aircraft is
    /// selected — the UI button gate prevents this in normal use, this is
    /// belt-and-suspenders for direct API callers.
    func armCalibration(_ axis: CalibrationAxis) {
        guard selectedAircraft != nil else { return }
        calibrationDisarmTask?.cancel()
        armedCalibrationAxis = axis
        calibrationDisarmTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.disarmCalibration()
        }
    }

    func disarmCalibration() {
        calibrationDisarmTask?.cancel()
        calibrationDisarmTask = nil
        armedCalibrationAxis = nil
    }

    /// Consumes a gaze pinch as a calibration sample for the currently
    /// armed axis. Called from `ImmersiveView` whenever
    /// `armedCalibrationAxis` is non-nil. Both axes use the selected
    /// aircraft's known world bearing/altitude as the reference target
    /// the user pinched at.
    @MainActor
    func completeCalibration(tapPosition: SIMD3<Float>, userPosition: SIMD3<Float>) {
        guard let axis = armedCalibrationAxis,
              let selected = selectedAircraft else {
            disarmCalibration()
            return
        }

        let placement = placement(for: selected)
        let gazeX = Double(tapPosition.x - userPosition.x)
        let gazeY = Double(tapPosition.y - userPosition.y)
        let gazeZ = Double(tapPosition.z - userPosition.z)
        let gazeHorizontal = sqrt(gazeX * gazeX + gazeZ * gazeZ)

        guard gazeHorizontal > 0.1 else {
            // Pinch was almost straight up or down — calibration math
            // becomes singular for near-vertical gaze. Bail without
            // changing yaw or altitude; let the user retry.
            disarmCalibration()
            return
        }

        switch axis {
        case .yaw:
            let gazeBearing = GeoMath.sceneBearingDegrees(from: userPosition, to: tapPosition)
            yawOffsetDegrees = CompassCalibration.yaw(
                forAircraftBearingDegrees: placement.bearingDegrees,
                gazeBearingDegrees: gazeBearing
            )

        case .altitude:
            // Move the entire vertical scene (aircraft AND ground) so the
            // selected aircraft sits at the gaze elevation. Pure formula
            // lives in `CompassCalibration.altitudeOffset(...)` so it can
            // be tested without the renderer.
            verticalCalibrationOffsetMeters = CompassCalibration.altitudeOffset(
                aircraftYWithoutCalibration: placement.enu.up,
                horizontalDistanceMeters: placement.horizontalDistanceMeters,
                userY: Double(userPosition.y),
                gazeY: gazeY,
                gazeHorizontal: gazeHorizontal
            )
        }

        disarmCalibration()
    }

    func applyPreset(_ preset: LocationPreset) {
        isApplyingPreset = true
        let coordinate = preset.coordinate
        observerLatitude = coordinate.latitudeDegrees
        observerLongitude = coordinate.longitudeDegrees
        observerAltitude = coordinate.altitudeMeters
        verticalCalibrationOffsetMeters = 0
        locationPresetOption = LocationPresetOption.option(for: preset)

        // If this preset has saved calibration values, restore them.
        // Custom presets have no keys and keep whatever yaw / altitude
        // the user had — they can recalibrate manually after moving.
        if let key = preset.calibrationStorageKey,
           UserDefaults.standard.object(forKey: key) != nil {
            yawOffsetDegrees = UserDefaults.standard.double(forKey: key)
        }
        if let verticalKey = preset.verticalCalibrationStorageKey,
           UserDefaults.standard.object(forKey: verticalKey) != nil {
            verticalCalibrationOffsetMeters = UserDefaults.standard.double(forKey: verticalKey)
        }

        isApplyingPreset = false
        updateGPSStatus()
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
        // GPS updates write three properties (lat, lon, alt) per fix and
        // each one fires this didSet. Skip entirely under that flag —
        // `applyGPSLocation` issues a single `reconfigureFlightProvider`
        // after all three writes settle, so we don't trigger 3× redundant
        // provider updates per fix.
        guard !isApplyingGPSUpdate else {
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

    /// Persists `yawOffsetDegrees` for the current preset, unless we're
    /// inside `applyPreset` (in which case the value we just set was loaded
    /// from disk and a re-write is wasteful) or in custom mode (no key).
    private func persistYawIfNeeded() {
        guard !isApplyingPreset else { return }
        let preset = locationPresetOption.preset(currentObserver: observer)
        guard let key = preset.calibrationStorageKey else { return }
        UserDefaults.standard.set(yawOffsetDegrees, forKey: key)
    }

    /// Persists `verticalCalibrationOffsetMeters` for the current preset,
    /// using the same `isApplyingPreset` suppression as the yaw persistence.
    private func persistVerticalCalibrationIfNeeded() {
        guard !isApplyingPreset else { return }
        let preset = locationPresetOption.preset(currentObserver: observer)
        guard let key = preset.verticalCalibrationStorageKey else { return }
        UserDefaults.standard.set(verticalCalibrationOffsetMeters, forKey: key)
    }

    /// Starts or stops the GPS provider based on the current preset. Called
    /// from `init` and after every preset change. Idempotent — multiple
    /// `start(...)` calls just rebind the callbacks. Also kicks off a
    /// 60-second "no fix yet" timeout so the user sees an explicit error
    /// instead of silently sitting on the fallback observer.
    private func updateGPSStatus() {
        gpsTimeoutTask?.cancel()
        gpsTimeoutTask = nil

        if locationPresetOption == .gps {
            gpsStatus = .locating
            lastLocationError = nil
            gpsProvider.start(
                onUpdate: { [weak self] location in
                    self?.applyGPSLocation(location)
                },
                onError: { [weak self] error in
                    self?.lastLocationError = error.localizedDescription
                }
            )
            gpsTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { return }
                if self.gpsStatus == .locating, self.lastLocationError == nil {
                    self.lastLocationError = "GPS timed out. Move outdoors or check Settings → Privacy → Location."
                }
            }
        } else {
            gpsProvider.stop()
            gpsStatus = .idle
            lastLocationError = nil
        }
    }

    /// Writes a fresh GPS coordinate into the observer fields without
    /// flipping the preset to `.custom`. The `isApplyingGPSUpdate` flag
    /// suppresses the auto-flip in `observerCoordinateDidChange`. Issues
    /// a single `reconfigureFlightProvider` after all three writes settle
    /// (the per-property didSets are skipped under the flag).
    private func applyGPSLocation(_ location: CLLocation) {
        isApplyingGPSUpdate = true
        observerLatitude = location.coordinate.latitude
        observerLongitude = location.coordinate.longitude
        observerAltitude = location.altitude
        isApplyingGPSUpdate = false

        gpsStatus = .fixed
        lastLocationError = nil
        gpsTimeoutTask?.cancel()
        gpsTimeoutTask = nil
        reconfigureFlightProvider()
    }
}
