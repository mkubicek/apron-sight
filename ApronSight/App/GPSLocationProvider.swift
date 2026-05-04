import CoreLocation

/// Lightweight CoreLocation wrapper for the `.gps` location preset.
///
/// AppModel calls `start(...)` when the user selects the GPS preset and
/// `stop()` when they switch away. Updates and errors are delivered on
/// MainActor so the model can update its `@Published` properties without
/// further hopping.
///
/// Permission flow: on first `start()`, requests authorization if not yet
/// determined. Once authorized, subsequent `start()` calls re-subscribe to
/// updates without re-prompting. Denial is surfaced via the error callback.
///
/// Threading: `CLLocationManager` delivers delegate callbacks on the queue
/// from which it was instantiated. This provider is constructed on the
/// `@MainActor` (AppModel holds it as a stored property), so all delegate
/// callbacks come back on main. Don't move provider construction off main
/// without revisiting the closure dispatch below.
final class GPSLocationProvider: NSObject {
    private let manager = CLLocationManager()
    private var onUpdate: (@MainActor (CLLocation) -> Void)?
    private var onError: (@MainActor (Error) -> Void)?

    /// Maximum acceptable age of a fix in seconds. Older fixes are almost
    /// always cached locations from before the app started; ignoring them
    /// avoids a brief snap to "where you were yesterday" on launch.
    private let maxFixAgeSeconds: TimeInterval = 30
    /// Maximum acceptable horizontal accuracy in meters. Negative values
    /// from CL indicate an invalid fix.
    private let maxHorizontalAccuracyMeters: CLLocationAccuracy = 100

    override init() {
        super.init()
        manager.delegate = self
        // `.best` is ~10m accuracy and meaningfully cheaper than
        // `bestForNavigation`. The observer is stationary; aircraft are
        // kilometers away. Sub-meter precision is wasted battery.
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func start(
        onUpdate: @escaping @MainActor (CLLocation) -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        self.onUpdate = onUpdate
        self.onError = onError

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            Task { @MainActor in
                onError(GPSError.notAuthorized)
            }
        @unknown default:
            break
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        onUpdate = nil
        onError = nil
    }
}

extension GPSLocationProvider: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            let callback = onError
            Task { @MainActor in
                callback?(GPSError.notAuthorized)
            }
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        // Drop stale cached fixes (often the first thing CL delivers) and
        // anything with an invalid or coarse accuracy. The observer doesn't
        // need pinpoint precision but we'd rather wait for a real fix than
        // teleport to where the user was yesterday.
        let age = Date().timeIntervalSince(location.timestamp)
        guard age <= maxFixAgeSeconds else { return }
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= maxHorizontalAccuracyMeters
        else { return }

        let callback = onUpdate
        Task { @MainActor in
            callback?(location)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let callback = onError
        Task { @MainActor in
            callback?(error)
        }
    }
}

enum GPSError: LocalizedError {
    case notAuthorized

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Location permission required for GPS preset. Enable it in Settings."
        }
    }
}
