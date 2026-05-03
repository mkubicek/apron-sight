import Foundation
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    @State private var immersiveSpaceIsOpen = false
    @State private var statusMessage = "Immersive demo space closed"

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 20) {
                Text("apron-sight")
                    .font(.largeTitle.weight(.semibold))

                Text(model.target.callsign)
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Button {
                    Task {
                        await toggleImmersiveSpace()
                    }
                } label: {
                    Label(
                        immersiveSpaceIsOpen ? "Close Demo Space" : "Open Demo Space",
                        systemImage: immersiveSpaceIsOpen ? "xmark.circle" : "viewfinder.circle"
                    )
                }

                Button {
                    model.resetAircraftPositions()
                } label: {
                    Label("Reset Aircraft", systemImage: "arrow.counterclockwise.circle")
                }

                Text(statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 280, alignment: .leading)

            DebugPanel(model: model)
                .frame(maxWidth: 430)
        }
        .padding(32)
        .frame(minWidth: 760, minHeight: 560)
        .task {
            model.startSimulation()
            await openImmersiveSpaceIfNeeded()
        }
        .onDisappear {
            model.stopSimulation()
        }
    }

    private func toggleImmersiveSpace() async {
        if immersiveSpaceIsOpen {
            await dismissImmersiveSpace()
            immersiveSpaceIsOpen = false
            statusMessage = "Immersive demo space closed"
        } else {
            await openImmersiveSpaceIfNeeded()
        }
    }

    private func openImmersiveSpaceIfNeeded() async {
        guard !immersiveSpaceIsOpen else {
            return
        }

        let result = await openImmersiveSpace(id: "HomeDemoImmersiveSpace")
        switch result {
        case .opened:
            immersiveSpaceIsOpen = true
            statusMessage = "Immersive demo space open"
        case .userCancelled:
            statusMessage = "Immersive demo space cancelled"
        case .error:
            statusMessage = "Unable to open immersive demo space"
        @unknown default:
            statusMessage = "Unknown immersive space result"
        }
    }
}

private struct DebugPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Debug")
                    .font(.title2.weight(.semibold))

                VStack(alignment: .leading, spacing: 12) {
                    CoordinateField(title: "Observer lat", value: $model.observerLatitude, fractionDigits: 6)
                    CoordinateField(title: "Observer lon", value: $model.observerLongitude, fractionDigits: 6)
                    CoordinateField(title: "Observer alt", value: $model.observerAltitude, fractionDigits: 1)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    DebugRow(title: "Target lat", value: model.targetCoordinate.latitudeDegrees, suffix: "deg", fractionDigits: 6)
                    DebugRow(title: "Target lon", value: model.targetCoordinate.longitudeDegrees, suffix: "deg", fractionDigits: 6)
                    DebugRow(title: "Target alt", value: model.targetCoordinate.altitudeMeters, suffix: "m", fractionDigits: 1)
                    DebugRow(title: "Observer ground", value: model.observerGroundElevationMeters, suffix: "m", fractionDigits: 1)
                    DebugRow(title: "Observer eye alt", value: model.observerAltitude, suffix: "m", fractionDigits: 1)
                    DebugRow(title: "Target ground", value: model.targetGroundElevationMeters, suffix: "m", fractionDigits: 1)
                    DebugRow(title: "Aircraft ground", value: model.aircraftGroundElevationMeters, suffix: "m", fractionDigits: 1)
                    DebugRow(title: "Horizontal", value: model.placement.horizontalDistanceMeters, suffix: "m", fractionDigits: 1)
                    DebugRow(title: "Distance", value: model.placement.slantDistanceMeters, suffix: "m", fractionDigits: 1)
                    DebugRow(title: "Bearing", value: model.placement.bearingDegrees, suffix: "deg", fractionDigits: 1)
                    DebugRow(title: "Elevation", value: model.placement.elevationDegrees, suffix: "deg", fractionDigits: 1)
                    DebugRow(title: "Relative bearing", value: model.relativeBearingDegrees, suffix: "deg", fractionDigits: 1)
                    DebugRow(title: "Aircraft yaw", value: model.aircraftRealityYawDegrees, suffix: "deg", fractionDigits: 1)
                    DebugRow(title: "Tuned distance", value: model.tunedDistanceMeters, suffix: "m", fractionDigits: 1)
                    DebugRow(title: "Aircraft length", value: model.aircraftLengthMeters, suffix: "m", fractionDigits: 1)
                    DebugRow(title: "Visual length", value: model.estimatedAircraftAngularLengthDegrees, suffix: "deg", fractionDigits: 1)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Ground calibration")
                        .font(.headline)
                    CoordinateField(title: "Eye height", value: $model.observerHeightAboveGroundMeters, fractionDigits: 1)
                    TuningSlider(title: "Ground level", value: $model.groundCalibrationOffsetMeters, range: -20 ... 20, step: 0.1)
                    DebugRow(title: "Manual ground", value: model.observerGroundElevationMeters, suffix: "m", fractionDigits: 1)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Selected aircraft")
                            .font(.headline)
                        Spacer()
                        if model.selectedAircraftID != nil {
                            Button {
                                model.clearSelectedAircraft()
                            } label: {
                                Label("Clear", systemImage: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    if let status = model.selectedAircraftStatus {
                        Text(status.aircraft.callsign)
                            .font(.title3.weight(.semibold))
                        DebugRow(title: "Distance", value: status.relativeDistanceMeters, suffix: "m", fractionDigits: 1)
                        DebugRow(title: "Height AGL", value: status.heightAboveGroundMeters, suffix: "m", fractionDigits: 1)
                        DebugRow(title: "Ground speed", value: status.groundSpeedMetersPerSecond, suffix: "m/s", fractionDigits: 1)
                        DebugRow(title: "Ground speed", value: status.groundSpeedMetersPerSecond * 3.6, suffix: "km/h", fractionDigits: 0)
                    } else {
                        Text("Look at an aircraft and tap to select it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                CompassCalibrationView(model: model)

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Ground cursor")
                            .font(.headline)
                        Spacer()
                        Button {
                            model.resetGroundCursor()
                        } label: {
                            Label("Reset", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.borderless)
                    }

                    Toggle("Show cursor", isOn: $model.showGroundCursor)
                    TuningSlider(title: "Left / Right", value: $model.groundCursorRightOffsetMeters, range: -500 ... 500, step: 0.1)
                    TuningSlider(title: "Back / Forward", value: $model.groundCursorForwardOffsetMeters, range: -500 ... 500, step: 0.1)
                    DebugRow(title: "Cursor distance", value: model.groundCursorDistanceMeters, suffix: "m", fractionDigits: 1)
                    DebugRow(title: "Cursor bearing", value: model.groundCursorWorldBearingDegrees, suffix: "deg", fractionDigits: 1)
                    DebugRow(title: "Cursor ground", value: model.groundCursorCoordinate.altitudeMeters, suffix: "m", fractionDigits: 1)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Reference overlay")
                        .font(.headline)

                    Toggle("Compass spokes", isOn: $model.showCompassOverlay)
                    Toggle("Distance rings", isOn: $model.showDistanceOverlay)
                    Toggle("Aircraft projection", isOn: $model.showProjectionShadow)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Geo target tuning")
                            .font(.headline)
                        Spacer()
                        Button {
                            model.resetTargetTuning()
                        } label: {
                            Label("Reset", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.borderless)
                    }

                    TuningSlider(title: "East", value: $model.targetEastOffsetMeters, range: -500 ... 500, step: 0.1)
                    TuningSlider(title: "North", value: $model.targetNorthOffsetMeters, range: -500 ... 500, step: 0.1)
                    TuningSlider(title: "Altitude", value: $model.targetAltitudeOffsetMeters, range: -500 ... 500, step: 0.1)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Local aircraft tuning")
                        .font(.headline)

                    TuningSlider(title: "Left / Right", value: $model.localRightOffsetMeters, range: -500 ... 500, step: 0.1)
                    TuningSlider(title: "Back / Forward", value: $model.localForwardOffsetMeters, range: -500 ... 500, step: 0.1)
                    AngleSlider(title: "Yaw offset", value: $model.aircraftYawOffsetDegrees, range: -180 ... 180, step: 0.1)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Aircraft size")
                            .font(.headline)
                        Spacer()
                        Button {
                            model.useDemoMarkerSize()
                        } label: {
                            Label("Marker", systemImage: "smallcircle.filled.circle")
                        }
                        .buttonStyle(.borderless)

                        Button {
                            model.useRealA350Size()
                        } label: {
                            Label("Real", systemImage: "airplane")
                        }
                        .buttonStyle(.borderless)
                    }

                    TuningSlider(title: "Length", value: $model.aircraftLengthMeters, range: 2 ... 80, step: 0.1)
                    DebugRow(title: "A350-900 reference", value: AppModel.a350900LengthMeters, suffix: "m", fractionDigits: 1)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(model.calibrationStatus)
                        Spacer()
                        Text("\(model.yawOffsetDegrees, format: .number.precision(.fractionLength(0))) deg")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Slider(value: $model.yawOffsetDegrees, in: 0 ... 359, step: 1)
                }
            }
        }
        .padding(20)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct CompassCalibrationView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Compass calibration")
                    .font(.headline)

                Spacer()

                Button {
                    model.alignTargetStraightAhead()
                } label: {
                    Label("Target Ahead", systemImage: "scope")
                }
                .buttonStyle(.borderless)
            }

            CompassDial(
                yawOffsetDegrees: model.yawOffsetDegrees,
                targetBearingDegrees: model.placement.bearingDegrees
            )
            .frame(height: 180)

            VStack(alignment: .leading, spacing: 8) {
                DebugRow(title: "Forward bearing", value: model.yawOffsetDegrees, suffix: "deg", fractionDigits: 0)
                DebugRow(title: "Target bearing", value: model.placement.bearingDegrees, suffix: "deg", fractionDigits: 1)
                DebugRow(title: "Relative target", value: model.relativeBearingDegrees, suffix: "deg", fractionDigits: 1)
            }
        }
    }
}

private struct CompassDial: View {
    let yawOffsetDegrees: Double
    let targetBearingDegrees: Double

    private let cardinalBearings: [(label: String, bearing: Double)] = [
        ("N", 0),
        ("E", 90),
        ("S", 180),
        ("W", 270)
    ]

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let radius = size * 0.42
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)

            ZStack {
                Circle()
                    .stroke(.secondary.opacity(0.45), lineWidth: 1)
                    .frame(width: radius * 2, height: radius * 2)
                    .position(center)

                Rectangle()
                    .fill(.primary.opacity(0.7))
                    .frame(width: 2, height: radius)
                    .position(x: center.x, y: center.y - radius / 2)

                Text("Forward")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .position(x: center.x, y: center.y - radius - 12)

                ForEach(cardinalBearings, id: \.label) { item in
                    let position = point(for: item.bearing, radius: radius, center: center)
                    Text(item.label)
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(item.label == "N" ? .red : .primary)
                        .position(position)
                }

                let targetPosition = point(for: targetBearingDegrees, radius: radius * 0.78, center: center)
                Image(systemName: "airplane")
                    .foregroundStyle(.yellow)
                    .font(.title3)
                    .position(targetPosition)

                Circle()
                    .fill(.primary)
                    .frame(width: 6, height: 6)
                    .position(center)
            }
        }
    }

    private func point(for bearingDegrees: Double, radius: CGFloat, center: CGPoint) -> CGPoint {
        let relative = GeoMath.degreesToRadians(GeoMath.normalizedDegrees(bearingDegrees - yawOffsetDegrees))
        return CGPoint(
            x: center.x + sin(relative) * radius,
            y: center.y - cos(relative) * radius
        )
    }
}

private struct TuningSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value, format: .number.precision(.fractionLength(1))) m")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Slider(value: clampedBinding, in: range, step: step)

            NudgeControls(
                value: $value,
                range: range,
                amounts: [-10, -1, -0.1, 0.1, 1, 10]
            )
        }
    }

    private var clampedBinding: Binding<Double> {
        Binding(
            get: { value },
            set: { value = clamped($0) }
        )
    }

    private func clamped(_ newValue: Double) -> Double {
        min(max(newValue, range.lowerBound), range.upperBound)
    }
}

private struct AngleSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value, format: .number.precision(.fractionLength(1))) deg")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Slider(value: clampedBinding, in: range, step: step)

            NudgeControls(
                value: $value,
                range: range,
                amounts: [-10, -1, -0.1, 0.1, 1, 10]
            )
        }
    }

    private var clampedBinding: Binding<Double> {
        Binding(
            get: { value },
            set: { value = clamped($0) }
        )
    }

    private func clamped(_ newValue: Double) -> Double {
        min(max(newValue, range.lowerBound), range.upperBound)
    }
}

private struct NudgeControls: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let amounts: [Double]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(amounts, id: \.self) { amount in
                Button {
                    value = clamped(value + amount)
                } label: {
                    Text(label(for: amount))
                        .font(.caption.monospacedDigit())
                        .frame(minWidth: 38)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func clamped(_ newValue: Double) -> Double {
        min(max(newValue, range.lowerBound), range.upperBound)
    }

    private func label(for amount: Double) -> String {
        let format = abs(amount) < 1 ? "%+.1f" : "%+.0f"
        return String(format: format, amount)
    }
}

private struct CoordinateField: View {
    let title: String
    @Binding var value: Double
    let fractionDigits: Int

    var body: some View {
        HStack {
            Text(title)
                .frame(width: 100, alignment: .leading)

            TextField(
                title,
                value: $value,
                format: .number.precision(.fractionLength(fractionDigits))
            )
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
        }
    }
}

private struct DebugRow: View {
    let title: String
    let value: Double
    let suffix: String
    let fractionDigits: Int

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(value, format: .number.precision(.fractionLength(fractionDigits))) \(suffix)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
