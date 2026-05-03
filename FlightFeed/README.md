# FlightFeed

Self-contained Swift package that fetches **live aircraft positions inside a
geographic radius** for later visualisation in apron-sight. Lives next to the
existing `Sources/ApronSightCore/` but does not modify it — pull it in later
as a local package dependency.

```swift
let region = RadiusRegion(latitudeDegrees: 47.4647, longitudeDegrees: 8.5492, radiusKm: 80)
let provider = OpenSkyClient.anonymous()
let snapshot = try await provider.snapshot(for: region)
print(snapshot.flights.count)   // 43 around ZRH at the time of this writing
```

For continuous updates:

```swift
let feed = RadiusFlightFeed(provider: provider, region: region, pollInterval: 10)
for await snapshot in feed.snapshots() {
    update(viewModel: snapshot.flights)
}
```

## Why OpenSky Network

Surveyed the realistic free options before picking:

| Provider           | Free tier                              | Auth                       | Coverage      | Verdict                                              |
| ------------------ | -------------------------------------- | -------------------------- | ------------- | ---------------------------------------------------- |
| **OpenSky Network**| ~400 calls/day anon, 4 000/day OAuth   | none / OAuth2 client-creds | global ADS-B  | **picked** — best free coverage, real public REST    |
| ADS-B Exchange     | Paid since 2023                        | API key                    | global        | no longer free                                       |
| AirLabs            | 1 000 calls/month                      | API key                    | global        | too tight for live polling                           |
| AviationStack      | 100 calls/month, schedules only        | API key                    | flight schedules | not real-time positions                          |
| Aircraft Scatter   | local only                             | n/a                        | RTL-SDR feed  | useful future hardware path, not a web API           |

Endpoint: `GET https://opensky-network.org/api/states/all?lamin=&lomin=&lamax=&lomax=`.
Schema documented at <https://openskynetwork.github.io/opensky-api/rest.html>.

## Architecture

```
RadiusRegion ── boundingBox ──► OpenSkyClient ──► OpenSkyParser ──► [LiveFlight]
                                                                         │
RadiusFlightFeed ◄──── AsyncStream<FlightSnapshot> ◄── tighten to true circle
```

- **`RadiusRegion`** — centre + radius. Computes the smallest enclosing
  lat/lon box for the OpenSky query. Polar regions collapse to full longitude.
- **`OpenSkyClient`** — REST client. Three credential modes:
  - `.anonymous()` — no auth, ~10 s minimum cadence.
  - `.basicAuth(username:password:)` — legacy.
  - `.oauth(clientID:clientSecret:)` — current OpenSky auth, get creds at
    <https://opensky-network.org/my-opensky/credentials>. Tokens cached and
    refreshed automatically.
- **`OpenSkyParser`** — decodes the heterogeneous 17-field state arrays via
  `JSONSerialization`. Drops aircraft without a position fix.
- **`RadiusFlightFeed`** — actor-backed polling loop. Honours `Retry-After`
  on 429s, forwards transient errors to a handler, terminates on stream
  cancellation.
- **`MockFlightProvider`** — deterministic 12-aircraft circle for tests / UI
  preview without burning your API quota.

After the bounding-box query returns, results are filtered by **true
great-circle distance** so a 50 km radius really means 50 km, not the
inscribed square.

## Bridging into ApronSightCore

`LiveFlight` is intentionally not coupled to `Aircraft` from `ApronSightCore`
so this package builds standalone. When you wire it up, add a one-screen
adapter in the host app:

```swift
import ApronSightCore
import FlightFeed

extension LiveFlight {
    var asAircraft: Aircraft {
        Aircraft(
            id: id,
            callsign: callsign.isEmpty ? id.uppercased() : callsign,
            coordinate: GeoCoordinate(
                latitudeDegrees: latitudeDegrees,
                longitudeDegrees: longitudeDegrees,
                altitudeMeters: altitudeMeters ?? 0
            ),
            velocityMetersPerSecond: velocityMetersPerSecond,
            trueTrackDegrees: trueTrackDegrees,
            verticalRateMetersPerSecond: verticalRateMetersPerSecond,
            isOnGround: isOnGround
        )
    }
}
```

To depend on this package locally:

```swift
.package(path: "FlightFeed")
```

## CLI demo

```sh
swift run flightfeed-demo --lat 47.4647 --lon 8.5492 --radius 80 --interval 12 --iterations 3
swift run flightfeed-demo --mock --forever         # offline UI smoke test
swift run flightfeed-demo --client-id … --client-secret …
```

## Tests

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

(The Command-Line-Tools-only SDK does not ship XCTest — same constraint as the
parent package.)

## 3D aircraft models — survey for the visualisation step

Free, redistributable airliner models with airline liveries are surprisingly
scarce. Concrete options found:

| Source                                        | License        | Format      | Coverage                                            | Liveries                            |
| --------------------------------------------- | -------------- | ----------- | --------------------------------------------------- | ----------------------------------- |
| [Flightradar24/fr24-3d-models]                | **GPLv2**      | glTF/GLB    | ~30 airliners (A320/330/350/380, B737/747/777/787, ATR, CRJ, E-jets, Cessna, glider, etc.) | house liveries only — repo refuses airline submissions |
| [Ysurac/FlightAirMap-3dmodels]                | unstated       | glTF        | ~60 types (similar coverage + Cirrus, Piper, P-40)  | none                                |
| [FlightGear FGAddon]                          | **GPLv2+**     | AC3D → glTF (Blender) | ~500 aircraft incl. hero-quality A320/B738/B787   | many community liveries with real airlines, also GPL |
| [Sketchfab CC-BY/CC0 filter]                  | per-model      | glTF/GLB    | hundreds, hand-pick                                 | usually baked per-model             |
| [Flightsim.to] / [X-Plane.org skins]          | per-upload, mostly **non-commercial** | DDS/PNG | thousands of airline liveries | UV-locked to specific payware airframes — not portable |

GPL is sticky for a closed-source iOS app. Two recommendations:

1. **Closed-source path** — curate a small CC-BY set from Sketchfab (one model
   per major airframe) plus a runtime-applied livery decal layer. More upfront
   work but legally safe for the App Store and lets you control polycount.
2. **Open-source path** — start from `Flightradar24/fr24-3d-models` GLBs.
   Ship under GPLv2-compatible terms. Already optimised for hundreds of
   concurrent web instances; converts to USDZ via Reality Composer Pro or
   `usdzconvert`.

Reference implementation worth reading for instancing/LOD patterns even if
you don't use its assets: [`kewonit/aeris`].

[Flightradar24/fr24-3d-models]: https://github.com/Flightradar24/fr24-3d-models
[Ysurac/FlightAirMap-3dmodels]: https://github.com/Ysurac/FlightAirMap-3dmodels
[FlightGear FGAddon]: https://wiki.flightgear.org/FGAddon
[Sketchfab CC-BY/CC0 filter]: https://sketchfab.com/features/gltf
[Flightsim.to]: https://flightsim.to/liveries
[X-Plane.org skins]: https://forums.x-plane.org/files/category/2-aircraft-skins-liveries/
[`kewonit/aeris`]: https://github.com/kewonit/aeris
