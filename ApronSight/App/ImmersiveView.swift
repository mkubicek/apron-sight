import RealityKit
import SwiftUI
import UIKit

/// Holds per-`ImmersiveView` mutable state that has to outlive the SwiftUI
/// struct: the per-frame `SceneEvents.Update` subscription token, plus
/// references to entities looked up once at scene-build time.
@MainActor
final class ImmersiveSceneRenderer {
    var subscription: EventSubscription?

    weak var aircraftRoot: Entity?
    weak var detailedAircraft: Entity?
    weak var keyLight: PointLight?
    weak var projection: Entity?
    weak var altitudeLine: ModelEntity?
    weak var distanceOverlay: Entity?
    weak var compassOverlay: Entity?
    weak var headAnchor: AnchorEntity?
    weak var selectionProxyRoot: Entity?
    weak var selectionRing: ModelEntity?
    var aircraftEntitiesByID: [String: Entity] = [:]
    var aircraftVisualsByID: [String: Entity] = [:]
    var nearbyDetailedAircraftByID: [String: Entity] = [:]
    var selectionProxyByAircraftID: [String: Entity] = [:]
    var selectionProxyRadiusByAircraftID: [String: Float] = [:]
}

struct ImmersiveView: View {
    @ObservedObject var model: AppModel
    @State private var renderer = ImmersiveSceneRenderer()
    private static let selectionProxyDistanceMeters: Float = 8
    private static let minimumSelectionProxyRadiusMeters: Float = 0.28
    private static let maximumSelectionProxyAngularRadiusDegrees = 6.0
    private static let emptySpaceTargetName = "EmptySpaceTarget"
    private static let emptySpaceShellHalfExtent: Float = 50
    /// Half-angle the selection ring subtends at the user's eye. With distance
    /// floor enforced, a far selected aircraft is always visible as a ~3°-wide
    /// blue ring even when the detailed A350 model has shrunk below visibility.
    private static let selectionRingMinAngularRadiusDegrees: Double = 1.5
    /// Multiplier on `aircraftLengthMeters` for the ring radius at close range.
    /// 0.6 means the ring is just larger than the aircraft model.
    private static let selectionRingAircraftLengthFactor: Float = 0.6
    /// Ring colour for the selection ring around the picked aircraft.
    private static let selectionRingDefaultColor = UIColor.systemYellow.withAlphaComponent(0.85)
    /// Temporary LOD experiment: render the textured aircraft for every
    /// target inside this horizontal range to measure the frame-budget cost.
    private static let nearbyDetailedAircraftHorizontalRangeMeters: Float = 1_000

    var body: some View {
        RealityView { content in
            let headAnchor = AnchorEntity(.head)
            headAnchor.name = "HeadAnchor"
            content.add(headAnchor)
            renderer.headAnchor = headAnchor

            // Catches taps that miss every selection proxy. Six head-anchored
            // walls travel with the user, so an empty-sky pinch always lands
            // here regardless of where the user has walked. Resolution to
            // "deselect" happens in the gesture handler below.
            let emptySpaceTarget = Self.makeEmptySpaceTarget()
            headAnchor.addChild(emptySpaceTarget)

            let aircraftRoot = Entity()
            aircraftRoot.name = "AircraftRoot"
            content.add(aircraftRoot)
            renderer.aircraftRoot = aircraftRoot

            let detailedAircraft = Self.makeA350Marker()
            detailedAircraft.name = "DetailedAircraft"
            content.add(detailedAircraft)
            renderer.detailedAircraft = detailedAircraft

            let selectionRing = Self.makeSelectionRing()
            selectionRing.name = "SelectionRing"
            selectionRing.isEnabled = false
            content.add(selectionRing)
            renderer.selectionRing = selectionRing

            let keyLight = Self.makeAircraftKeyLight()
            keyLight.name = "AircraftKeyLight"
            content.add(keyLight)
            renderer.keyLight = keyLight

            let projection = Self.makeProjectionMarker()
            projection.name = "AircraftProjection"
            projection.position = model.targetProjectionPosition
            projection.scale = model.aircraftScale
            content.add(projection)
            renderer.projection = projection

            let altitudeLine = Self.makeAltitudeLine()
            altitudeLine.name = "AircraftAltitudeLine"
            content.add(altitudeLine)
            renderer.altitudeLine = altitudeLine

            let distanceOverlay = Self.makeDistanceOverlay()
            distanceOverlay.name = "DistanceOverlay"
            distanceOverlay.position = model.observerGroundRealityPosition
            content.add(distanceOverlay)
            renderer.distanceOverlay = distanceOverlay

            let compassOverlay = Self.makeCompassOverlay()
            compassOverlay.name = "CompassOverlay"
            content.add(compassOverlay)
            renderer.compassOverlay = compassOverlay

            let selectionProxyRoot = Entity()
            selectionProxyRoot.name = "AircraftSelectionProxyRoot"
            content.add(selectionProxyRoot)
            renderer.selectionProxyRoot = selectionProxyRoot

            // Per-frame entity updates run here, NOT in the SwiftUI `update:`
            // closure. That way render cadence is the visionOS frame rate
            // (90 Hz), independent of how often `@Published` properties on
            // AppModel change.
            renderer.subscription = content.subscribe(to: SceneEvents.Update.self) { _ in
                MainActor.assumeIsolated {
                    Self.renderScene(model: model, renderer: renderer)
                }
            }
        }
        .gesture(
            SpatialTapGesture()
                .targetedToAnyEntity()
                .onEnded { value in
                    // Drop taps that arrive before head pose is valid: better
                    // a missed first tap than a tap routed through scene-origin
                    // math when the user is somewhere else.
                    guard let userPosition = Self.userPosition(renderer) else { return }
                    let tapPosition = value.convert(value.location3D, from: .local, to: .scene)

                    // When compass calibration is armed (yaw OR altitude),
                    // the next pinch is the user pointing at the selected
                    // aircraft in reality. Hijack before normal selection.
                    if model.armedCalibrationAxis != nil {
                        model.completeCalibration(tapPosition: tapPosition, userPosition: userPosition)
                        return
                    }

                    let aircraftList = model.currentAircraft()
                    if let id = Self.selectedAircraftID(
                        tapPosition: tapPosition,
                        userPosition: userPosition,
                        model: model,
                        aircraftList: aircraftList
                    ) {
                        model.selectAircraft(id: id)
                    } else if Self.isEmptySpaceTarget(value.entity) {
                        model.clearSelectedAircraft()
                    }
                }
        )
    }

    @MainActor
    private static func renderScene(model: AppModel, renderer: ImmersiveSceneRenderer) {
        let aircraftList = model.currentAircraft()
        // Single source of truth for aircraft world positions this frame.
        // Both the visual aircraft tree and the selection-proxy tree must use
        // the same numbers, otherwise they can disagree by one frame and
        // selection ends up referring to where the aircraft used to be.
        let aircraftPositions = Dictionary(uniqueKeysWithValues:
            aircraftList.map { ($0.id, model.realityPosition(for: $0)) }
        )
        let referenceAircraft = aircraftList.first(where: { $0.id == model.selectedAircraftID })
            ?? aircraftList.first
            ?? DemoScenario.homeDemoAircraft
        let referencePosition = aircraftPositions[referenceAircraft.id]
            ?? model.realityPosition(for: referenceAircraft)
        let referenceOrientation = Self.aircraftOrientation(for: referenceAircraft, model: model)
        let nearbyDetailedAircraftIDs = nearbyDetailedAircraftIDs(
            aircraftList: aircraftList,
            aircraftPositions: aircraftPositions
        )
        let detailedVisualAircraftIDs = nearbyDetailedAircraftIDs.union([referenceAircraft.id])

        let userPosition = Self.userPosition(renderer)

        if let aircraftRoot = renderer.aircraftRoot {
            syncAircraftEntities(
                in: aircraftRoot,
                renderer: renderer,
                aircraftList: aircraftList,
                aircraftPositions: aircraftPositions,
                nearbyDetailedAircraftIDs: nearbyDetailedAircraftIDs,
                detailedVisualAircraftIDs: detailedVisualAircraftIDs,
                model: model
            )
        }

        if let userPosition,
           let selectionProxyRoot = renderer.selectionProxyRoot {
            syncSelectionProxyEntities(
                in: selectionProxyRoot,
                renderer: renderer,
                aircraftList: aircraftList,
                aircraftPositions: aircraftPositions,
                userPosition: userPosition,
                model: model
            )
        }

        if let selectionRing = renderer.selectionRing {
            updateSelectionRing(
                ring: selectionRing,
                model: model,
                aircraftList: aircraftList,
                aircraftPositions: aircraftPositions,
                userPosition: userPosition
            )
        }

        if let detailedAircraft = renderer.detailedAircraft {
            detailedAircraft.position = referencePosition
            detailedAircraft.orientation = referenceOrientation
            detailedAircraft.scale = model.aircraftScale
            detailedAircraft.isEnabled = !nearbyDetailedAircraftIDs.contains(referenceAircraft.id)
        }

        if let keyLight = renderer.keyLight {
            let aircraftLength = Float(model.aircraftLengthMeters)
            keyLight.position = referencePosition + SIMD3<Float>(
                -0.45 * aircraftLength,
                0.35 * aircraftLength,
                -0.35 * aircraftLength
            )
            keyLight.light.intensity = max(1800, aircraftLength * 80)
            keyLight.light.attenuationRadius = max(12, aircraftLength * 2)
        }

        if let projection = renderer.projection {
            projection.position = model.groundRealityPosition(under: referencePosition)
            projection.scale = model.aircraftScale
            projection.orientation = referenceOrientation
            projection.isEnabled = model.showProjectionShadow
        }

        if let altitudeLine = renderer.altitudeLine {
            updateAltitudeLine(
                altitudeLine,
                targetPosition: referencePosition,
                groundPosition: model.groundRealityPosition(under: referencePosition)
            )
            altitudeLine.isEnabled = model.showProjectionShadow
        }

        if let distanceOverlay = renderer.distanceOverlay {
            distanceOverlay.position = model.observerGroundRealityPosition
            distanceOverlay.isEnabled = model.showDistanceOverlay
        }

        if let compassOverlay = renderer.compassOverlay {
            compassOverlay.orientation = simd_quatf(
                angle: Float(GeoMath.degreesToRadians(model.yawOffsetDegrees)),
                axis: SIMD3<Float>(0, 1, 0)
            )
            compassOverlay.isEnabled = model.showCompassOverlay
        }
    }

    private static func makeSelectableAircraftEntity(id: String) -> Entity {
        let root = Entity()
        root.name = "Aircraft:\(id)"

        let visual = makeLightweightAircraftMarker()
        visual.name = "AircraftVisual"
        root.addChild(visual)

        return root
    }

    private static func syncAircraftEntities(
        in root: Entity,
        renderer: ImmersiveSceneRenderer,
        aircraftList: [Aircraft],
        aircraftPositions: [String: SIMD3<Float>],
        nearbyDetailedAircraftIDs: Set<String>,
        detailedVisualAircraftIDs: Set<String>,
        model: AppModel
    ) {
        var activeAircraftIDs = Set<String>()

        for aircraft in aircraftList {
            activeAircraftIDs.insert(aircraft.id)
            let entity = renderer.aircraftEntitiesByID[aircraft.id] ?? {
                let newEntity = makeSelectableAircraftEntity(id: aircraft.id)
                root.addChild(newEntity)
                renderer.aircraftEntitiesByID[aircraft.id] = newEntity
                renderer.aircraftVisualsByID[aircraft.id] = newEntity.findEntity(named: "AircraftVisual")
                return newEntity
            }()

            entity.position = aircraftPositions[aircraft.id] ?? model.realityPosition(for: aircraft)
            entity.orientation = Self.aircraftOrientation(for: aircraft, model: model)

            if let visual = renderer.aircraftVisualsByID[aircraft.id] {
                visual.scale = model.markerVisualScale(for: aircraft)
                visual.isEnabled = !detailedVisualAircraftIDs.contains(aircraft.id)
            }

            if nearbyDetailedAircraftIDs.contains(aircraft.id) {
                let detailed = renderer.nearbyDetailedAircraftByID[aircraft.id] ?? {
                    let newDetailed = makeDetailedAircraftInstance(renderer: renderer)
                    newDetailed.name = "NearbyDetailedAircraft:\(aircraft.id)"
                    entity.addChild(newDetailed)
                    renderer.nearbyDetailedAircraftByID[aircraft.id] = newDetailed
                    return newDetailed
                }()
                detailed.position = .zero
                detailed.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
                detailed.scale = model.aircraftScale
                detailed.isEnabled = true
            } else if let detailed = renderer.nearbyDetailedAircraftByID[aircraft.id] {
                detailed.removeFromParent()
                renderer.nearbyDetailedAircraftByID[aircraft.id] = nil
            }
        }

        let staleAircraftIDs = Set(renderer.aircraftEntitiesByID.keys).subtracting(activeAircraftIDs)
        for aircraftID in staleAircraftIDs {
            renderer.aircraftEntitiesByID[aircraftID]?.removeFromParent()
            renderer.aircraftEntitiesByID[aircraftID] = nil
            renderer.aircraftVisualsByID[aircraftID] = nil
            renderer.nearbyDetailedAircraftByID[aircraftID] = nil
        }
    }

    private static func nearbyDetailedAircraftIDs(
        aircraftList: [Aircraft],
        aircraftPositions: [String: SIMD3<Float>]
    ) -> Set<String> {
        Set(aircraftList.compactMap { aircraft in
            guard let position = aircraftPositions[aircraft.id] else {
                return nil
            }

            let horizontalDistance = sqrt(position.x * position.x + position.z * position.z)
            return horizontalDistance <= nearbyDetailedAircraftHorizontalRangeMeters ? aircraft.id : nil
        })
    }

    private static func makeDetailedAircraftInstance(renderer: ImmersiveSceneRenderer) -> Entity {
        if let prototype = renderer.detailedAircraft?.clone(recursive: true) {
            prototype.position = .zero
            prototype.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
            prototype.scale = SIMD3<Float>(repeating: 1)
            prototype.isEnabled = true
            return prototype
        }

        return makeA350Marker()
    }

    private static func makeSelectionProxyEntity(id: String) -> Entity {
        let root = Entity()
        root.name = "AircraftSelectionProxy:\(id)"
        root.components.set(InputTargetComponent())
        root.components.set(CollisionComponent(shapes: [.generateSphere(radius: Self.minimumSelectionProxyRadiusMeters)]))
        // visionOS renders the system hover highlight while gaze is on the
        // proxy. Free pre-commit feedback so the user sees what they'll select.
        root.components.set(HoverEffectComponent())
        return root
    }

    private static func syncSelectionProxyEntities(
        in root: Entity,
        renderer: ImmersiveSceneRenderer,
        aircraftList: [Aircraft],
        aircraftPositions: [String: SIMD3<Float>],
        userPosition: SIMD3<Float>,
        model: AppModel
    ) {
        var activeAircraftIDs = Set<String>()

        for aircraft in aircraftList {
            activeAircraftIDs.insert(aircraft.id)
            let proxy = renderer.selectionProxyByAircraftID[aircraft.id] ?? {
                let newProxy = makeSelectionProxyEntity(id: aircraft.id)
                root.addChild(newProxy)
                renderer.selectionProxyByAircraftID[aircraft.id] = newProxy
                return newProxy
            }()

            let aircraftPosition = aircraftPositions[aircraft.id] ?? model.realityPosition(for: aircraft)
            let aircraftVector = aircraftPosition - userPosition
            let aircraftDistance = simd_length(aircraftVector)
            guard aircraftDistance > 0.001 else {
                proxy.isEnabled = false
                continue
            }

            let direction = simd_normalize(aircraftVector)
            proxy.position = userPosition + direction * Self.selectionProxyDistanceMeters

            let selectionAngularRadius = min(
                AngularAircraftSelector.angularRadiusRadians(
                    selectionRadiusMeters: model.selectionRadiusMeters(for: aircraft),
                    distanceMeters: Double(aircraftDistance)
                ),
                GeoMath.degreesToRadians(Self.maximumSelectionProxyAngularRadiusDegrees)
            )
            let proxyRadius = max(
                Self.minimumSelectionProxyRadiusMeters,
                Self.selectionProxyDistanceMeters * Float(tan(selectionAngularRadius))
            )
            if shouldUpdateCollisionRadius(
                cached: renderer.selectionProxyRadiusByAircraftID[aircraft.id],
                next: proxyRadius
            ) {
                proxy.components.set(CollisionComponent(shapes: [.generateSphere(radius: proxyRadius)]))
                renderer.selectionProxyRadiusByAircraftID[aircraft.id] = proxyRadius
            }
            proxy.isEnabled = true
        }

        let staleAircraftIDs = Set(renderer.selectionProxyByAircraftID.keys).subtracting(activeAircraftIDs)
        for aircraftID in staleAircraftIDs {
            renderer.selectionProxyByAircraftID[aircraftID]?.removeFromParent()
            renderer.selectionProxyByAircraftID[aircraftID] = nil
            renderer.selectionProxyRadiusByAircraftID[aircraftID] = nil
        }
    }

    private static func shouldUpdateCollisionRadius(cached: Float?, next: Float) -> Bool {
        guard let cached else {
            return true
        }

        return abs(next - cached) / max(cached, 1) >= 0.1
    }

    private static func userPosition(_ renderer: ImmersiveSceneRenderer) -> SIMD3<Float>? {
        guard let anchor = renderer.headAnchor, anchor.isAnchored else { return nil }
        return anchor.position(relativeTo: nil)
    }

    private static func selectedAircraftID(
        tapPosition: SIMD3<Float>,
        userPosition: SIMD3<Float>,
        model: AppModel,
        aircraftList: [Aircraft]
    ) -> String? {
        let candidates = aircraftList.map {
            AngularSelectionCandidate(
                id: $0.id,
                positionMeters: doubleVector(model.realityPosition(for: $0)),
                selectionRadiusMeters: model.selectionRadiusMeters(for: $0)
            )
        }

        return AngularAircraftSelector.selectedID(
            tapPositionMeters: doubleVector(tapPosition),
            userPositionMeters: doubleVector(userPosition),
            candidates: candidates
        )
    }

    private static func isEmptySpaceTarget(_ entity: Entity) -> Bool {
        entity.name == Self.emptySpaceTargetName
    }

    /// Builds a flat annulus in the X-Y plane (normal = +Z) with unit outer
    /// radius. Sized at runtime via `entity.scale`. Triangles wound CCW from
    /// +Z so the ring is front-facing toward the user once `+Z` is rotated
    /// to point at them. Uses `SimpleMaterial` to match the transparent-ring
    /// pattern already proven in `makeDistanceOverlay`.
    private static func makeSelectionRing() -> ModelEntity {
        let segmentCount = 96
        let outerRadius: Float = 1.0
        let innerRadius: Float = 0.9
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        positions.reserveCapacity((segmentCount + 1) * 2)
        indices.reserveCapacity(segmentCount * 6)

        for index in 0 ... segmentCount {
            let angle = Float(index) * 2 * .pi / Float(segmentCount)
            let direction = SIMD3<Float>(sin(angle), cos(angle), 0)
            positions.append(direction * outerRadius)
            positions.append(direction * innerRadius)
        }

        for index in 0 ..< segmentCount {
            let outerStart = UInt32(index * 2)
            let innerStart = outerStart + 1
            let outerEnd = outerStart + 2
            let innerEnd = outerStart + 3
            indices.append(contentsOf: [outerStart, innerStart, outerEnd])
            indices.append(contentsOf: [outerEnd, innerStart, innerEnd])
        }

        var descriptor = MeshDescriptor()
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)
        let mesh = (try? MeshResource.generate(from: [descriptor])) ?? .generateBox(size: 1)

        let material = SimpleMaterial(color: Self.selectionRingDefaultColor, isMetallic: false)
        return ModelEntity(mesh: mesh, materials: [material])
    }

    /// Position, size, and orient the selection ring around the selected
    /// aircraft. Hidden when nothing is selected, when the selected aircraft
    /// has dropped out of the live feed, or before head pose is available.
    @MainActor
    private static func updateSelectionRing(
        ring: ModelEntity,
        model: AppModel,
        aircraftList: [Aircraft],
        aircraftPositions: [String: SIMD3<Float>],
        userPosition: SIMD3<Float>?
    ) {
        guard let selectedID = model.selectedAircraftID,
              aircraftList.contains(where: { $0.id == selectedID }),
              let userPosition,
              let aircraftPosition = aircraftPositions[selectedID]
        else {
            ring.isEnabled = false
            return
        }

        let toUser = userPosition - aircraftPosition
        let distance = simd_length(toUser)
        guard distance > 0.001 else {
            ring.isEnabled = false
            return
        }

        let minAngularRadius = Float(GeoMath.degreesToRadians(Self.selectionRingMinAngularRadiusDegrees))
        let minRadius = distance * tan(minAngularRadius)
        let aircraftLengthRadius = Float(model.aircraftLengthMeters) * Self.selectionRingAircraftLengthFactor
        let radius = max(aircraftLengthRadius, minRadius)

        ring.position = aircraftPosition
        ring.scale = SIMD3<Float>(repeating: radius)
        ring.orientation = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: simd_normalize(toUser))
        ring.isEnabled = true
    }

    private static func doubleVector(_ vector: SIMD3<Float>) -> SIMD3<Double> {
        SIMD3<Double>(Double(vector.x), Double(vector.y), Double(vector.z))
    }

    /// Six head-anchored walls forming a cube around the user, sized big
    /// enough that selection proxies (at 8m) always sit between the user and
    /// the empty-space walls. visionOS picks the closest collision along the
    /// gaze ray, so a tap only reaches these walls when no proxy is in the
    /// gaze direction. Each wall carries the same name so the gesture handler
    /// can identify any of them with a single string compare — no recursive
    /// parent walk required.
    private static func makeEmptySpaceTarget() -> Entity {
        let root = Entity()
        root.name = Self.emptySpaceTargetName
        let halfExtent = Self.emptySpaceShellHalfExtent
        let span = halfExtent * 2
        let thickness: Float = 0.5

        let walls: [(position: SIMD3<Float>, size: SIMD3<Float>)] = [
            (SIMD3<Float>(0, 0, -halfExtent), SIMD3<Float>(span, span, thickness)),
            (SIMD3<Float>(0, 0, halfExtent), SIMD3<Float>(span, span, thickness)),
            (SIMD3<Float>(-halfExtent, 0, 0), SIMD3<Float>(thickness, span, span)),
            (SIMD3<Float>(halfExtent, 0, 0), SIMD3<Float>(thickness, span, span)),
            (SIMD3<Float>(0, halfExtent, 0), SIMD3<Float>(span, thickness, span)),
            (SIMD3<Float>(0, -halfExtent, 0), SIMD3<Float>(span, thickness, span))
        ]

        for wall in walls {
            let entity = Entity()
            entity.name = Self.emptySpaceTargetName
            entity.position = wall.position
            entity.components.set(InputTargetComponent())
            entity.components.set(CollisionComponent(shapes: [.generateBox(size: wall.size)]))
            root.addChild(entity)
        }

        return root
    }

    /// Composes the aircraft's RealityKit orientation as yaw (around
    /// world Y) times pitch (around local X). Pitch is applied first
    /// in the local frame so the aircraft tilts in the direction of
    /// travel rather than around a world-aligned axis. Both the
    /// lightweight marker and the wrapping root of the textured A350
    /// share this contract — the asset's internal 180° flip lives on
    /// a child entity, so the wrapper's pitch axis still points along
    /// world +X before yaw rotates it.
    @MainActor
    private static func aircraftOrientation(for aircraft: Aircraft, model: AppModel) -> simd_quatf {
        let yawRadians = Float(GeoMath.degreesToRadians(model.aircraftRealityYawDegrees(for: aircraft)))
        let pitchRadians = Float(GeoMath.degreesToRadians(model.aircraftRealityPitchDegrees(for: aircraft)))
        let yaw = simd_quatf(angle: yawRadians, axis: SIMD3<Float>(0, 1, 0))
        let pitch = simd_quatf(angle: pitchRadians, axis: SIMD3<Float>(1, 0, 0))
        return yaw * pitch
    }

    private static func makeA350Marker() -> Entity {
        if let texturedMarker = makeTexturedA350Marker() {
            return texturedMarker
        }

        return makeLightweightAircraftMarker()
    }

    private static func makeLightweightAircraftMarker() -> Entity {
        let root = Entity()
        let fuselageMaterial = SimpleMaterial(color: UIColor(white: 0.86, alpha: 0.86), isMetallic: false)
        let wingMaterial = SimpleMaterial(color: UIColor.systemCyan.withAlphaComponent(0.78), isMetallic: false)
        let noseMaterial = SimpleMaterial(color: UIColor.white.withAlphaComponent(0.92), isMetallic: false)
        let redMaterial = SimpleMaterial(color: UIColor.systemRed.withAlphaComponent(0.9), isMetallic: false)
        let greenMaterial = SimpleMaterial(color: UIColor.systemGreen.withAlphaComponent(0.9), isMetallic: false)

        let fuselage = ModelEntity(mesh: .generateBox(size: 1), materials: [fuselageMaterial])
        fuselage.scale = SIMD3<Float>(0.22, 0.18, 4.55)
        fuselage.position = SIMD3<Float>(0, 0, 0)

        let nose = ModelEntity(mesh: .generateSphere(radius: 0.18), materials: [noseMaterial])
        nose.scale = SIMD3<Float>(0.85, 0.7, 1.2)
        nose.position = SIMD3<Float>(0, 0.02, -2.36)

        let wings = ModelEntity(mesh: .generateBox(size: 1), materials: [wingMaterial])
        wings.scale = SIMD3<Float>(3.75, 0.045, 0.42)
        wings.position = SIMD3<Float>(0, -0.02, -0.16)

        let tailPlane = ModelEntity(mesh: .generateBox(size: 1), materials: [wingMaterial])
        tailPlane.scale = SIMD3<Float>(1.25, 0.04, 0.26)
        tailPlane.position = SIMD3<Float>(0, 0.08, 1.88)

        let verticalTail = ModelEntity(mesh: .generateBox(size: 1), materials: [wingMaterial])
        verticalTail.scale = SIMD3<Float>(0.08, 0.72, 0.32)
        verticalTail.position = SIMD3<Float>(0, 0.34, 1.96)

        let leftTip = ModelEntity(mesh: .generateSphere(radius: 0.07), materials: [redMaterial])
        leftTip.position = SIMD3<Float>(-1.95, 0.04, -0.18)

        let rightTip = ModelEntity(mesh: .generateSphere(radius: 0.07), materials: [greenMaterial])
        rightTip.position = SIMD3<Float>(1.95, 0.04, -0.18)

        root.addChild(fuselage)
        root.addChild(nose)
        root.addChild(wings)
        root.addChild(tailPlane)
        root.addChild(verticalTail)
        root.addChild(leftTip)
        root.addChild(rightTip)
        return root
    }

    private static func makeTexturedA350Marker() -> Entity? {
        guard let url = Bundle.main.url(forResource: "A350_Qatar_CC_BY", withExtension: "usdz"),
              let aircraft = try? Entity.load(contentsOf: url)
        else {
            return nil
        }

        let root = Entity()
        aircraft.name = "TexturedA350Asset"
        aircraft.orientation = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
        root.addChild(aircraft)
        return root
    }

    private static func makeAircraftKeyLight() -> PointLight {
        let light = PointLight()
        light.light.intensity = 1800
        light.light.attenuationRadius = 12
        light.position = SIMD3<Float>(-3.5, 4.5, -2.5)
        return light
    }

    private static func makeProjectionMarker() -> Entity {
        let root = Entity()
        let material = SimpleMaterial(color: UIColor.systemYellow.withAlphaComponent(0.45), isMetallic: false)
        let shadowMaterial = SimpleMaterial(color: UIColor.black.withAlphaComponent(0.38), isMetallic: false)

        let pad = ModelEntity(mesh: .generateCylinder(height: 0.03, radius: 1.2), materials: [material])
        pad.position = SIMD3<Float>(0, 0, 0)

        let shadowFuselage = ModelEntity(mesh: .generateBox(size: 1), materials: [shadowMaterial])
        shadowFuselage.scale = SIMD3<Float>(0.18, 0.025, 2.6)
        shadowFuselage.position = SIMD3<Float>(0, 0.045, 0)

        let shadowWing = ModelEntity(mesh: .generateBox(size: 1), materials: [shadowMaterial])
        shadowWing.scale = SIMD3<Float>(2.15, 0.025, 0.34)
        shadowWing.position = SIMD3<Float>(0, 0.055, -0.12)

        let shadowTail = ModelEntity(mesh: .generateBox(size: 1), materials: [shadowMaterial])
        shadowTail.scale = SIMD3<Float>(0.86, 0.025, 0.18)
        shadowTail.position = SIMD3<Float>(0, 0.055, 1.05)

        let crossA = makeHorizontalLine(
            from: SIMD3<Float>(-1.8, 0.03, 0),
            to: SIMD3<Float>(1.8, 0.03, 0),
            thickness: 0.05,
            material: material
        )
        let crossB = makeHorizontalLine(
            from: SIMD3<Float>(0, 0.03, -1.8),
            to: SIMD3<Float>(0, 0.03, 1.8),
            thickness: 0.05,
            material: material
        )

        root.addChild(pad)
        root.addChild(shadowFuselage)
        root.addChild(shadowWing)
        root.addChild(shadowTail)
        root.addChild(crossA)
        root.addChild(crossB)
        return root
    }

    private static func makeAltitudeLine() -> ModelEntity {
        let material = SimpleMaterial(color: UIColor.systemYellow.withAlphaComponent(0.55), isMetallic: false)
        return ModelEntity(mesh: .generateBox(size: 1), materials: [material])
    }

    private static func updateAltitudeLine(
        _ line: ModelEntity,
        targetPosition: SIMD3<Float>,
        groundPosition: SIMD3<Float>
    ) {
        let height = max(abs(targetPosition.y - groundPosition.y), 0.05)
        line.position = SIMD3<Float>(
            targetPosition.x,
            (targetPosition.y + groundPosition.y) / 2,
            targetPosition.z
        )
        line.scale = SIMD3<Float>(0.05, height, 0.05)
    }

    private static func makeDistanceOverlay() -> Entity {
        let root = Entity()
        let ringMaterial = SimpleMaterial(color: UIColor.systemCyan.withAlphaComponent(0.25), isMetallic: false)
        let axisMaterial = SimpleMaterial(color: UIColor.systemCyan.withAlphaComponent(0.35), isMetallic: false)

        for radius in [10, 25, 50, 100, 250, 500] as [Float] {
            root.addChild(makeRing(radius: radius, material: ringMaterial))
            root.addChild(makeTextLabel(
                "\(Int(radius)) m",
                position: SIMD3<Float>(max(1, radius * 0.02), max(0.55, radius * 0.012), -radius),
                material: axisMaterial,
                scale: max(0.38, radius * 0.012)
            ))
        }

        root.addChild(makeHorizontalLine(from: SIMD3<Float>(-500, 0, 0), to: SIMD3<Float>(500, 0, 0), thickness: 0.055, material: axisMaterial))
        root.addChild(makeHorizontalLine(from: SIMD3<Float>(0, 0, -500), to: SIMD3<Float>(0, 0, 500), thickness: 0.055, material: axisMaterial))

        return root
    }

    private static func makeCompassOverlay() -> Entity {
        let root = Entity()
        let northMaterial = SimpleMaterial(color: UIColor.systemRed.withAlphaComponent(0.7), isMetallic: false)
        let spokeMaterial = SimpleMaterial(color: UIColor.white.withAlphaComponent(0.35), isMetallic: false)
        let textMaterial = SimpleMaterial(color: UIColor.white.withAlphaComponent(0.85), isMetallic: false)

        let radius: Float = 62
        root.addChild(makeHorizontalLine(from: .zero, to: SIMD3<Float>(0, 0.08, -radius), thickness: 0.09, material: northMaterial))
        root.addChild(makeHorizontalLine(from: .zero, to: SIMD3<Float>(radius, 0.08, 0), thickness: 0.06, material: spokeMaterial))
        root.addChild(makeHorizontalLine(from: .zero, to: SIMD3<Float>(0, 0.08, radius), thickness: 0.06, material: spokeMaterial))
        root.addChild(makeHorizontalLine(from: .zero, to: SIMD3<Float>(-radius, 0.08, 0), thickness: 0.06, material: spokeMaterial))

        root.addChild(makeTextLabel("N", position: SIMD3<Float>(0, 1.4, -8), material: northMaterial))
        root.addChild(makeTextLabel("E", position: SIMD3<Float>(8, 1.4, 0), material: textMaterial))
        root.addChild(makeTextLabel("S", position: SIMD3<Float>(0, 1.4, 8), material: textMaterial))
        root.addChild(makeTextLabel("W", position: SIMD3<Float>(-8, 1.4, 0), material: textMaterial))

        return root
    }

    private static func makeRing(radius: Float, material: SimpleMaterial) -> ModelEntity {
        let segmentCount = 128
        let halfThickness = max(radius * 0.001, 0.0225)
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        positions.reserveCapacity((segmentCount + 1) * 2)
        indices.reserveCapacity(segmentCount * 6)

        for index in 0 ... segmentCount {
            let angle = Float(index) * 2 * .pi / Float(segmentCount)
            let direction = SIMD3<Float>(sin(angle), 0, -cos(angle))
            positions.append(direction * (radius + halfThickness))
            positions.append(direction * max(radius - halfThickness, 0.001))
        }

        for index in 0 ..< segmentCount {
            let outerStart = UInt32(index * 2)
            let innerStart = outerStart + 1
            let outerEnd = outerStart + 2
            let innerEnd = outerStart + 3
            indices.append(contentsOf: [outerStart, outerEnd, innerStart])
            indices.append(contentsOf: [innerStart, outerEnd, innerEnd])
        }

        var descriptor = MeshDescriptor()
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)
        let mesh = (try? MeshResource.generate(from: [descriptor])) ?? .generateBox(size: 1)
        return ModelEntity(mesh: mesh, materials: [material])
    }

    private static func makeHorizontalLine(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        thickness: Float,
        material: SimpleMaterial
    ) -> ModelEntity {
        let entity = ModelEntity(mesh: .generateBox(size: 1), materials: [material])
        updateLine(entity, from: start, to: end, thickness: thickness)
        return entity
    }

    private static func updateLine(
        _ entity: ModelEntity,
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        thickness: Float = 0.08
    ) {
        let delta = end - start
        let length = max(sqrt(delta.x * delta.x + delta.z * delta.z), 0.001)
        entity.position = (start + end) / 2
        entity.scale = SIMD3<Float>(thickness, thickness, length)
        entity.orientation = simd_quatf(angle: atan2(delta.x, delta.z), axis: SIMD3<Float>(0, 1, 0))
    }

    private static func makeTextLabel(
        _ text: String,
        position: SIMD3<Float>,
        material: SimpleMaterial,
        scale: Float = 0.8
    ) -> ModelEntity {
        let mesh = MeshResource.generateText(
            text,
            extrusionDepth: 0.02,
            font: .systemFont(ofSize: 1.0),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byClipping
        )
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.position = position
        entity.scale = SIMD3<Float>(scale, scale, scale)
        return entity
    }
}
