import Foundation
import FlightFeed

// MARK: - CLI

struct DemoConfig {
    var latitude: Double = 47.4647
    var longitude: Double = 8.5492
    var radiusKm: Double = 50
    var pollInterval: TimeInterval = 10
    var iterations: Int? = 3
    var useMock = false
    var basicAuthUser: String?
    var basicAuthPassword: String?
    var oauthClientID: String?
    var oauthClientSecret: String?
}

func parseArgs() -> DemoConfig {
    var config = DemoConfig()
    var args = Array(CommandLine.arguments.dropFirst())
    while let arg = args.first {
        args.removeFirst()
        switch arg {
        case "--lat":
            config.latitude = Double(args.removeFirst()) ?? config.latitude
        case "--lon":
            config.longitude = Double(args.removeFirst()) ?? config.longitude
        case "--radius":
            config.radiusKm = Double(args.removeFirst()) ?? config.radiusKm
        case "--interval":
            config.pollInterval = Double(args.removeFirst()) ?? config.pollInterval
        case "--iterations":
            config.iterations = Int(args.removeFirst())
        case "--forever":
            config.iterations = nil
        case "--mock":
            config.useMock = true
        case "--user":
            config.basicAuthUser = args.removeFirst()
        case "--password":
            config.basicAuthPassword = args.removeFirst()
        case "--client-id":
            config.oauthClientID = args.removeFirst()
        case "--client-secret":
            config.oauthClientSecret = args.removeFirst()
        case "-h", "--help":
            printUsage()
            exit(0)
        default:
            FileHandle.standardError.write(Data("unknown argument: \(arg)\n".utf8))
            printUsage()
            exit(1)
        }
    }
    return config
}

func printUsage() {
    let usage = """
    flightfeed-demo — poll OpenSky for live flights in a radius

    USAGE:
      flightfeed-demo [options]

    OPTIONS:
      --lat <deg>            Centre latitude  (default 47.4647 — ZRH)
      --lon <deg>            Centre longitude (default 8.5492)
      --radius <km>          Radius in km     (default 50)
      --interval <seconds>   Poll cadence     (default 10)
      --iterations <n>       Stop after n snapshots (default 3)
      --forever              Poll until Ctrl-C
      --mock                 Use deterministic MockFlightProvider
      --user / --password    OpenSky basic auth (legacy)
      --client-id / --client-secret  OpenSky OAuth2 client credentials

    EXAMPLE:
      flightfeed-demo --lat 47.46 --lon 8.55 --radius 80 --interval 15

    """
    FileHandle.standardError.write(Data(usage.utf8))
}

func provider(for config: DemoConfig) -> any FlightProvider {
    if config.useMock {
        return MockFlightProvider(count: 8)
    }
    if let id = config.oauthClientID, let secret = config.oauthClientSecret {
        return OpenSkyClient.oauth(clientID: id, clientSecret: secret)
    }
    if let user = config.basicAuthUser, let password = config.basicAuthPassword {
        return OpenSkyClient.basicAuth(username: user, password: password)
    }
    return OpenSkyClient.anonymous()
}

func render(_ snapshot: FlightSnapshot) {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    formatter.timeZone = TimeZone(identifier: "UTC")
    print("\n── snapshot @ \(formatter.string(from: snapshot.capturedAt))Z — \(snapshot.flights.count) flight(s) inside \(Int(snapshot.region.radiusKm))km")
    let sorted = snapshot.flights.sorted { lhs, rhs in
        snapshot.region.distanceMeters(toLatitude: lhs.latitudeDegrees, longitude: lhs.longitudeDegrees)
            < snapshot.region.distanceMeters(toLatitude: rhs.latitudeDegrees, longitude: rhs.longitudeDegrees)
    }
    for f in sorted.prefix(20) {
        let altKm = f.altitudeMeters.map { String(format: "%5.1fkm", $0 / 1000) } ?? "   ?  "
        let speed = f.velocityMetersPerSecond.map { String(format: "%4.0fkt", $0 * 1.94384) } ?? "  ?kt"
        let track = f.trueTrackDegrees.map { String(format: "%3.0f°", $0) } ?? "  ?"
        let dist = snapshot.region.distanceMeters(toLatitude: f.latitudeDegrees, longitude: f.longitudeDegrees) / 1000
        let cs = f.callsign.isEmpty ? f.id : f.callsign
        print(String(
            format: "  %-8s  %@  %@  %@  d=%5.1fkm  (%.4f, %.4f)",
            (cs as NSString).utf8String!, altKm as NSString, speed as NSString, track as NSString,
            dist, f.latitudeDegrees, f.longitudeDegrees
        ))
    }
    if snapshot.flights.count > 20 {
        print("  … \(snapshot.flights.count - 20) more")
    }
}

@main
struct App {
    static func main() async {
        let config = parseArgs()
        let region = RadiusRegion(
            latitudeDegrees: config.latitude,
            longitudeDegrees: config.longitude,
            radiusKm: config.radiusKm
        )
        let p = provider(for: config)
        print("Polling \(type(of: p)) — centre (\(config.latitude), \(config.longitude)) radius \(Int(config.radiusKm))km every \(config.pollInterval)s")

        let feed = RadiusFlightFeed(
            provider: p,
            region: region,
            pollInterval: config.pollInterval
        ) { error in
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        }

        var seen = 0
        for await snapshot in feed.snapshots() {
            render(snapshot)
            seen += 1
            if let limit = config.iterations, seen >= limit { break }
        }
    }
}
