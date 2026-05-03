import Combine
import RealityKit
import SwiftUI
import UIKit

/// Tracks the last text rendered into a text-bearing `ModelEntity` so the
/// per-frame renderer can skip the (expensive) `MeshResource.generateText`
/// call when nothing changed. Without this, regenerating compass + status
/// text every frame dominates frame time.
struct TextMeshCacheComponent: Component {
    var lastText: String = ""
}

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
    weak var groundCursor: Entity?
    weak var groundCursorLine: ModelEntity?
    weak var compassOverlay: Entity?
    weak var frontCompass: Entity?
    weak var compassNeedle: Entity?
    weak var compassText: ModelEntity?
    weak var statusWindow: Entity?
    weak var statusText: ModelEntity?
    weak var statusArrow: Entity?
    weak var selectionProxyRoot: Entity?
    var aircraftEntitiesByID: [String: Entity] = [:]
    var aircraftVisualsByID: [String: Entity] = [:]
    var collisionRadiusByAircraftID: [String: Float] = [:]
    var selectionProxyByAircraftID: [String: Entity] = [:]
    var selectionProxyRadiusByAircraftID: [String: Float] = [:]
}

struct ImmersiveView: View {
    @ObservedObject var model: AppModel
    @State private var renderer = ImmersiveSceneRenderer()
    private static let farSelectionProxyDistanceMeters: Float = 18
    private static let farSelectionProxyAngularRadiusDegrees: Float = 1.6

    var body: some View {
        RealityView { content in
            let aircraftRoot = Entity()
            aircraftRoot.name = "AircraftRoot"
            content.add(aircraftRoot)
            renderer.aircraftRoot = aircraftRoot

            let selectionProxyRoot = Entity()
            selectionProxyRoot.name = "AircraftSelectionProxyRoot"
            content.add(selectionProxyRoot)
            renderer.selectionProxyRoot = selectionProxyRoot

            let detailedAircraft = Self.makeA350Marker()
            detailedAircraft.name = "DetailedAircraft"
            content.add(detailedAircraft)
            renderer.detailedAircraft = detailedAircraft

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

            let groundCursor = Self.makeGroundCursor()
            groundCursor.name = "GroundCursor"
            groundCursor.position = model.groundCursorRealityPosition
            content.add(groundCursor)
            renderer.groundCursor = groundCursor

            let groundCursorLine = Self.makeGroundCursorLine()
            groundCursorLine.name = "GroundCursorLine"
            content.add(groundCursorLine)
            renderer.groundCursorLine = groundCursorLine

            let compassOverlay = Self.makeCompassOverlay()
            compassOverlay.name = "CompassOverlay"
            content.add(compassOverlay)
            renderer.compassOverlay = compassOverlay

            let frontCompass = Self.makeFrontCompassOverlay()
            frontCompass.name = "FrontCompassOverlay"
            content.add(frontCompass)
            renderer.frontCompass = frontCompass
            renderer.compassNeedle = frontCompass.findEntity(named: "FrontCompassNeedle")
            renderer.compassText = frontCompass.findEntity(named: "FrontCompassText") as? ModelEntity

            let statusWindow = Self.makeAircraftStatusWindow()
            statusWindow.name = "AircraftStatusWindow"
            statusWindow.isEnabled = false
            content.add(statusWindow)
            renderer.statusWindow = statusWindow
            renderer.statusText = statusWindow.findEntity(named: "AircraftStatusText") as? ModelEntity
            renderer.statusArrow = statusWindow.findEntity(named: "AircraftStatusArrow")

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
                    if let id = Self.aircraftID(from: value.entity) {
                        model.selectAircraft(id: id)
                    }
                }
        )
    }

    @MainActor
    private static func renderScene(model: AppModel, renderer: ImmersiveSceneRenderer) {
        let aircraftList = model.currentAircraft()
        let referenceAircraft = aircraftList.first(where: { $0.id == model.selectedAircraftID })
            ?? aircraftList.first
            ?? DemoScenario.homeDemoAircraft
        let referencePosition = model.realityPosition(for: referenceAircraft)
        let referenceOrientation = simd_quatf(
            angle: Float(GeoMath.degreesToRadians(model.aircraftRealityYawDegrees(for: referenceAircraft))),
            axis: SIMD3<Float>(0, 1, 0)
        )

        if let aircraftRoot = renderer.aircraftRoot {
            syncAircraftEntities(
                in: aircraftRoot,
                renderer: renderer,
                aircraftList: aircraftList,
                model: model
            )
        }

        if let selectionProxyRoot = renderer.selectionProxyRoot {
            syncSelectionProxyEntities(
                in: selectionProxyRoot,
                renderer: renderer,
                aircraftList: aircraftList,
                model: model
            )
        }

        if let detailedAircraft = renderer.detailedAircraft {
            detailedAircraft.position = referencePosition
            detailedAircraft.orientation = referenceOrientation
            detailedAircraft.scale = model.aircraftScale
            detailedAircraft.isEnabled = true
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

        if let groundCursor = renderer.groundCursor {
            groundCursor.position = model.groundCursorRealityPosition
            groundCursor.isEnabled = model.showGroundCursor
        }

        if let groundCursorLine = renderer.groundCursorLine {
            updateLine(
                groundCursorLine,
                from: model.observerGroundRealityPosition,
                to: model.groundCursorRealityPosition
            )
            groundCursorLine.isEnabled = model.showGroundCursor
        }

        if let compassOverlay = renderer.compassOverlay {
            compassOverlay.orientation = simd_quatf(
                angle: Float(GeoMath.degreesToRadians(model.yawOffsetDegrees)),
                axis: SIMD3<Float>(0, 1, 0)
            )
            compassOverlay.isEnabled = model.showCompassOverlay
        }

        if let frontCompass = renderer.frontCompass {
            frontCompass.isEnabled = model.showCompassOverlay
        }
        if let needle = renderer.compassNeedle {
            needle.orientation = simd_quatf(
                angle: Float(GeoMath.degreesToRadians(model.relativeBearingDegrees)),
                axis: SIMD3<Float>(0, 0, 1)
            )
        }
        if let compassText = renderer.compassText {
            updateCachedText(
                on: compassText,
                to: makeFrontCompassText(model: model),
                font: .monospacedSystemFont(ofSize: 0.7, weight: .regular)
            )
        }

        if let statusWindow = renderer.statusWindow,
           let statusText = renderer.statusText {
            updateAircraftStatusWindow(
                window: statusWindow,
                textEntity: statusText,
                arrowEntity: renderer.statusArrow,
                model: model,
                aircraftList: aircraftList
            )
        }
    }

    private static func makeSelectableAircraftEntity(id: String) -> Entity {
        let root = Entity()
        root.name = "Aircraft:\(id)"
        root.components.set(InputTargetComponent())
        // Real radius is set per-frame from `selectionRadiusMeters(for:)`.
        // Seed with a small placeholder so the component exists.
        root.components.set(CollisionComponent(shapes: [.generateSphere(radius: 60)]))

        let visual = makeLightweightAircraftMarker()
        visual.name = "AircraftVisual"
        root.addChild(visual)

        return root
    }

    private static func makeSelectionProxyEntity(id: String) -> Entity {
        let root = Entity()
        root.name = "AircraftProxy:\(id)"
        root.components.set(InputTargetComponent())
        root.components.set(CollisionComponent(shapes: [.generateSphere(radius: 0.5)]))
        return root
    }

    private static func syncAircraftEntities(
        in root: Entity,
        renderer: ImmersiveSceneRenderer,
        aircraftList: [Aircraft],
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

            entity.position = model.realityPosition(for: aircraft)
            entity.orientation = simd_quatf(
                angle: Float(GeoMath.degreesToRadians(model.aircraftRealityYawDegrees(for: aircraft))),
                axis: SIMD3<Float>(0, 1, 0)
            )

            let radius = Float(model.selectionRadiusMeters(for: aircraft))
            if shouldUpdateCollisionRadius(
                cached: renderer.collisionRadiusByAircraftID[aircraft.id],
                next: radius
            ) {
                entity.components.set(CollisionComponent(shapes: [.generateSphere(radius: radius)]))
                renderer.collisionRadiusByAircraftID[aircraft.id] = radius
            }

            if let visual = renderer.aircraftVisualsByID[aircraft.id] {
                visual.scale = model.markerVisualScale(for: aircraft)
                visual.isEnabled = true
            }
        }

        let staleAircraftIDs = Set(renderer.aircraftEntitiesByID.keys).subtracting(activeAircraftIDs)
        for aircraftID in staleAircraftIDs {
            renderer.aircraftEntitiesByID[aircraftID]?.removeFromParent()
            renderer.aircraftEntitiesByID[aircraftID] = nil
            renderer.aircraftVisualsByID[aircraftID] = nil
            renderer.collisionRadiusByAircraftID[aircraftID] = nil
        }
    }

    private static func syncSelectionProxyEntities(
        in root: Entity,
        renderer: ImmersiveSceneRenderer,
        aircraftList: [Aircraft],
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

            let aircraftPosition = model.realityPosition(for: aircraft)
            let distance = simd_length(aircraftPosition)
            guard distance > 0.001 else {
                proxy.isEnabled = false
                continue
            }

            let proxyDistance = min(distance, Self.farSelectionProxyDistanceMeters)
            let radius = max(
                Float(0.28),
                proxyDistance * Float(tan(GeoMath.degreesToRadians(Double(Self.farSelectionProxyAngularRadiusDegrees))))
            )
            proxy.position = simd_normalize(aircraftPosition) * proxyDistance
            if shouldUpdateCollisionRadius(
                cached: renderer.selectionProxyRadiusByAircraftID[aircraft.id],
                next: radius
            ) {
                proxy.components.set(CollisionComponent(shapes: [.generateSphere(radius: radius)]))
                renderer.selectionProxyRadiusByAircraftID[aircraft.id] = radius
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

    @MainActor
    private static func updateCachedText(
        on entity: ModelEntity,
        to text: String,
        font: UIFont,
        extrusionDepth: Float = 0.01,
        alignment: CTTextAlignment = .left
    ) {
        if entity.components[TextMeshCacheComponent.self]?.lastText == text {
            return
        }
        entity.model?.mesh = MeshResource.generateText(
            text,
            extrusionDepth: extrusionDepth,
            font: font,
            containerFrame: .zero,
            alignment: alignment,
            lineBreakMode: .byClipping
        )
        entity.components.set(TextMeshCacheComponent(lastText: text))
    }

    private static func aircraftID(from entity: Entity) -> String? {
        if entity.name.hasPrefix("Aircraft:") {
            return String(entity.name.dropFirst("Aircraft:".count))
        }

        if entity.name.hasPrefix("AircraftProxy:") {
            return String(entity.name.dropFirst("AircraftProxy:".count))
        }

        return entity.parent.flatMap { aircraftID(from: $0) }
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

    private static func makeGroundCursor() -> Entity {
        let root = Entity()
        let cursorMaterial = SimpleMaterial(color: UIColor.systemGreen.withAlphaComponent(0.72), isMetallic: false)
        let centerMaterial = SimpleMaterial(color: UIColor.white.withAlphaComponent(0.9), isMetallic: false)

        let ring = makeRing(radius: 2.1, material: cursorMaterial)
        ring.position = SIMD3<Float>(0, 0.08, 0)

        let crossA = makeHorizontalLine(
            from: SIMD3<Float>(-3, 0.08, 0),
            to: SIMD3<Float>(3, 0.08, 0),
            thickness: 0.09,
            material: cursorMaterial
        )
        let crossB = makeHorizontalLine(
            from: SIMD3<Float>(0, 0.08, -3),
            to: SIMD3<Float>(0, 0.08, 3),
            thickness: 0.09,
            material: cursorMaterial
        )
        let center = ModelEntity(mesh: .generateSphere(radius: 0.22), materials: [centerMaterial])
        center.position = SIMD3<Float>(0, 0.35, 0)

        root.addChild(ring)
        root.addChild(crossA)
        root.addChild(crossB)
        root.addChild(center)
        return root
    }

    private static func makeGroundCursorLine() -> ModelEntity {
        let material = SimpleMaterial(color: UIColor.systemGreen.withAlphaComponent(0.42), isMetallic: false)
        return ModelEntity(mesh: .generateBox(size: 1), materials: [material])
    }

    private static func makeAircraftStatusWindow() -> Entity {
        let root = Entity()
        let panelMaterial = SimpleMaterial(color: UIColor.black.withAlphaComponent(0.62), isMetallic: false)
        let accentMaterial = SimpleMaterial(color: UIColor.systemYellow.withAlphaComponent(0.9), isMetallic: false)
        let textMaterial = SimpleMaterial(color: UIColor.white, isMetallic: false)

        let panel = ModelEntity(mesh: .generateBox(size: 1), materials: [panelMaterial])
        panel.scale = SIMD3<Float>(1.24, 0.86, 0.025)
        panel.position = SIMD3<Float>(0, 0, 0.02)
        root.addChild(panel)

        let accent = ModelEntity(mesh: .generateBox(size: 1), materials: [accentMaterial])
        accent.scale = SIMD3<Float>(1.24, 0.035, 0.035)
        accent.position = SIMD3<Float>(0, 0.41, -0.03)
        root.addChild(accent)

        let arrow = ModelEntity(mesh: .generateBox(size: 1), materials: [accentMaterial])
        arrow.name = "AircraftStatusArrow"
        arrow.scale = SIMD3<Float>(0.035, 0.16, 0.02)
        arrow.position = SIMD3<Float>(0, 0.48, -0.05)
        root.addChild(arrow)

        let textMesh = MeshResource.generateText(
            "NO AIRCRAFT",
            extrusionDepth: 0.006,
            font: .monospacedSystemFont(ofSize: 0.42, weight: .semibold),
            containerFrame: .zero,
            alignment: .left,
            lineBreakMode: .byClipping
        )
        let text = ModelEntity(mesh: textMesh, materials: [textMaterial])
        text.name = "AircraftStatusText"
        text.position = SIMD3<Float>(-0.55, 0.22, -0.05)
        text.scale = SIMD3<Float>(0.078, 0.078, 0.078)
        text.components.set(TextMeshCacheComponent(lastText: "NO AIRCRAFT"))
        root.addChild(text)

        return root
    }

    @MainActor
    private static func updateAircraftStatusWindow(
        window: Entity,
        textEntity: ModelEntity,
        arrowEntity: Entity?,
        model: AppModel,
        aircraftList: [Aircraft]
    ) {
        guard
            let selectedID = model.selectedAircraftID,
            let aircraft = aircraftList.first(where: { $0.id == selectedID })
        else {
            window.isEnabled = false
            return
        }

        let status = model.status(for: aircraft)

        window.isEnabled = true
        window.position = SIMD3<Float>(1.4, 1.45, -1.8)
        window.scale = SIMD3<Float>(repeating: 1)
        window.orientation = simd_quatf()

        arrowEntity?.orientation = simd_quatf(
            angle: -Float(GeoMath.degreesToRadians(status.relativeBearingDegrees)),
            axis: SIMD3<Float>(0, 0, 1)
        )

        updateCachedText(
            on: textEntity,
            to: aircraftStatusText(status),
            font: .monospacedSystemFont(ofSize: 0.42, weight: .semibold),
            extrusionDepth: 0.006
        )
    }

    private static func aircraftStatusText(_ status: AircraftStatus) -> String {
        let origin = status.originCountry ?? "--"
        let verticalRate = status.verticalRateMetersPerSecond ?? 0
        return """
        \(status.aircraft.callsign)
        DIST \(Int(status.relativeDistanceMeters.rounded())) m
        BRG  \(Int(status.bearingDegrees.rounded()))  REL \(Int(status.relativeBearingDegrees.rounded()))
        ELEV \(Int(status.elevationDegrees.rounded())) deg
        AGL  \(Int(status.heightAboveGroundMeters.rounded())) m
        GS   \(Int((status.groundSpeedMetersPerSecond * 3.6).rounded())) km/h
        VS   \(Int(verticalRate.rounded())) m/s
        ORG  \(origin)
        """
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

    private static func makeFrontCompassOverlay() -> Entity {
        let root = Entity()
        root.position = SIMD3<Float>(0, 1.55, -1.6)

        let panelMaterial = SimpleMaterial(color: UIColor.black.withAlphaComponent(0.42), isMetallic: false)
        let lineMaterial = SimpleMaterial(color: UIColor.white.withAlphaComponent(0.8), isMetallic: false)
        let targetMaterial = SimpleMaterial(color: UIColor.systemYellow, isMetallic: false)
        let textMaterial = SimpleMaterial(color: UIColor.white, isMetallic: false)

        let panel = ModelEntity(mesh: .generateBox(size: 1), materials: [panelMaterial])
        panel.scale = SIMD3<Float>(1.55, 0.72, 0.02)
        panel.position = SIMD3<Float>(0, 0, 0.02)
        root.addChild(panel)

        let center = ModelEntity(mesh: .generateSphere(radius: 0.035), materials: [lineMaterial])
        center.position = SIMD3<Float>(0, 0, -0.04)
        root.addChild(center)

        let forward = ModelEntity(mesh: .generateBox(size: 1), materials: [lineMaterial])
        forward.scale = SIMD3<Float>(0.035, 0.32, 0.02)
        forward.position = SIMD3<Float>(0, 0.16, -0.04)
        root.addChild(forward)

        let needle = ModelEntity(mesh: .generateBox(size: 1), materials: [targetMaterial])
        needle.name = "FrontCompassNeedle"
        needle.scale = SIMD3<Float>(0.045, 0.46, 0.025)
        needle.position = SIMD3<Float>(0, 0, -0.06)
        root.addChild(needle)

        root.addChild(makePanelText("FORWARD", position: SIMD3<Float>(-0.64, 0.26, -0.06), material: textMaterial, scale: 0.18))
        let initialCompassText = "YAW 0  TGT 0  REL 0"
        let dynamicMesh = MeshResource.generateText(
            initialCompassText,
            extrusionDepth: 0.01,
            font: .monospacedSystemFont(ofSize: 0.7, weight: .regular),
            containerFrame: .zero,
            alignment: .left,
            lineBreakMode: .byClipping
        )
        let dynamicText = ModelEntity(mesh: dynamicMesh, materials: [textMaterial])
        dynamicText.name = "FrontCompassText"
        dynamicText.position = SIMD3<Float>(-0.66, -0.27, -0.06)
        dynamicText.scale = SIMD3<Float>(0.16, 0.16, 0.16)
        dynamicText.components.set(TextMeshCacheComponent(lastText: initialCompassText))
        root.addChild(dynamicText)

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

    private static func makePanelText(_ text: String, position: SIMD3<Float>, material: SimpleMaterial, scale: Float) -> ModelEntity {
        let entity = makeTextLabel(text, position: position, material: material, scale: scale)
        return entity
    }

    private static func makeFrontCompassText(model: AppModel) -> String {
        let yaw = Int(model.yawOffsetDegrees.rounded())
        let target = Int(model.placement.bearingDegrees.rounded())
        let relative = Int(model.relativeBearingDegrees.rounded())
        return "YAW \(yaw)  TGT \(target)  REL \(relative)"
    }
}
