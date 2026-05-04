# AGENTS.md

Guidance for AI coding agents (Claude, Codex, Cursor, etc.) working in this repo.

## What this is

`apron-sight` is a visionOS app that places live air traffic in immersive space relative to the wearer's manually-calibrated observer position. The debug panel toggles between a deterministic mock provider (12 simulated aircraft circling the observer) and live OpenSky data via OAuth, both running through the same `LiveAircraftProvider`. Calibration is fully manual: yaw, eye height, and ground-level offset are sliders. See `docs/PLAN.md` for current phase and `docs/FIELD_TEST.md` for the field-test procedure.

Stack: Swift 6, SwiftUI, RealityKit, visionOS 1+. No `CLHeading`, no Vision Pro compass, no terrain DEM lookups — those don't work well enough for this use case yet.

## Repository layout

Three independent units, glued by the Xcode project:

- `apron-sight.xcodeproj` — the visionOS app. **This is what actually runs on device.** Open in Xcode for app builds. A build phase copies `Config/OpenSkyCredentials.local.json` (gitignored) into the bundle so the live provider can authenticate.
- `Package.swift` (repo root) — Swift package `ApronSightCore`. Pure math (`GeoMath`, `GeoCoordinate`, `Aircraft`, `DemoScenario`, `LocationPreset`, `AngularAircraftSelector`). No UIKit, no network, no RealityKit. Has unit tests.
- `FlightFeed/Package.swift` — Swift package `FlightFeed`. OpenSky REST client, polling feed, mock provider. Cross-platform (macOS/iOS/visionOS). Imported by the app via `LiveAircraftProvider`.
- `ApronSight/App/` — visionOS app sources (`AppModel`, `ContentView`, `ImmersiveView`, `LiveAircraftProvider`, `GPSLocationProvider`, `OpenSkyConfiguration`, `ApronSightApp`). Imports `ApronSightCore` and `FlightFeed`.
- `Assets/Models/A350/` — CC-BY A350 USDZ asset (see `docs/MODEL_ATTRIBUTION.md`).

`ApronSightCore` is the only target the two packages and the app share. Anything that needs to be testable without RealityKit goes there.

## Build & test

The active `xcode-select` may point at Command Line Tools, whose Swift toolchain can't import `XCTest`. Always prefix Xcode commands:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

Common commands (run from repo root):

```sh
# Core math tests (Sources/ApronSightCoreTests)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test

# FlightFeed tests
cd FlightFeed && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test

# visionOS simulator build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project apron-sight.xcodeproj -scheme apron-sight \
  -destination 'generic/platform=visionOS Simulator' \
  -derivedDataPath DerivedData build

# Generic visionOS device build (no signing — for CI / sanity check)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project apron-sight.xcodeproj -scheme apron-sight \
  -destination 'generic/platform=visionOS' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build

# USDZ asset validation
xcrun usdchecker Assets/Models/A350/Processed/A350_Qatar_CC_BY.usdz
```

Real device deployment needs a valid Apple development team in Xcode signing settings. Live OpenSky data needs `Config/OpenSkyCredentials.local.json` with an OAuth client ID/secret; mock mode works without it.

## Architecture conventions

- **Coordinate frames.** Geographic input is WGS84 lat/lon/alt. `GeoMath` converts to ECEF then ENU (east/north/up meters relative to observer). `localCoordinate(for:yawOffsetDegrees:)` rotates ENU into the RealityKit frame: `+x` right, `+y` up, `−z` forward. Yaw offset is the real-world bearing currently aligned with the user's forward direction. Don't introduce a fourth frame.
- **Per-frame motion lives in the renderer, not in `@Published` state.** `ImmersiveView` subscribes to `SceneEvents.Update` (90 Hz) and calls `model.currentAircraft(at:)`, a pure function that dead-reckons each flight from the latest `FlightSnapshot` (bounded by `GeoMath.maximumDeadReckoningSeconds = 30s` so a stalled feed can't extrapolate aircraft off into the next country). The 1 Hz `runFlightUpdates` tick republishes `AppModel.aircraft` for SwiftUI consumers (debug panel, selected-aircraft lookup). Keep this split — don't drive RealityKit entities from `@Published` invalidation cycles.
- **Aircraft positions resolve once per frame.** `renderScene` builds an `aircraftPositions: [String: SIMD3<Float>]` dict by calling `model.realityPosition(for:)` per aircraft once, then threads it into the visual aircraft sync, the selection-proxy sync, and the selection-ring update. Don't add a fourth caller that recomputes positions independently — they will drift by one frame.
- **Detailed model is single-instance.** Only the selected (or primary) aircraft renders as the high-detail textured A350. Others use `makeLightweightAircraftMarker`. Don't change this without a perf reason — visionOS frame budget is tight.
- **Compass calibration is user-initiated.** The "Calibrate Yaw" and "Calibrate Altitude" buttons in `CompassCalibrationView` arm a state, the user pinches at the real selected aircraft in the sky, and the math in `CompassCalibration.swift` solves for `yawOffsetDegrees` (yaw axis) or `verticalCalibrationOffsetMeters` (altitude axis). The altitude offset is applied to BOTH the rendered ground AND every aircraft's scene-Y in `realityPosition(for:)`, so the aircraft-above-ground geometry stays constant under altitude calibration. Eye height stays manual (it's a physical user property, not a calibration). No `CLHeading`, no compass APIs, no terrain DEM lookups. Both calibration axes persist per `LocationPreset` via `UserDefaults`.
- **Location is preset-driven.** `LocationPresetOption` is the UI selector; `LocationPreset` is the core enum. `.gps` is the default; `GPSLocationProvider` (a `CLLocationManager` wrapper) writes live coordinates into `observerLatitude/Longitude/Altitude`. Switching to a non-GPS preset stops the provider. The first GPS activation triggers the system permission prompt.

## Selection pipeline

Selection has been through several iterations and is the most architecturally load-bearing part of `ImmersiveView`. The current shape:

- **Each aircraft has a near-field selection proxy** at 8m from the user's head, in the bearing direction of the actual aircraft (which itself can be tens of km away in scene coords). Sized to match the aircraft's angular footprint via `AngularAircraftSelector.angularRadiusRadians`, capped at 6° to bound proxy density when bearings cluster. `HoverEffectComponent` on each proxy gives the visionOS system hover highlight before the user pinches.
- **A head-anchored "empty space" shell** (six walls forming a 100m cube around the user, all named `"EmptySpaceTarget"`) catches gaze-pinches that miss every proxy. visionOS picks the closest collision along the gaze ray, so the shell only intercepts when no proxy is in the gaze direction.
- **The pinch handler dispatches linearly:** `AngularAircraftSelector.selectedID(...)` returns the picked aircraft, or nil → check `value.entity.name == "EmptySpaceTarget"` to deselect, otherwise no-op. No recursive entity-name fallback.
- **First-frame head-pose guard.** `userPosition(_:)` returns nil until `headAnchor.isAnchored` is true. Pinches before then are dropped (better than routing them through scene-origin math when the user is somewhere else). The proxy sync and selection ring are skipped for those frames; the visual aircraft tree still updates.
- **Selection ring.** A billboarded yellow annulus (`SimpleMaterial`, alpha 0.85, CCW winding so it's front-facing toward the user) rendered around the selected aircraft, sized `max(aircraftLength * 0.6, distance * tan(1.5°))` so it stays visible at any range — close aircraft get a ring slightly larger than the model, far aircraft get a constant ~3° angular ring even when the detailed A350 is too small to see.
- **Window-side panel.** `ContentView.SelectedFlightPanel` reads `model.selectedAircraftStatus` and shows live data + `AircraftPhotoView` (ICAO24-keyed photo lookup). The "Clear" button calls `model.clearSelectedAircraft()`. Don't break that contract.
- **Auto-clear on dropout.** `AppModel.publishCurrentAircraft` clears `selectedAircraftID` when the selected aircraft leaves the live list.

`AngularAircraftSelector` and its tests live in `Sources/ApronSightCore/GeoMath.swift` — selection math is pure, the renderer just orchestrates RealityKit.

## Known cleanup work

These are loose ends an agent should be aware of:

1. **30s dead-reckoning bound.** `GeoMath.maximumDeadReckoningSeconds = 30` extrapolates aircraft for up to 30s after the last snapshot. Could be tightened or made adaptive if field test shows visible drift before the next poll lands.
2. **Forking note.** `PRODUCT_BUNDLE_IDENTIFIER` is `com.milankubicek.apronsight` and `DEVELOPMENT_TEAM` is intentionally blank in `apron-sight.xcodeproj/project.pbxproj`. Anyone forking needs to set their own bundle ID and signing team in Xcode before they can run on device.

## Things to avoid

- Don't add `CLHeading` or any device-sensor heading code. The whole point of the compass calibration UI is that those don't work well enough for this use case yet. `CLLocationManager` IS allowed — it's used by `GPSLocationProvider` for the `.gps` location preset (one-axis position only, never heading).
- Don't introduce a network dependency in `ApronSightCore`. It is intentionally pure.
- Don't import RealityKit or UIKit from `FlightFeed`. It must stay cross-platform.
- Don't commit Apple development team IDs, signing identities, or `Config/OpenSkyCredentials.local.json`.
- Don't bypass `AngularAircraftSelector` with ad-hoc selection logic in the gesture handler. If you need a new selection mode, extend the selector or add a parallel pure function in `ApronSightCore` with tests.
- Don't read aircraft positions from `model.realityPosition(for:)` directly inside per-frame sync helpers. Use the `aircraftPositions` dict threaded through `renderScene`.
- Don't replace the manual `groundCalibrationOffsetMeters` slider with a terrain/DEM lookup. Calibration is manual on purpose.
- Don't widen the `AircraftProvider` protocol (`func aircraft(at: Date) -> [Aircraft]`) with async or throwing methods unless you also update `LiveAircraftProvider` and `AppModel`'s init.

## Coding style

- Swift 6, value types where reasonable, `@MainActor` for anything that touches `AppModel` or RealityKit entities.
- `let` over `var`. `private` by default; widen only when needed.
- Comments explain *why*, not *what*. The existing comments around `LiveAircraftProvider`, `runFlightUpdates`, the selection pipeline in `ImmersiveView.renderScene`, and the dead-reckoning bound are the model — load-bearing context that isn't obvious from the code.
- Match existing naming: `*Meters`, `*Degrees`, `*Seconds` suffixes for unit-bearing values. The codebase is unit-suffix-heavy on purpose — keep it.

## Reference coordinates

- Home demo target: `47.333859, 8.520262`, alt `432 m`
- Default observer (home): `47.333580, 8.519790`, alt `420 m`
- LSZH (Zürich Airport) ARP: `47.4647, 8.5492`, elev `432 m` — ~14.6 km north of home
- LSZH Observation Deck B: `47.451210, 8.557410`, alt `432 m`

Available as `LocationPreset` cases (`.home`, `.zrhObservationDeck`, `.zrhCenter`, `.custom(GeoCoordinate)`) in `ApronSightCore`.

## Documentation to read first

- `docs/PLAN.md` — current phase, completed work, acceptance criteria, validation log
- `docs/FIELD_TEST.md` — how the app is meant to be used on a real Vision Pro
- `docs/RUN_ON_DEVICE.md` — device deployment path
- `docs/MODEL_ATTRIBUTION.md` — A350 asset license

## When in doubt

Ask before: changing the calibration model (yaw / ground / eye-height semantics), changing the selection pipeline (proxies / angular selector / shell / ring), breaking the `ApronSightCore` purity rule, breaking the `ContentView` selection panel contract, or refactoring the `AppModel` `@Published` surface. Everything else is fair game.
