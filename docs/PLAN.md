# apron-sight Plan

## Current phase

The MVP airport-mode path is implemented. The app can run with a mock `FlightFeed` source for offline testing or a live OpenSky source for field testing around the selected observer preset.

## Completed work

- Created a visionOS SwiftUI/RealityKit app shell named `apron-sight`.
- Added a fixed home demo target at `47.333859, 8.520262`, altitude `432 m`.
- Added an editable default observer coordinate near the target: `47.333580, 8.519790`, altitude `420 m`.
- Rendered ten moving mock aircraft in an immersive space using observer-relative coordinates.
- Added a debug panel showing observer lat/lon/alt, target lat/lon/alt, distance, bearing, elevation, relative bearing, and yaw offset.
- Added isolated WGS84 ECEF -> ENU coordinate math in `ApronSightCore`.
- Added deterministic unit tests for same-position, east/north offsets, home-demo placement, and yaw offset mapping.
- Added manual yaw calibration with a slider. The yaw offset is treated as the real-world bearing aligned with the user's forward direction.
- Added a compass calibration card, calibrated immersive compass spokes, and a floating front compass panel for yaw validation.
- Added distance rings with labels on the observer-height plane plus an aircraft projection silhouette and vertical altitude line.
- Replaced the crude block marker with a textured real A350 USDZ asset. The lightweight traffic marker is used as the runtime fallback if the textured asset cannot be loaded.
- Added target East/North/Altitude tuning sliders with `0.1 m` slider steps, fine nudge buttons, and a `+/-500 m` range around the fixed home coordinate.
- Added local aircraft tuning sliders after geo placement: left/right and back/forward with `0.1 m` slider steps, fine nudge buttons, and a `+/-500 m` range, plus aircraft yaw offset. These move/rotate the visible aircraft in the calibrated viewer-relative frame without changing the stored target coordinate.
- Extended distance rings and axis guides to `500 m`.
- Removed network terrain altitude lookup. Ground is now a manual calibration plane from observer altitude, eye height, and ground-level offset.
- Added a manual ground-level calibration slider to shift grounded overlays up/down by `0.1 m` steps.
- Added gaze/tap aircraft selection with RealityKit input/collision targets sized to keep far aircraft selectable.
- Added selected-aircraft status in the debug panel and as a fixed heads-up immersive status panel, showing distance, height above ground, speed, bearing, elevation, origin country, and vertical rate.
- Corrected the aircraft track-to-RealityKit yaw mapping so aircraft noses align with simulated travel direction.
- Reduced mock aircraft speeds to local approach/flyby-like values and lengthened their straight-line paths to avoid frequent wraparound jumps.
- Improved immersive performance by rendering only one high-detail textured A350 at a time for the selected/primary aircraft. Other mock aircraft now use lightweight directional 3D markers with the same meter scale and tap targets.
- Reduced aircraft list publishing to 1 Hz. Per-frame aircraft motion is still evaluated by the RealityKit renderer without invalidating SwiftUI.
- Made the simulation runner single-instance and cancellable so view lifecycle events do not accidentally start duplicate update loops.
- Added a movable ground cursor with viewer-relative `+/-500 m` controls, distance/bearing readouts, and a green ground line from the observer ground point.
- Added explicit aircraft size controls. The default length is `66.8 m` for a real-size A350-900, with a smaller marker preset for calibration and debug readouts for tuned distance and estimated visual angle.
- Added a tiny `AircraftProvider` abstraction. The app now uses `LiveAircraftProvider` in the visionOS target to bridge `FlightFeed` snapshots into `Aircraft`.
- Added location presets for home, ZRH Observation Deck B, ZRH center, and custom coordinates. Presets reset manual ground offset while preserving yaw and eye height.
- Wired the local `FlightFeed` package into the Xcode project. The debug UI can switch between mock and live OpenSky data.
- Added dead-reckoned aircraft interpolation from the latest snapshot using velocity, true track, and vertical rate.
- Cached aircraft entities and collision radius buckets in the immersive renderer, and replaced segmented distance rings with single mesh rings.
- Added `docs/FIELD_TEST.md` with the first home-test procedure.
- Added `docs/RUN_ON_DEVICE.md` with the Xcode project/device setup path.
- Added `docs/MODEL_ATTRIBUTION.md` for the CC-BY A350 model source and conversion notes.

## Acceptance criteria

### Phase 0 - Project shell + home-test demo object

- App builds for visionOS simulator or records the exact local blocker.
- App shows one demo 3D marker at/near `47.333859, 8.520262`.
- Debug UI shows observer, target, distance, bearing, elevation, and yaw offset.
- No live network or paid API dependency.

### Phase 1 - Coordinate math

- Converts observer and target lat/lon/alt into ENU meters.
- Computes distance, bearing, and elevation.
- Pure math is isolated in a small Swift package target.
- Unit tests cover deterministic coordinate cases.

### Phase 2 - Manual calibration

- Observer location can be edited in the debug panel.
- Manual yaw slider changes target placement and relative bearing.
- Calibration status is visible in the debug UI.
- No Vision Pro compass or heading API is used.

### Phase 3 - Data provider abstraction

- `AircraftProvider` is defined.
- `FlightFeed` provides mock and OpenSky-backed snapshots.
- The visionOS app bridges `FlightFeed` snapshots into app `Aircraft` values without adding networking to `ApronSightCore`.

### Phase 4 - Home device field test readiness

- `docs/FIELD_TEST.md` documents where to stand, the target coordinate, calibration, observations, and limitations.
- Ground level uses manual calibration only, with no terrain network dependency.
- Local simulator build succeeds.
- Generic visionOS device SDK build succeeds with signing disabled.

### Phase 5 - Airport mode MVP

- Debug UI exposes location presets and editable custom observer coordinates.
- Debug UI exposes a source toggle for Mock and Live.
- Live mode polls OpenSky through `FlightFeed`; mock mode uses `MockFlightProvider` through the same app provider path.
- Renderer gets per-frame dead-reckoned aircraft positions from `currentAircraft(at:)`.
- The selected-aircraft HUD is fixed in front of the user and remains readable independent of aircraft distance.

## Validation

- Revalidated on May 3, 2026 after wiring `FlightFeed`, adding location presets, replacing the aircraft-attached status window with the HUD panel, and trimming renderer hot-path work.
- Passed: `usdchecker Assets/Models/A350/Processed/A350_Qatar_CC_BY.usdz`
  - Validation result: success.
- Passed: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`
  - 8 tests, 0 failures.
- Passed: `cd FlightFeed && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`
  - 10 tests, 0 failures.
- Passed: `cd FlightFeed && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift run flightfeed-demo --lat 47.4647 --lon 8.5492 --radius 50 --iterations 1 --interval 10`
  - Returned one OpenSky snapshot with 34 flights inside 50 km of LSZH.
- Passed: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project apron-sight.xcodeproj -scheme apron-sight -destination 'generic/platform=visionOS Simulator' -derivedDataPath DerivedData build`
- Passed: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project apron-sight.xcodeproj -scheme apron-sight -destination 'generic/platform=visionOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build`

## Next step

- Run the app on the actual Vision Pro, pick the ZRH center or Observation Deck B preset, calibrate yaw manually, and compare live traffic bearings/elevations against visible aircraft.
- If live data is unavailable or rate-limited, switch Source to Mock and validate calibration/HUD behavior offline.

## Blockers

- Exact home observer coordinate was not provided. The app uses an editable nearby default observer coordinate for now.
- Active `xcode-select` points at Command Line Tools, whose Swift toolchain could not import `XCTest`. Validation succeeds when commands are run with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Real device deployment still needs a valid Apple development team/signing configuration in Xcode.
- The repository root includes `Package.swift` for math tests; open `apron-sight.xcodeproj` for app runs.
