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
}

struct ImmersiveView: View {
    @ObservedObject var model: AppModel
    @State private var renderer = ImmersiveSceneRenderer()

    var body: some View {
        RealityView { content in
            let aircraftRoot = Entity()
            aircraftRoot.name = "AircraftRoot"
            for aircraft in model.aircraft {
                aircraftRoot.addChild(Self.makeSelectableAircraftEntity(id: aircraft.id))
            }
            content.add(aircraftRoot)
            renderer.aircraftRoot = aircraftRoot

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
            TapGesture()
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
            ?? model.target
        let referencePosition = model.realityPosition(for: referenceAircraft)
        let referenceOrientation = simd_quatf(
            angle: Float(GeoMath.degreesToRadians(model.aircraftRealityYawDegrees(for: referenceAircraft))),
            axis: SIMD3<Float>(0, 1, 0)
        )

        if let aircraftRoot = renderer.aircraftRoot {
            syncAircraftEntities(
                in: aircraftRoot,
                aircraftList: aircraftList,
                model: model,
                detailedAircraftID: referenceAircraft.id
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
                model: model,
                referenceAircraft: referenceAircraft,
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

    private static func syncAircraftEntities(
        in root: Entity,
        aircraftList: [Aircraft],
        model: AppModel,
        detailedAircraftID: String
    ) {
        for aircraft in aircraftList {
            let entityName = "Aircraft:\(aircraft.id)"
            let entity = root.findEntity(named: entityName) ?? {
                let newEntity = makeSelectableAircraftEntity(id: aircraft.id)
                root.addChild(newEntity)
                return newEntity
            }()

            entity.position = model.realityPosition(for: aircraft)
            entity.orientation = simd_quatf(
                angle: Float(GeoMath.degreesToRadians(model.aircraftRealityYawDegrees(for: aircraft))),
                axis: SIMD3<Float>(0, 1, 0)
            )

            // Resize the tap target with distance so far aircraft remain
            // selectable. CollisionComponent's shape isn't mutable in place,
            // so we replace it. Cheap relative to per-frame text mesh gen.
            let radius = Float(model.selectionRadiusMeters(for: aircraft))
            entity.components.set(CollisionComponent(shapes: [.generateSphere(radius: radius)]))

            if let visual = entity.findEntity(named: "AircraftVisual") {
                visual.scale = model.aircraftScale
                visual.isEnabled = aircraft.id != detailedAircraftID
            }
        }
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

        return entity.parent.flatMap { aircraftID(from: $0) }
    }

    private static func makeA350Marker() -> Entity {
        if let texturedMarker = makeTexturedA350Marker() {
            return texturedMarker
        }

        return makeProceduralA350Marker()
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

    private static func makeProceduralA350Marker() -> Entity {
        let root = Entity()

        let fuselageMaterial = makePBRMaterial(color: UIColor(white: 0.96, alpha: 1), roughness: 0.22)
        let bellyMaterial = makePBRMaterial(color: UIColor(white: 0.72, alpha: 1), roughness: 0.38)
        let wingMaterial = makePBRMaterial(color: UIColor(white: 0.82, alpha: 1), roughness: 0.28)
        let metalMaterial = makePBRMaterial(color: UIColor(white: 0.68, alpha: 1), roughness: 0.18, metallic: 0.35)
        let tailMaterial = makePBRMaterial(color: UIColor(red: 0.02, green: 0.22, blue: 0.72, alpha: 1), roughness: 0.24)
        let stripeMaterial = makePBRMaterial(color: UIColor(red: 0.02, green: 0.28, blue: 0.82, alpha: 1), roughness: 0.24)
        let engineMaterial = makePBRMaterial(color: UIColor(white: 0.22, alpha: 1), roughness: 0.22, metallic: 0.2)
        let fanMaterial = makePBRMaterial(color: UIColor(white: 0.04, alpha: 1), roughness: 0.18, metallic: 0.55)
        let windowMaterial = makePBRMaterial(color: UIColor(white: 0.015, alpha: 1), roughness: 0.08, metallic: 0.05)
        let doorMaterial = makePBRMaterial(color: UIColor(white: 0.08, alpha: 1), roughness: 0.18)
        let gearMaterial = makePBRMaterial(color: UIColor(white: 0.54, alpha: 1), roughness: 0.24, metallic: 0.45)
        let tireMaterial = makePBRMaterial(color: UIColor(white: 0.015, alpha: 1), roughness: 0.62)
        let redLightMaterial = SimpleMaterial(color: UIColor.systemRed, isMetallic: false)
        let greenLightMaterial = SimpleMaterial(color: UIColor.systemGreen, isMetallic: false)
        let whiteLightMaterial = SimpleMaterial(color: UIColor.white, isMetallic: false)

        let fuselage = ModelEntity(mesh: makeA350FuselageMesh(), materials: [fuselageMaterial])

        let bellyStripe = ModelEntity(mesh: .generateBox(size: 1), materials: [bellyMaterial])
        bellyStripe.scale = SIMD3<Float>(0.22, 0.035, 3.8)
        bellyStripe.position = SIMD3<Float>(0, -0.24, 0.05)

        let cockpit = ModelEntity(mesh: .generateBox(size: 1), materials: [windowMaterial])
        cockpit.scale = SIMD3<Float>(0.38, 0.035, 0.2)
        cockpit.position = SIMD3<Float>(0, 0.235, -2.34)
        cockpit.orientation = simd_quatf(angle: -0.18, axis: SIMD3<Float>(1, 0, 0))

        let leftWindows = makeWindowStrip(x: -0.285, material: windowMaterial)
        let rightWindows = makeWindowStrip(x: 0.285, material: windowMaterial)
        let leftDoors = makeDoorSet(side: -1, material: doorMaterial)
        let rightDoors = makeDoorSet(side: 1, material: doorMaterial)
        let leftStripe = makeLiveryStripe(side: -1, material: stripeMaterial)
        let rightStripe = makeLiveryStripe(side: 1, material: stripeMaterial)

        let leftWing = makeSweptWing(side: -1, wingMaterial: wingMaterial, metalMaterial: metalMaterial, lightMaterial: redLightMaterial)
        let rightWing = makeSweptWing(side: 1, wingMaterial: wingMaterial, metalMaterial: metalMaterial, lightMaterial: greenLightMaterial)
        let leftEngine = makeEngine(side: -1, nacelleMaterial: engineMaterial, fanMaterial: fanMaterial, metalMaterial: metalMaterial)
        let rightEngine = makeEngine(side: 1, nacelleMaterial: engineMaterial, fanMaterial: fanMaterial, metalMaterial: metalMaterial)

        let verticalTail = ModelEntity(mesh: .generateBox(size: 1), materials: [tailMaterial])
        verticalTail.scale = SIMD3<Float>(0.14, 1.05, 0.7)
        verticalTail.position = SIMD3<Float>(0, 0.47, 1.95)
        verticalTail.orientation = simd_quatf(angle: -0.25, axis: SIMD3<Float>(1, 0, 0))

        let tailLogo = makePanelText("A350", position: SIMD3<Float>(-0.08, 0.8, 1.62), material: SimpleMaterial(color: .white, isMetallic: false), scale: 0.16)
        tailLogo.orientation = simd_quatf(angle: -0.18, axis: SIMD3<Float>(0, 1, 0))

        let leftStabilizer = makeHorizontalStabilizer(side: -1, material: wingMaterial)
        let rightStabilizer = makeHorizontalStabilizer(side: 1, material: wingMaterial)
        let landingGear = makeLandingGear(strutMaterial: gearMaterial, tireMaterial: tireMaterial)

        let tailLight = ModelEntity(mesh: .generateSphere(radius: 0.035), materials: [whiteLightMaterial])
        tailLight.position = SIMD3<Float>(0, 0.02, 2.78)
        let topBeacon = ModelEntity(mesh: .generateSphere(radius: 0.035), materials: [redLightMaterial])
        topBeacon.position = SIMD3<Float>(0, 0.31, -0.05)
        let bellyBeacon = ModelEntity(mesh: .generateSphere(radius: 0.03), materials: [redLightMaterial])
        bellyBeacon.position = SIMD3<Float>(0, -0.32, -0.12)

        root.addChild(fuselage)
        root.addChild(bellyStripe)
        root.addChild(cockpit)
        root.addChild(leftWindows)
        root.addChild(rightWindows)
        root.addChild(leftDoors)
        root.addChild(rightDoors)
        root.addChild(leftStripe)
        root.addChild(rightStripe)
        root.addChild(leftWing)
        root.addChild(rightWing)
        root.addChild(leftEngine)
        root.addChild(rightEngine)
        root.addChild(verticalTail)
        root.addChild(tailLogo)
        root.addChild(leftStabilizer)
        root.addChild(rightStabilizer)
        root.addChild(landingGear)
        root.addChild(tailLight)
        root.addChild(topBeacon)
        root.addChild(bellyBeacon)

        root.addChild(makePanelText("AIRBUS  A350", position: SIMD3<Float>(-0.31, 0.02, -0.72), material: SimpleMaterial(color: UIColor(white: 0.08, alpha: 1), isMetallic: false), scale: 0.13))

        return root
    }

    private static func makeA350FuselageMesh() -> MeshResource {
        let ringCount = 44
        let segmentCount = 40
        let length: Float = 5.35
        let maxRadius: Float = 0.29
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        for ring in 0 ... ringCount {
            let progress = Float(ring) / Float(ringCount)
            let z = -length / 2 + progress * length
            let profile = fuselageProfile(z: z, halfLength: length / 2)
            let radiusX = maxRadius * profile
            let radiusY = maxRadius * 0.88 * profile

            for segment in 0 ..< segmentCount {
                let angle = Float(segment) * 2 * .pi / Float(segmentCount)
                positions.append(SIMD3<Float>(
                    cos(angle) * radiusX,
                    sin(angle) * radiusY,
                    z
                ))
            }
        }

        for ring in 0 ..< ringCount {
            for segment in 0 ..< segmentCount {
                let current = UInt32(ring * segmentCount + segment)
                let next = UInt32(ring * segmentCount + (segment + 1) % segmentCount)
                let above = UInt32((ring + 1) * segmentCount + segment)
                let aboveNext = UInt32((ring + 1) * segmentCount + (segment + 1) % segmentCount)

                indices.append(contentsOf: [current, above, next])
                indices.append(contentsOf: [next, above, aboveNext])
            }
        }

        var descriptor = MeshDescriptor()
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)
        return try! MeshResource.generate(from: [descriptor])
    }

    private static func fuselageProfile(z: Float, halfLength: Float) -> Float {
        if z < -2.18 {
            let t = max(0.12, min(1, (z + halfLength) / (halfLength - 2.18)))
            return 0.18 + 0.82 * sin(t * .pi / 2)
        }

        if z > 2.05 {
            let t = max(0, min(1, (halfLength - z) / (halfLength - 2.05)))
            return 0.22 + 0.78 * sin(t * .pi / 2)
        }

        return 1
    }

    private static func makePBRMaterial(color: UIColor, roughness: Float, metallic: Float = 0) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.roughness = .init(floatLiteral: roughness)
        material.metallic = .init(floatLiteral: metallic)
        return material
    }

    private static func makeWindowStrip(x: Float, material: PhysicallyBasedMaterial) -> Entity {
        let root = Entity()
        for index in 0 ..< 22 {
            let window = ModelEntity(mesh: .generateBox(size: 1), materials: [material])
            window.scale = SIMD3<Float>(0.016, 0.034, 0.052)
            window.position = SIMD3<Float>(x, 0.185, -1.76 + Float(index) * 0.16)
            root.addChild(window)
        }
        return root
    }

    private static func makeDoorSet(side: Float, material: PhysicallyBasedMaterial) -> Entity {
        let root = Entity()
        for z in [-2.02, -0.42, 1.42] as [Float] {
            let door = ModelEntity(mesh: .generateBox(size: 1), materials: [material])
            door.scale = SIMD3<Float>(0.014, 0.2, 0.08)
            door.position = SIMD3<Float>(side * 0.302, 0.01, z)
            root.addChild(door)
        }
        return root
    }

    private static func makeLiveryStripe(side: Float, material: PhysicallyBasedMaterial) -> Entity {
        let root = Entity()
        let stripe = ModelEntity(mesh: .generateBox(size: 1), materials: [material])
        stripe.scale = SIMD3<Float>(0.018, 0.052, 2.7)
        stripe.position = SIMD3<Float>(side * 0.305, -0.045, -0.2)
        root.addChild(stripe)

        let noseCurve = ModelEntity(mesh: .generateBox(size: 1), materials: [material])
        noseCurve.scale = SIMD3<Float>(0.018, 0.045, 0.62)
        noseCurve.position = SIMD3<Float>(side * 0.292, -0.015, -1.85)
        noseCurve.orientation = simd_quatf(angle: side * 0.18, axis: SIMD3<Float>(0, 1, 0))
        root.addChild(noseCurve)

        return root
    }

    private static func makeSweptWing(
        side: Float,
        wingMaterial: PhysicallyBasedMaterial,
        metalMaterial: PhysicallyBasedMaterial,
        lightMaterial: SimpleMaterial
    ) -> Entity {
        let root = Entity()

        let main = ModelEntity(mesh: .generateBox(size: 1), materials: [wingMaterial])
        main.scale = SIMD3<Float>(1.8, 0.045, 0.36)
        main.position = SIMD3<Float>(side * 1.02, -0.03, -0.16)
        main.orientation = simd_quatf(angle: side * -0.24, axis: SIMD3<Float>(0, 1, 0))

        let outer = ModelEntity(mesh: .generateBox(size: 1), materials: [wingMaterial])
        outer.scale = SIMD3<Float>(0.9, 0.035, 0.22)
        outer.position = SIMD3<Float>(side * 1.92, -0.015, -0.36)
        outer.orientation = simd_quatf(angle: side * -0.32, axis: SIMD3<Float>(0, 1, 0))

        let flapLine = ModelEntity(mesh: .generateBox(size: 1), materials: [metalMaterial])
        flapLine.scale = SIMD3<Float>(1.55, 0.012, 0.025)
        flapLine.position = SIMD3<Float>(side * 1.04, -0.002, 0.06)
        flapLine.orientation = main.orientation

        let tip = ModelEntity(mesh: .generateBox(size: 1), materials: [wingMaterial])
        tip.scale = SIMD3<Float>(0.08, 0.46, 0.16)
        tip.position = SIMD3<Float>(side * 2.23, 0.2, -0.38)
        tip.orientation = simd_quatf(angle: side * -0.35, axis: SIMD3<Float>(0, 0, 1))

        let navLight = ModelEntity(mesh: .generateSphere(radius: 0.045), materials: [lightMaterial])
        navLight.position = SIMD3<Float>(side * 2.34, 0.22, -0.38)

        root.addChild(main)
        root.addChild(outer)
        root.addChild(flapLine)
        root.addChild(tip)
        root.addChild(navLight)
        return root
    }

    private static func makeHorizontalStabilizer(side: Float, material: PhysicallyBasedMaterial) -> ModelEntity {
        let stabilizer = ModelEntity(mesh: .generateBox(size: 1), materials: [material])
        stabilizer.scale = SIMD3<Float>(0.75, 0.045, 0.18)
        stabilizer.position = SIMD3<Float>(side * 0.52, 0.2, 2.12)
        stabilizer.orientation = simd_quatf(angle: side * -0.18, axis: SIMD3<Float>(0, 1, 0))
        return stabilizer
    }

    private static func makeEngine(
        side: Float,
        nacelleMaterial: PhysicallyBasedMaterial,
        fanMaterial: PhysicallyBasedMaterial,
        metalMaterial: PhysicallyBasedMaterial
    ) -> Entity {
        let root = Entity()
        let nacelle = ModelEntity(mesh: .generateCylinder(height: 0.46, radius: 0.19), materials: [nacelleMaterial])
        nacelle.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        nacelle.position = SIMD3<Float>(side * 1.16, -0.34, -0.38)

        let fan = ModelEntity(mesh: .generateCylinder(height: 0.02, radius: 0.145), materials: [fanMaterial])
        fan.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        fan.position = SIMD3<Float>(side * 1.16, -0.34, -0.62)

        for bladeIndex in 0 ..< 10 {
            let blade = ModelEntity(mesh: .generateBox(size: 1), materials: [metalMaterial])
            blade.scale = SIMD3<Float>(0.012, 0.006, 0.12)
            blade.position = SIMD3<Float>(side * 1.16, -0.34, -0.64)
            blade.orientation = simd_quatf(angle: Float(bladeIndex) * 2 * .pi / 10, axis: SIMD3<Float>(0, 0, 1))
            root.addChild(blade)
        }

        root.addChild(nacelle)
        root.addChild(fan)
        return root
    }

    private static func makeLandingGear(strutMaterial: PhysicallyBasedMaterial, tireMaterial: PhysicallyBasedMaterial) -> Entity {
        let root = Entity()

        root.addChild(makeGearLeg(position: SIMD3<Float>(0, -0.47, -1.65), height: 0.38, material: strutMaterial))
        root.addChild(makeWheel(position: SIMD3<Float>(-0.08, -0.68, -1.65), material: tireMaterial))
        root.addChild(makeWheel(position: SIMD3<Float>(0.08, -0.68, -1.65), material: tireMaterial))

        for side in [-1, 1] as [Float] {
            root.addChild(makeGearLeg(position: SIMD3<Float>(side * 0.42, -0.5, 0.42), height: 0.42, material: strutMaterial))
            root.addChild(makeWheel(position: SIMD3<Float>(side * 0.34, -0.72, 0.36), material: tireMaterial))
            root.addChild(makeWheel(position: SIMD3<Float>(side * 0.5, -0.72, 0.36), material: tireMaterial))
            root.addChild(makeWheel(position: SIMD3<Float>(side * 0.34, -0.72, 0.55), material: tireMaterial))
            root.addChild(makeWheel(position: SIMD3<Float>(side * 0.5, -0.72, 0.55), material: tireMaterial))
        }

        return root
    }

    private static func makeGearLeg(position: SIMD3<Float>, height: Float, material: PhysicallyBasedMaterial) -> ModelEntity {
        let leg = ModelEntity(mesh: .generateBox(size: 1), materials: [material])
        leg.scale = SIMD3<Float>(0.035, height, 0.035)
        leg.position = position
        return leg
    }

    private static func makeWheel(position: SIMD3<Float>, material: PhysicallyBasedMaterial) -> ModelEntity {
        let wheel = ModelEntity(mesh: .generateCylinder(height: 0.07, radius: 0.085), materials: [material])
        wheel.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
        wheel.position = position
        return wheel
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
        panel.scale = SIMD3<Float>(5.4, 2.7, 0.06)
        panel.position = SIMD3<Float>(0, 0, 0.03)
        root.addChild(panel)

        let accent = ModelEntity(mesh: .generateBox(size: 1), materials: [accentMaterial])
        accent.scale = SIMD3<Float>(5.4, 0.08, 0.08)
        accent.position = SIMD3<Float>(0, 1.28, -0.04)
        root.addChild(accent)

        let textMesh = MeshResource.generateText(
            "NO AIRCRAFT",
            extrusionDepth: 0.015,
            font: .monospacedSystemFont(ofSize: 0.72, weight: .semibold),
            containerFrame: .zero,
            alignment: .left,
            lineBreakMode: .byClipping
        )
        let text = ModelEntity(mesh: textMesh, materials: [textMaterial])
        text.name = "AircraftStatusText"
        text.position = SIMD3<Float>(-2.45, 0.65, -0.08)
        text.scale = SIMD3<Float>(0.24, 0.24, 0.24)
        text.components.set(TextMeshCacheComponent(lastText: "NO AIRCRAFT"))
        root.addChild(text)

        return root
    }

    @MainActor
    private static func updateAircraftStatusWindow(
        window: Entity,
        textEntity: ModelEntity,
        model: AppModel,
        referenceAircraft: Aircraft,
        aircraftList: [Aircraft]
    ) {
        guard
            let selectedID = model.selectedAircraftID,
            let aircraft = aircraftList.first(where: { $0.id == selectedID })
        else {
            window.isEnabled = false
            return
        }

        let status = AircraftStatus(
            aircraft: aircraft,
            relativeDistanceMeters: model.relativeDistanceMeters(for: aircraft),
            heightAboveGroundMeters: model.heightAboveGroundMeters(for: aircraft),
            groundSpeedMetersPerSecond: aircraft.velocityMetersPerSecond ?? 0
        )
        _ = referenceAircraft  // reserved for future hover/interaction state

        window.isEnabled = true
        window.position = model.statusWindowPosition(for: status.aircraft)
        window.scale = model.statusWindowScale(for: status.aircraft)
        window.orientation = statusWindowOrientation(for: window.position)

        updateCachedText(
            on: textEntity,
            to: aircraftStatusText(status),
            font: .monospacedSystemFont(ofSize: 0.72, weight: .semibold),
            extrusionDepth: 0.015
        )
    }

    private static func statusWindowOrientation(for position: SIMD3<Float>) -> simd_quatf {
        simd_quatf(
            angle: atan2(-position.x, -position.z),
            axis: SIMD3<Float>(0, 1, 0)
        )
    }

    private static func aircraftStatusText(_ status: AircraftStatus) -> String {
        """
        \(status.aircraft.callsign)
        DIST \(Int(status.relativeDistanceMeters.rounded())) m
        AGL  \(Int(status.heightAboveGroundMeters.rounded())) m
        GS   \(Int((status.groundSpeedMetersPerSecond * 3.6).rounded())) km/h
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

    private static func makeRing(radius: Float, material: SimpleMaterial) -> Entity {
        let root = Entity()
        let segmentCount = 96

        for index in 0 ..< segmentCount {
            let startAngle = Float(index) * 2 * .pi / Float(segmentCount)
            let endAngle = Float(index + 1) * 2 * .pi / Float(segmentCount)
            let start = SIMD3<Float>(sin(startAngle) * radius, 0, -cos(startAngle) * radius)
            let end = SIMD3<Float>(sin(endAngle) * radius, 0, -cos(endAngle) * radius)
            root.addChild(makeHorizontalLine(from: start, to: end, thickness: 0.045, material: material))
        }

        return root
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
