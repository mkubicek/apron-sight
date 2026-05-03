import Foundation
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    @State private var immersiveSpaceIsOpen = false
    @State private var statusMessage = "Immersive demo space closed"

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 20) {
                Text("apron-sight")
                    .font(.largeTitle.weight(.semibold))

                Text(model.primaryAircraft.callsign)
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
                    model.refreshFlights()
                } label: {
                    Label("Refresh Flights", systemImage: "arrow.counterclockwise.circle")
                }

                Text(statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                SelectedFlightPanel(model: model)
            }
            .frame(minWidth: 330, maxWidth: 360, alignment: .leading)

            DebugPanel(model: model)
                .frame(maxWidth: 430)
        }
        .padding(32)
        .frame(minWidth: 820, minHeight: 620)
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

private struct SelectedFlightPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Selected flight")
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
                AircraftPhotoView(aircraft: status.aircraft)

                Text(status.aircraft.callsign)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)

                VStack(alignment: .leading, spacing: 7) {
                    DebugRow(title: "Distance", value: status.relativeDistanceMeters, suffix: "m", fractionDigits: 0)
                    DebugRow(title: "Bearing", value: status.bearingDegrees, suffix: "deg", fractionDigits: 1)
                    DebugRow(title: "Relative bearing", value: status.relativeBearingDegrees, suffix: "deg", fractionDigits: 1)
                    DebugRow(title: "Elevation", value: status.elevationDegrees, suffix: "deg", fractionDigits: 1)
                    DebugRow(title: "Height AGL", value: status.heightAboveGroundMeters, suffix: "m", fractionDigits: 0)
                    DebugRow(title: "Ground speed", value: status.groundSpeedMetersPerSecond * 3.6, suffix: "km/h", fractionDigits: 0)
                    DebugRow(title: "Vertical rate", value: status.verticalRateMetersPerSecond ?? 0, suffix: "m/s", fractionDigits: 1)
                    TextRow(title: "Origin", value: status.originCountry ?? "--")
                    TextRow(title: "ICAO24", value: status.aircraft.id.uppercased())
                }
                .font(.caption)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "airplane.circle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)

                    Text("Look at an aircraft and tap to select it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            }
        }
        .padding(16)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct AircraftPhotoView: View {
    let aircraft: Aircraft

    @State private var photo: AircraftPhoto?
    @State private var isLoading = false
    @State private var lookupCompleted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.secondary.opacity(0.12))

                if let photo {
                    AsyncImage(url: photo.imageURL) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        case .failure:
                            unavailablePhoto
                        @unknown default:
                            unavailablePhoto
                        }
                    }
                } else if isLoading {
                    ProgressView()
                } else {
                    unavailablePhoto
                }
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            if let photo {
                let attribution = photo.photographer.map { "Photo: \($0)" } ?? "Photo: Planespotters.net"
                Group {
                    if let link = photo.link {
                        Link(destination: link) {
                            Label(attribution, systemImage: "link")
                        }
                    } else {
                        Text(attribution)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            } else if lookupCompleted {
                Text("No aircraft photo found")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: aircraft.id) {
            await loadPhoto()
        }
    }

    private var unavailablePhoto: some View {
        VStack(spacing: 6) {
            Image(systemName: "airplane")
                .font(.title2)
            Text("Aircraft photo unavailable")
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
    }

    @MainActor
    private func loadPhoto() async {
        photo = nil
        lookupCompleted = false
        guard AircraftPhotoLookup.icao24Hex(from: aircraft.id) != nil else {
            isLoading = false
            lookupCompleted = true
            return
        }

        isLoading = true
        photo = await AircraftPhotoLookup.photo(for: aircraft)
        isLoading = false
        lookupCompleted = true
    }
}

private struct AircraftPhoto: Equatable {
    let imageURL: URL
    let link: URL?
    let photographer: String?
}

private enum AircraftPhotoLookup {
    static func photo(for aircraft: Aircraft) async -> AircraftPhoto? {
        guard let hex = icao24Hex(from: aircraft.id),
              let url = URL(string: "https://api.planespotters.net/pub/photos/hex/\(hex)")
        else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("apron-sight/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  200 ..< 300 ~= httpResponse.statusCode
            else {
                return nil
            }

            let payload = try JSONDecoder().decode(PlanespottersPhotoResponse.self, from: data)
            guard let firstPhoto = payload.photos.first,
                  let imageURLString = firstPhoto.thumbnailLarge?.src ?? firstPhoto.thumbnail?.src,
                  let imageURL = URL(string: imageURLString)
            else {
                return nil
            }

            return AircraftPhoto(
                imageURL: imageURL,
                link: firstPhoto.link.flatMap(URL.init(string:)),
                photographer: firstPhoto.photographer
            )
        } catch {
            return nil
        }
    }

    static func icao24Hex(from aircraftID: String) -> String? {
        let hex = aircraftID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        guard hex.count == 6,
              hex.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else {
            return nil
        }

        return hex
    }
}

private struct PlanespottersPhotoResponse: Decodable {
    let photos: [PlanespottersPhoto]
}

private struct PlanespottersPhoto: Decodable {
    let thumbnail: PlanespottersImage?
    let thumbnailLarge: PlanespottersImage?
    let link: String?
    let photographer: String?

    enum CodingKeys: String, CodingKey {
        case thumbnail
        case thumbnailLarge = "thumbnail_large"
        case link
        case photographer
    }
}

private struct PlanespottersImage: Decodable {
    let src: String?
}

private struct DebugPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Debug")
                    .font(.title2.weight(.semibold))

                VStack(alignment: .leading, spacing: 12) {
                    Text("Location")
                        .font(.headline)

                    Picker("Preset", selection: locationPresetBinding) {
                        ForEach(LocationPresetOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    CoordinateField(title: "Observer lat", value: $model.observerLatitude, fractionDigits: 6)
                    CoordinateField(title: "Observer lon", value: $model.observerLongitude, fractionDigits: 6)
                    CoordinateField(title: "Observer alt", value: $model.observerAltitude, fractionDigits: 1)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Flight source")
                        .font(.headline)

                    Picker("Source", selection: $model.flightDataSource) {
                        ForEach(FlightDataSource.allCases) { source in
                            Text(source.title).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)

                    DebugRow(title: "Aircraft", value: Double(model.aircraft.count), suffix: "", fractionDigits: 0)
                    if let age = model.flightSnapshotAgeSeconds {
                        DebugRow(title: "Snapshot age", value: age, suffix: "s", fractionDigits: 1)
                    }
                    if let error = model.lastFlightError {
                        Text(error)
                            .font(.caption.monospaced())
                            .foregroundStyle(.red)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    DebugRow(title: "Primary lat", value: model.targetCoordinate.latitudeDegrees, suffix: "deg", fractionDigits: 6)
                    DebugRow(title: "Primary lon", value: model.targetCoordinate.longitudeDegrees, suffix: "deg", fractionDigits: 6)
                    DebugRow(title: "Primary alt", value: model.targetCoordinate.altitudeMeters, suffix: "m", fractionDigits: 1)
                    DebugRow(title: "Observer ground", value: model.observerGroundElevationMeters, suffix: "m", fractionDigits: 1)
                    DebugRow(title: "Observer eye alt", value: model.observerAltitude, suffix: "m", fractionDigits: 1)
                    DebugRow(title: "Primary ground", value: model.targetGroundElevationMeters, suffix: "m", fractionDigits: 1)
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

    private var locationPresetBinding: Binding<LocationPresetOption> {
        Binding(
            get: { model.locationPresetOption },
            set: { model.applyPresetOption($0) }
        )
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

private struct TextRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}
