import FlightFeed
import Foundation
import MapKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    @State private var immersiveSpaceIsOpen = false
    @State private var immersiveSpaceError: String?

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("apron-sight")
                        .font(.largeTitle.weight(.semibold))

                    HStack(spacing: 10) {
                        Button {
                            Task { await toggleImmersiveSpace() }
                        } label: {
                            Label(
                                immersiveSpaceIsOpen ? "Close" : "Open",
                                systemImage: immersiveSpaceIsOpen ? "xmark.circle" : "viewfinder.circle"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            model.refreshFlights()
                        } label: {
                            Label("Refresh", systemImage: "arrow.counterclockwise.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    if let error = immersiveSpaceError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    SelectedFlightPanel(model: model)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 320, idealWidth: 380, maxWidth: 460, alignment: .leading)

            DebugPanel(model: model)
                .frame(maxWidth: .infinity)
        }
        .padding(32)
        .frame(minWidth: 980, minHeight: 720)
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
            immersiveSpaceError = nil
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
            immersiveSpaceError = nil
        case .userCancelled:
            immersiveSpaceError = "Immersive space dismissed."
        case .error:
            immersiveSpaceError = "Unable to open immersive space."
        @unknown default:
            immersiveSpaceError = "Unknown immersive space error."
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

                FlightRouteView(callsign: status.aircraft.callsign, icao24: status.aircraft.id)

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
            .frame(height: 200)
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

/// Shows the origin and destination airport for the selected flight.
/// adsbdb resolves the *current scheduled* route by callsign for most
/// numeric airline callsigns; OpenSky's flight history covers
/// suffix-letter callsigns that adsbdb misses by returning the
/// aircraft's previous completed flight (labelled "Last flight"). When
/// neither resolves, the row simply doesn't render.
private struct FlightRouteView: View {
    let callsign: String
    let icao24: String

    @State private var route: FlightRoute?

    var body: some View {
        Group {
            if let route, let summary = formatRoute(route) {
                HStack(spacing: 6) {
                    Image(systemName: route.kind == .scheduled ? "airplane.departure" : "clock.arrow.circlepath")
                    Text(label(for: route, summary: summary))
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .task(id: "\(callsign)|\(icao24)") {
            route = nil
            let trimmedCallsign = callsign.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedICAO = icao24.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedCallsign.isEmpty || !trimmedICAO.isEmpty else { return }
            route = await FlightRouteLookup.shared.route(
                forCallsign: trimmedCallsign,
                icao24: trimmedICAO.isEmpty ? nil : trimmedICAO
            )
        }
    }

    private func formatRoute(_ route: FlightRoute) -> String? {
        let origin = route.origin?.icao ?? route.origin?.iata
        let destination = route.destination?.icao ?? route.destination?.iata
        guard origin != nil || destination != nil else { return nil }
        return "\(origin ?? "—") → \(destination ?? "—")"
    }

    private func label(for route: FlightRoute, summary: String) -> String {
        switch route.kind {
        case .scheduled:
            return summary
        case .previous:
            return "Last: \(summary)"
        }
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

private enum DebugTab: String, CaseIterable, Identifiable {
    case main
    case world

    var id: String { rawValue }

    var title: String {
        switch self {
        case .main: return "Main"
        case .world: return "World"
        }
    }
}

private struct DebugPanel: View {
    @ObservedObject var model: AppModel

    @State private var selectedTab: DebugTab = .main

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $selectedTab) {
                ForEach(DebugTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch selectedTab {
                    case .main:
                        mainTab
                    case .world:
                        worldTab
                    }
                }
            }
        }
        .padding(20)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var mainTab: some View {
        CompassCalibrationView(model: model)

        Divider()

        VStack(alignment: .leading, spacing: 12) {
            Text("Location")
                .font(.headline)

            Picker("Preset", selection: locationPresetBinding) {
                ForEach(LocationPresetOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)

            if model.locationPresetOption == .gps {
                gpsStatusRow
            }

            if let error = model.lastLocationError {
                Text(error)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
            }

            if model.locationPresetOption == .custom {
                ObserverMapPicker(model: model)
                // 6-decimal precision (≈0.11 m at the equator) for
                // typing exact coordinates when you have them on hand.
                CoordinateField(title: "Observer lat", value: $model.observerLatitude, fractionDigits: 6)
                CoordinateField(title: "Observer lon", value: $model.observerLongitude, fractionDigits: 6)
            }

            ObserverAltitudeWheel(value: $model.observerAltitude)
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
    }

    @ViewBuilder
    private var worldTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Eye height")
                .font(.headline)

            HStack(spacing: 8) {
                eyeHeightPresetButton(title: "Sitting", meters: 1.35)
                eyeHeightPresetButton(title: "Standing", meters: 1.78)
                eyeHeightPresetButton(title: "Tall", meters: 1.90)
            }

            EyeHeightWheel(value: $model.observerHeightAboveGroundMeters)
            DebugRow(title: "Manual ground", value: model.observerGroundElevationMeters, suffix: "m", fractionDigits: 1)
        }

        Divider()

        VStack(alignment: .leading, spacing: 10) {
            Text("Reference overlay")
                .font(.headline)

            Toggle("Compass spokes", isOn: $model.showCompassOverlay)
            Toggle("Distance rings", isOn: $model.showDistanceOverlay)
            Toggle("Aircraft projection", isOn: $model.showProjectionShadow)
        }
    }

    private func eyeHeightPresetButton(title: String, meters: Double) -> some View {
        let isCurrent = abs(model.observerHeightAboveGroundMeters - meters) < 0.005
        return Button {
            model.observerHeightAboveGroundMeters = meters
        } label: {
            VStack(spacing: 2) {
                Text(title).font(.caption.weight(.semibold))
                Text("\(Int((meters * 100).rounded())) cm")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .tint(isCurrent ? .accentColor : Color.secondary)
    }

    private var locationPresetBinding: Binding<LocationPresetOption> {
        Binding(
            get: { model.locationPresetOption },
            set: { model.applyPresetOption($0) }
        )
    }

    @ViewBuilder
    private var gpsStatusRow: some View {
        switch model.gpsStatus {
        case .idle:
            EmptyView()
        case .locating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Locating…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .fixed(let horizontal, let vertical):
            HStack(spacing: 8) {
                Image(systemName: model.gpsPositionLocked ? "lock.fill" : "location.fill")
                    .foregroundStyle(model.gpsPositionLocked ? .yellow : .green)
                Text(gpsAccuracyLabel(horizontal: horizontal, vertical: vertical))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Spacer()

                Button {
                    model.setGPSPositionLocked(!model.gpsPositionLocked)
                } label: {
                    Label(
                        model.gpsPositionLocked ? "Unlock" : "Lock",
                        systemImage: model.gpsPositionLocked ? "lock.open" : "lock"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func gpsAccuracyLabel(horizontal: Double, vertical: Double?) -> String {
        let horizontalText = "±\(formatAccuracy(horizontal)) m"
        guard let vertical else {
            return "GPS fix · \(horizontalText)"
        }
        return "GPS fix · \(horizontalText) / ±\(formatAccuracy(vertical)) m alt"
    }

    private func formatAccuracy(_ meters: Double) -> String {
        let digits = meters >= 10 ? 0 : 1
        return meters.formatted(.number.precision(.fractionLength(digits)))
    }
}

private struct CompassCalibrationView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Compass calibration")
                .font(.title3.weight(.semibold))

            HStack(spacing: 12) {
                calibrationButton(
                    axis: .yaw,
                    title: "Calibrate Yaw",
                    systemImage: "scope"
                )
                calibrationButton(
                    axis: .altitude,
                    title: "Calibrate Altitude",
                    systemImage: "arrow.up.and.down"
                )
            }

            if let armedAxis = model.armedCalibrationAxis {
                Text(armedBannerText(for: armedAxis))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.yellow)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.yellow.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            CompassDial(model: model)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 380, maxHeight: 380)
                .frame(maxWidth: .infinity, alignment: .center)

            HStack {
                Text(model.calibrationStatus)
                Spacer()
                Text("\(model.yawOffsetDegrees, format: .number.precision(.fractionLength(0))) deg")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            AngleWheel(
                title: "Manual yaw",
                value: $model.yawOffsetDegrees,
                range: 0 ... 359.9,
                step: 0.1,
                wraps: true
            )
        }
    }

    private func armedBannerText(for axis: CalibrationAxis) -> String {
        switch axis {
        case .yaw:
            return "Pinch on the real aircraft to calibrate yaw."
        case .altitude:
            return "Pinch on the real aircraft to calibrate altitude."
        }
    }

    /// Prominent button: full-width, bordered-prominent style, large
    /// control size. Disabled until an aircraft is selected (since both
    /// axes use the selected aircraft as the calibration reference). When
    /// this axis is armed, the button label flips to "Cancel".
    private func calibrationButton(axis: CalibrationAxis, title: String, systemImage: String) -> some View {
        let isThisAxisArmed = model.armedCalibrationAxis == axis
        return Button {
            if isThisAxisArmed {
                model.disarmCalibration()
            } else {
                model.armCalibration(axis)
            }
        } label: {
            Label(isThisAxisArmed ? "Cancel" : title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(isThisAxisArmed ? .red : .accentColor)
        .disabled(model.selectedAircraftID == nil && !isThisAxisArmed)
    }
}

private struct CompassDial: View {
    @ObservedObject var model: AppModel

    private let cardinalBearings: [(label: String, bearing: Double)] = [
        ("N", 0),
        ("E", 90),
        ("S", 180),
        ("W", 270)
    ]

    /// Distance shown at the rim of the dial. Anything farther saturates
    /// at the edge.
    private static let maxRangeKm: Double = 50

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
                    let position = point(
                        forBearing: item.bearing,
                        radiusFraction: 1.0,
                        radius: radius,
                        center: center
                    )
                    Text(item.label)
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(item.label == "N" ? .red : .primary)
                        .position(position)
                }

                ForEach(model.aircraft) { aircraft in
                    aircraftDot(
                        for: aircraft,
                        radius: radius,
                        center: center
                    )
                }

                Circle()
                    .fill(.primary)
                    .frame(width: 6, height: 6)
                    .position(center)
            }
        }
    }

    @ViewBuilder
    private func aircraftDot(for aircraft: Aircraft, radius: CGFloat, center: CGPoint) -> some View {
        let placement = model.placement(for: aircraft)
        let radiusFraction = logScaledRadius(distanceMeters: placement.horizontalDistanceMeters)
        let position = point(
            forBearing: placement.bearingDegrees,
            radiusFraction: radiusFraction,
            radius: radius,
            center: center
        )
        let isSelected = aircraft.id == model.selectedAircraftID
        let speed = aircraft.velocityMetersPerSecond ?? 0
        let trackDegrees = speed >= Self.minimumDirectionalSpeedMetersPerSecond ? aircraft.trueTrackDegrees : nil

        Group {
            if let trackDegrees {
                let relativeTrack = GeoMath.normalizedDegrees(trackDegrees - model.yawOffsetDegrees)
                Image(systemName: "airplane")
                    .font(.system(size: isSelected ? 18 : 11))
                    .foregroundStyle(isSelected ? .yellow : .secondary)
                    // SF Symbol "airplane" defaults to nose pointing
                    // right/east at 90 deg; subtracting that puts a 0 deg
                    // relative track straight up the dial.
                    .rotationEffect(.degrees(relativeTrack - Self.airplaneSymbolDefaultRotationDegrees))
            } else if isSelected {
                Circle()
                    .strokeBorder(.yellow, lineWidth: 2)
                    .frame(width: 10, height: 10)
            } else {
                Circle()
                    .fill(.secondary)
                    .frame(width: 6, height: 6)
            }
        }
        // Inflate the hit-test area to ~24 pt so dots near the rim of the
        // dial are still tappable. The visible glyph stays small.
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
        .position(position)
        .onTapGesture {
            model.selectAircraft(id: aircraft.id)
        }
    }

    private static let minimumDirectionalSpeedMetersPerSecond: Double = 1
    private static let airplaneSymbolDefaultRotationDegrees: Double = 90

    private func point(
        forBearing bearingDegrees: Double,
        radiusFraction: CGFloat,
        radius: CGFloat,
        center: CGPoint
    ) -> CGPoint {
        let relative = GeoMath.degreesToRadians(
            GeoMath.normalizedDegrees(bearingDegrees - model.yawOffsetDegrees)
        )
        let r = radius * radiusFraction
        return CGPoint(
            x: center.x + sin(relative) * r,
            y: center.y - cos(relative) * r
        )
    }

    /// Maps a horizontal distance in meters to a `[0, 1]` radial fraction
    /// using `log(1 + km) / log(1 + maxRangeKm)`. Spreads close-in
    /// aircraft (sub-10 km) across most of the dial; far-out aircraft
    /// pile near the rim instead of squishing into the center.
    private func logScaledRadius(distanceMeters: Double) -> CGFloat {
        let distanceKm = max(0, distanceMeters / 1000.0)
        let numerator = log(1.0 + distanceKm)
        let denominator = log(1.0 + Self.maxRangeKm)
        let fraction = numerator / denominator
        return CGFloat(min(max(fraction, 0), 1))
    }
}

private struct TuningWheel: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        PrecisionWheelControl(
            title: title,
            value: $value,
            range: range,
            step: step,
            unit: "m",
            fractionDigits: 1,
            nudgeAmounts: [-10, -1, -0.1, 0.1, 1, 10]
        )
    }
}

/// Observer altitude wheel: 1 m steps over a wide range, with metre +
/// decametre + hectometre nudges for fast coarse moves.
private struct ObserverAltitudeWheel: View {
    @Binding var value: Double

    var body: some View {
        PrecisionWheelControl(
            title: "Observer alt",
            value: $value,
            range: -200 ... 6000,
            step: 1,
            unit: "m",
            fractionDigits: 0,
            nudgeAmounts: [-100, -10, -1, 1, 10, 100]
        )
    }
}

/// Eye height wheel: 1 cm resolution over the realistic body-height
/// range so the preset buttons handle the common cases and the wheel
/// fine-tunes from there.
private struct EyeHeightWheel: View {
    @Binding var value: Double

    var body: some View {
        PrecisionWheelControl(
            title: "Eye height",
            value: $value,
            range: 0.5 ... 2.5,
            step: 0.01,
            unit: "m",
            fractionDigits: 2,
            nudgeAmounts: [-0.1, -0.01, 0.01, 0.1]
        )
    }
}

/// Apple-Maps view bound to the observer coordinate. Tapping the map
/// drops the pin at that point and writes lat/lon back into AppModel.
/// Uses MapKit's `MapReader.proxy.convert(_:from:)` for screen→geo
/// conversion, no API key needed.
///
/// The marker rebuilds every render from `model.observerLatitude/
/// Longitude`, so external edits (e.g. typing into the CoordinateField
/// below) do move the pin. The camera centers on the current observer
/// at first appearance only — pan/zoom afterwards is user-driven and
/// not auto-snapped back. To follow external edits with the camera,
/// add an `.onChange` that updates `cameraPosition`.
private struct ObserverMapPicker: View {
    @ObservedObject var model: AppModel

    @State private var cameraPosition: MapCameraPosition

    init(model: AppModel) {
        self.model = model
        _cameraPosition = State(initialValue: .region(Self.region(
            latitude: model.observerLatitude,
            longitude: model.observerLongitude
        )))
    }

    var body: some View {
        MapReader { proxy in
            Map(position: $cameraPosition) {
                Marker("Observer", coordinate: CLLocationCoordinate2D(
                    latitude: model.observerLatitude,
                    longitude: model.observerLongitude
                ))
                .tint(.yellow)
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onTapGesture(coordinateSpace: .local) { point in
                if let coordinate = proxy.convert(point, from: .local) {
                    model.observerLatitude = coordinate.latitude
                    model.observerLongitude = coordinate.longitude
                }
            }
            // Recenter when AppModel coordinates change externally
            // (CoordinateField below, GPS preset switch, programmatic
            // updates). Uses a single combined onChange so the camera
            // sees a consistent lat/lon pair instead of two intermediate
            // states.
            .onChange(of: ObserverCoordinateKey(
                latitude: model.observerLatitude,
                longitude: model.observerLongitude
            )) { _, key in
                cameraPosition = .region(Self.region(
                    latitude: key.latitude,
                    longitude: key.longitude
                ))
            }
        }
    }

    private static func region(latitude: Double, longitude: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
    }
}

private struct ObserverCoordinateKey: Equatable {
    let latitude: Double
    let longitude: Double
}

private struct AngleWheel: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var wraps = false

    var body: some View {
        PrecisionWheelControl(
            title: title,
            value: $value,
            range: range,
            step: step,
            unit: "deg",
            fractionDigits: 1,
            nudgeAmounts: [-10, -1, -0.1, 0.1, 1, 10],
            wraps: wraps
        )
    }
}

private struct PrecisionWheelControl: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let fractionDigits: Int
    let nudgeAmounts: [Double]
    var wraps = false

    @State private var dragStartValue: Double?

    private let wheelHeight: CGFloat = 46
    private let tickSpacing: CGFloat = 10
    private let visibleTickCount = 35

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value, format: .number.precision(.fractionLength(fractionDigits))) \(unit)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                wheelButton(systemImage: "minus", amount: -step)

                wheelStrip

                wheelButton(systemImage: "plus", amount: step)
            }

            NudgeControls(
                value: adjustedBinding,
                amounts: nudgeAmounts
            )
        }
    }

    private var wheelStrip: some View {
        GeometryReader { proxy in
            let centerX = proxy.size.width / 2
            let centerY = proxy.size.height / 2

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.secondary.opacity(0.12))

                ForEach(visibleTicks, id: \.self) { tick in
                    let x = centerX + CGFloat(tick) * tickSpacing
                    let tickValue = adjusted(value + Double(tick) * step)

                    WheelTick(isMajor: isMajorTick(tickValue))
                        .position(x: x, y: centerY)
                }

                Rectangle()
                    .fill(.yellow)
                    .frame(width: 3, height: 32)
                    .position(x: centerX, y: centerY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let startValue = dragStartValue ?? value
                        dragStartValue = startValue
                        let translation = dominantTranslation(gesture.translation)
                        value = adjusted(startValue + translation * unitsPerPoint)
                    }
                    .onEnded { _ in
                        dragStartValue = nil
                    }
            )
        }
        .frame(height: wheelHeight)
        .accessibilityLabel(title)
        .accessibilityValue("\(value, format: .number.precision(.fractionLength(fractionDigits))) \(unit)")
    }

    private func wheelButton(systemImage: String, amount: Double) -> some View {
        Button {
            value = adjusted(value + amount)
        } label: {
            Image(systemName: systemImage)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var adjustedBinding: Binding<Double> {
        Binding(
            get: { value },
            set: { value = adjusted($0) }
        )
    }

    private var unitsPerPoint: Double {
        step * 0.35
    }

    private var visibleTicks: ClosedRange<Int> {
        -(visibleTickCount / 2) ... (visibleTickCount / 2)
    }

    private func dominantTranslation(_ translation: CGSize) -> Double {
        if abs(translation.width) > abs(translation.height) {
            return Double(translation.width)
        }

        return Double(-translation.height)
    }

    private func adjusted(_ newValue: Double) -> Double {
        let quantized = (newValue / step).rounded() * step
        if wraps {
            let normalized = GeoMath.normalizedDegrees(quantized)
            return normalized >= 360 ? 0 : normalized
        }

        return min(max(quantized, range.lowerBound), range.upperBound)
    }

    private func isMajorTick(_ tickValue: Double) -> Bool {
        let majorStep = unit == "deg" ? 5.0 : 1.0
        let ratio = tickValue / majorStep
        return abs(ratio.rounded() - ratio) < 0.000_1
    }
}

private struct WheelTick: View {
    let isMajor: Bool

    var body: some View {
        Rectangle()
            .fill(isMajor ? Color.primary.opacity(0.75) : Color.secondary.opacity(0.45))
            .frame(width: isMajor ? 2 : 1, height: isMajor ? 24 : 13)
    }
}

private struct NudgeControls: View {
    @Binding var value: Double
    let amounts: [Double]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(amounts, id: \.self) { amount in
                Button {
                    value += amount
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
