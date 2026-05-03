# Home Field Test

## Standpoint

Stand at the intended home observation point and keep your head position steady while opening the immersive space.

The app currently defaults to this editable observer coordinate:

- Latitude: `47.333580`
- Longitude: `8.519790`
- Altitude: `420 m`

Update those observer fields in the debug panel if you have a better measured standing-point coordinate. Treat altitude as approximately headset altitude above sea level.

## Demo Aircraft

The app now runs a mock simulation with ten moving aircraft around the observer. They use deterministic callsigns, tracks, slower approach/flyby-like speeds, and heights above the manually calibrated ground plane. There is still no live flight data.

The first aircraft remains the primary tuning target in the debug panel. Other aircraft move continuously around and above the observer, including far aircraft that use larger invisible selection targets.

For headset performance, only the selected aircraft, or the primary aircraft when nothing is selected, is shown as the high-detail textured A350. The other mock aircraft use lightweight directional markers at the same configured meter scale.

## Calibration

Use the yaw slider as the first manual calibration control.

- If you know the real-world bearing you are facing, set the yaw offset to that bearing.
- If the primary target should be straight ahead, set the yaw offset close to the displayed target bearing.
- Use the compass calibration card to compare forward bearing, target bearing, and relative target bearing.
- Use Target Ahead to set yaw to the current target bearing when you are intentionally facing the target.
- The immersive compass spokes are calibrated visual aids. They do not use Vision Pro compass data.
- A floating compass panel appears in front of the initial view direction and updates with yaw/target bearing values.

Use target tuning only after yaw is roughly correct:

- East and North sliders move the primary demo aircraft around its current simulated coordinate by `0.1 m` slider steps over a `+/-500 m` range.
- Altitude moves the primary demo aircraft by `0.1 m` slider steps over a `+/-500 m` range.
- The adjusted target lat/lon/alt values in the debug panel reflect these offsets.
- Local Left/Right and Back/Forward sliders move the visible aircraft by `0.1 m` slider steps over a `+/-500 m` range without changing the target lat/lon.
- The `-10`, `-1`, `-0.1`, `+0.1`, `+1`, and `+10` buttons under each tuning slider are for fine nudges when the full-range slider is too coarse.
- Use Reset to clear tuning offsets.

## Ground Calibration

Ground is manual-only. The app derives a flat ground plane from observer altitude, eye height, and the Ground level calibration slider.

- Set `Eye height` to your approximate headset height above the floor/ground.
- Use the `Ground level` slider to manually move grounded overlays up/down by `0.1 m` steps until the rings/cursor feel aligned with the real ground.
- No satellite/DEM terrain altitude is used.

Use the ground cursor to sanity-check distance perception:

- Enable `Show cursor`.
- Move `Left / Right` and `Back / Forward` to place the cursor on the grounded surface.
- Compare the cursor's visual position with `Cursor distance` and `Cursor bearing`.
- The green line from your ground point to the cursor is a distance aid; it is not part of the aircraft projection.

Use aircraft size tuning separately from target placement:

- The default aircraft length is `66.8 m`, matching Airbus' published A350-900 overall length.
- With the default observer and target, the app places the aircraft only about `49 m` away, so a real-size A350 should look very large.
- Use the `Marker` size preset if you want a smaller visual object for calibration.
- Use the `Real` size preset before judging whether the real-world scale feels plausible.
- The debug panel shows the estimated visual length in degrees as a quick sanity check for apparent size.

Use aircraft selection:

- Look at an aircraft and tap your fingers.
- A selected-aircraft status card appears in the debug panel and as a floating immersive status window.
- The status shows relative distance, height above ground, and ground speed.
- Far aircraft have larger invisible selection volumes so they remain selectable even when the visible model is small.

## What To Observe

- The ten mock aircraft should move continuously along plausible straight tracks above and around you, with noses aligned to their direction of travel.
- Looking at an aircraft and tapping should select it and show its status.
- Selecting an aircraft should move the detailed textured A350 to that aircraft while the rest remain lightweight markers.
- The primary aircraft should move smoothly when target East, North, or Altitude tuning changes.
- The debug panel's relative bearing should approach `0 deg` when the marker is straight ahead.
- Distance rings with meter labels out to `500 m` on the manually calibrated ground should make the horizontal range easier to estimate.
- The yellow projection marker and dark aircraft silhouette should sit on the manual ground plane under the selected aircraft.
- The yellow vertical line should make the selected aircraft's elevation above ground easier to read.
- The selected/primary aircraft is a textured A350 model scaled in meters. The lightweight aircraft marker remains as the fallback if the asset fails to load.
- The marker should feel plausibly anchored in the direction of the target coordinate, not merely glued to the headset.

## Known Limitations

- No Vision Pro compass or `CLHeading` is used.
- Observer location is manual for now.
- Aircraft heights are mock values above the manually calibrated ground plane.
- Mock aircraft still fly simple straight-line loops, so very long sessions may eventually show a wraparound reposition.
- There is no live flight data yet.
- Device deployment may require selecting a valid Apple development team in Xcode.
- The compass is a calibrated overlay, not a live magnetic or true-heading sensor.
- The A350 model is a CC-BY textured asset converted to USDZ; see `docs/MODEL_ATTRIBUTION.md`.
- Apparent size is correct only if the observer location, target location, and target altitude are reasonably accurate. A nearby home demo coordinate will make a real-size widebody look enormous.
