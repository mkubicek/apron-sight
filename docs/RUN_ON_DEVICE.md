# Run On Vision Pro

Open the app project explicitly:

```bash
open /Users/mkubicek/repos/apron-sight/apron-sight.xcodeproj
```

Do not open the repository folder or `Package.swift` in Xcode for device runs. The root `Package.swift` exists only so the pure geo math can be tested with SwiftPM; opening it puts Xcode in package mode.

## Xcode Setup

1. Select the `apron-sight` project.
2. Select the `apron-sight` target.
3. Open `Signing & Capabilities`.
4. Enable `Automatically manage signing`.
5. Select your Apple development team.
6. Change the bundle identifier if Xcode says it is unavailable.
7. In the toolbar, choose the physical `Apple Vision Pro` destination, not `Any visionOS Device` and not a simulator.

## Headset Setup

1. Keep the Vision Pro awake and unlocked.
2. Confirm Developer Mode is enabled on the headset.
3. Keep the Mac and Vision Pro on the same network.
4. Wait for Xcode to show the device as available, not connecting or preparing.

## Validate From Terminal

After signing is configured in Xcode, this should build for the headset:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project apron-sight.xcodeproj \
  -scheme apron-sight \
  -destination 'platform=visionOS,name=Apple Vision Pro' \
  -derivedDataPath DerivedData \
  build
```

If command-line build still reports a missing development team, set the team in Xcode first. If the build succeeds but Run does not launch, check `Product > Scheme > Edit Scheme... > Run > Info` and make sure `Executable` is `apron-sight.app`.
