# apron-sight

A visionOS app that places live air traffic in immersive space, anchored to the wearer's manually-calibrated observer position. Look up; the aircraft you see in the sky are pinned to their real-world coordinates around you.

> **Status: home-test PoC.** Calibration is fully manual on purpose — no compass, no GPS, no terrain DEM. The app trades automatic alignment for predictable behavior at a single fixed observer point. Field-tested at home and at LSZH (Zürich Airport).

## Hardware

- Apple Vision Pro for actual use.
- visionOS Simulator works for build sanity checks but doesn't render the immersive scene meaningfully.

## What works

- **Live OpenSky air traffic** via OAuth (50 km radius around the observer, polling at the anonymous-tier limit).
- **Deterministic mock provider** for offline development and field-test rehearsal (12 aircraft circling the observer).
- **Manual yaw / eye-height / ground-level calibration** via SwiftUI sliders, plus an "align target ahead" shortcut for one-tap yaw lock-in.
- **Selection that works at any distance.** Tap an aircraft, however far, via gaze-pinch — angular resolution + a yellow ring that scales with distance keeps the selected aircraft findable even when the detailed model has shrunk below visibility.
- **Selected-aircraft details panel** in the SwiftUI window: callsign, distance, height AGL, ground speed, bearing, altitude, vertical rate, origin country, and an ICAO24-keyed photo lookup.
- **Location presets:** home, LSZH center, LSZH Observation Deck B, plus a custom-coordinate path.

## Build

The active `xcode-select` may point at Command Line Tools, whose Swift toolchain can't import `XCTest`. Always prefix Xcode commands:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

Common commands from the repo root:

```sh
# Run the core unit tests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test

# Build for the visionOS Simulator
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project apron-sight.xcodeproj -scheme apron-sight \
  -destination 'generic/platform=visionOS Simulator' \
  -derivedDataPath DerivedData build
```

To run on a real Vision Pro, set your Apple development team in Xcode signing settings. See [`docs/RUN_ON_DEVICE.md`](docs/RUN_ON_DEVICE.md).

## Live data setup (optional)

Mock mode works out of the box. For live OpenSky data, get OAuth client credentials at <https://opensky-network.org/> and write them to `Config/OpenSkyCredentials.local.json` (gitignored):

```json
{
  "clientId": "your-client-id",
  "clientSecret": "your-client-secret"
}
```

An Xcode build phase copies the file into the app bundle. The debug panel's flight-source picker will then expose a "Live" option.

## Repository layout

- `ApronSight/` — visionOS app (SwiftUI + RealityKit).
- `Sources/ApronSightCore/` — Swift package: pure math (ECEF/ENU coordinates, dead reckoning, angular selection, location presets). No UIKit, no RealityKit, no network.
- `FlightFeed/` — Swift package: OpenSky REST client, polling feed, deterministic mock provider. Cross-platform (macOS / iOS / visionOS).
- `Assets/Models/A350/` — bundled A350 USDZ model (CC-BY 4.0, see [`docs/MODEL_ATTRIBUTION.md`](docs/MODEL_ATTRIBUTION.md)).
- `docs/` — field-test procedure, device-run path, model attribution, design plan.

For architecture conventions and "what not to break" notes, see [`AGENTS.md`](AGENTS.md).

## Documentation

- [`docs/PLAN.md`](docs/PLAN.md) — current phase, completed work, validation log.
- [`docs/FIELD_TEST.md`](docs/FIELD_TEST.md) — how to use the app on real hardware.
- [`docs/RUN_ON_DEVICE.md`](docs/RUN_ON_DEVICE.md) — device deployment.
- [`docs/MODEL_ATTRIBUTION.md`](docs/MODEL_ATTRIBUTION.md) — A350 asset license and source chain.

## Attribution

The bundled A350 model is by **jhag** (via Sketchfab / FetchCFD) under [Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/). See [`docs/MODEL_ATTRIBUTION.md`](docs/MODEL_ATTRIBUTION.md) for the full source chain and processing notes.

## License

The project's own code is released under the [MIT License](LICENSE). The bundled A350 asset is separately licensed under [Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/) — see [`docs/MODEL_ATTRIBUTION.md`](docs/MODEL_ATTRIBUTION.md).

## Forking

`PRODUCT_BUNDLE_IDENTIFIER` is `com.milankubicek.apronsight` and `DEVELOPMENT_TEAM` is intentionally blank. Set your own bundle ID and signing team in Xcode before building for device.
