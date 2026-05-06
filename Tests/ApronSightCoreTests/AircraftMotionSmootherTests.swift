import XCTest
@testable import ApronSightCore

final class AircraftMotionSmootherTests: XCTestCase {
    func testPollCorrectionDoesNotJumpRenderedPositionImmediately() throws {
        var smoother = AircraftMotionSmoother(configuration: .test)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let t1 = t0.addingTimeInterval(1.0 / 90.0)
        let original = aircraft(id: "abc123", eastMeters: 0, speed: 80, track: 90)
        let corrected = aircraft(id: "abc123", eastMeters: 100, speed: 80, track: 90)

        _ = smoother.smooth([original], at: t0)
        let beforePoll = try XCTUnwrap(smoother.smooth([original], at: t1).first)
        let afterPoll = try XCTUnwrap(smoother.smooth([corrected], at: t1).first)

        let rawSnap = MotionPerceptionMetrics.horizontalDistanceMeters(
            from: original.coordinate,
            to: corrected.coordinate
        )
        let renderedSnap = MotionPerceptionMetrics.horizontalDistanceMeters(
            from: beforePoll.coordinate,
            to: afterPoll.coordinate
        )
        XCTAssertEqual(rawSnap, 100, accuracy: 0.1)
        XCTAssertLessThan(renderedSnap, 0.5)

        let later = try XCTUnwrap(smoother.smooth([corrected], at: t1.addingTimeInterval(1)).first)
        let laterError = MotionPerceptionMetrics.horizontalDistanceMeters(
            from: later.coordinate,
            to: corrected.coordinate
        )
        XCTAssertLessThan(laterError, 40)
    }

    func testSmoothingMetricsCaptureSnapAccuracyTradeoff() throws {
        var smoother = AircraftMotionSmoother(configuration: .test)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let original = aircraft(id: "abc123", eastMeters: 0)
        let corrected = aircraft(id: "abc123", eastMeters: 120)

        _ = smoother.smooth([original], at: date)
        let before = try XCTUnwrap(smoother.smooth([original], at: date).first)
        let after = try XCTUnwrap(smoother.smooth([corrected], at: date).first)

        let raw = try XCTUnwrap(MotionPerceptionMetrics.summarize([
            MotionPerceptionMetrics.Sample(
                before: original,
                after: corrected,
                target: corrected,
                observer: metricObserver
            )
        ]))
        let smoothed = try XCTUnwrap(MotionPerceptionMetrics.summarize([
            MotionPerceptionMetrics.Sample(
                before: before,
                after: after,
                target: corrected,
                observer: metricObserver
            )
        ]))

        XCTAssertEqual(raw.snapMeters.median, 120, accuracy: 0.1)
        XCTAssertEqual(raw.accuracyMeters.median, 0, accuracy: 0.1)
        XCTAssertLessThan(smoothed.snapMeters.median, 0.5)
        XCTAssertGreaterThan(smoothed.accuracyMeters.median, 100)
        XCTAssertNotNil(smoothed.angularSnapDegrees)
    }

    func testCorrectionConvergesWithoutOvershootingTarget() throws {
        var smoother = AircraftMotionSmoother(configuration: .test)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let target = aircraft(id: "abc123", eastMeters: 100)

        _ = smoother.smooth([aircraft(id: "abc123", eastMeters: 0)], at: t0)
        _ = smoother.smooth([target], at: t0)

        var previousError = Double.greatestFiniteMagnitude
        for step in 1 ... 180 {
            let date = t0.addingTimeInterval(Double(step) / 90.0)
            let rendered = try XCTUnwrap(smoother.smooth([target], at: date).first)
            let error = MotionPerceptionMetrics.horizontalDistanceMeters(
                from: rendered.coordinate,
                to: target.coordinate
            )
            XCTAssertLessThanOrEqual(error, previousError + 0.001)
            previousError = error
        }

        XCTAssertLessThan(previousError, 15)
    }

    func testLandingClampsVerticalPositionImmediately() throws {
        var smoother = AircraftMotionSmoother(configuration: .test)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let airborne = aircraft(id: "abc123", eastMeters: 0, altitudeMeters: 520, onGround: false)
        let landed = aircraft(id: "abc123", eastMeters: 30, altitudeMeters: observer.altitudeMeters, onGround: true)

        _ = smoother.smooth([airborne], at: date)
        let rendered = try XCTUnwrap(smoother.smooth([landed], at: date).first)

        XCTAssertEqual(rendered.coordinate.altitudeMeters, landed.coordinate.altitudeMeters, accuracy: 0.001)
        XCTAssertEqual(rendered.verticalRateMetersPerSecond ?? -1, 0)
    }

    func testTakeoffUsesAirborneTrackImmediately() throws {
        var smoother = AircraftMotionSmoother(configuration: .test)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let taxiing = aircraft(id: "abc123", eastMeters: 0, speed: 8, track: 95, onGround: true)
        let airborne = aircraft(id: "abc123", eastMeters: 60, altitudeMeters: 480, speed: 60, track: 275, onGround: false)

        _ = smoother.smooth([taxiing], at: date)
        let rendered = try XCTUnwrap(smoother.smooth([airborne], at: date).first)

        XCTAssertEqual(try XCTUnwrap(rendered.trueTrackDegrees), 275, accuracy: 0.001)
    }

    func testLowSpeedGroundTrafficDoesNotDriftFromReportedSpeed() throws {
        var smoother = AircraftMotionSmoother(configuration: .test)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let stopped = aircraft(id: "vehicle", eastMeters: 0, speed: 0.7, track: 20, onGround: true, trafficKind: .groundVehicle)

        let rendered = try XCTUnwrap(smoother.smooth([stopped], at: date).first)

        XCTAssertEqual(rendered.velocityMetersPerSecond, 0)
    }

    private let observer = GeoCoordinate(latitudeDegrees: 47.451210, longitudeDegrees: 8.557410, altitudeMeters: 432)
    private var metricObserver: GeoCoordinate {
        GeoMath.coordinate(offsetFrom: observer, eastMeters: -1_000, northMeters: 0, upMeters: 0)
    }

    private func aircraft(
        id: String,
        eastMeters: Double,
        altitudeMeters: Double = 432,
        speed: Double = 0,
        track: Double? = 90,
        onGround: Bool = false,
        trafficKind: TrafficKind = .aircraft
    ) -> Aircraft {
        Aircraft(
            id: id,
            callsign: id.uppercased(),
            coordinate: GeoMath.coordinate(
                offsetFrom: observer,
                eastMeters: eastMeters,
                northMeters: 0,
                upMeters: altitudeMeters - observer.altitudeMeters
            ),
            velocityMetersPerSecond: speed,
            trueTrackDegrees: track,
            verticalRateMetersPerSecond: onGround ? 0 : 5,
            isOnGround: onGround,
            trafficKind: trafficKind
        )
    }
}

private extension AircraftMotionSmoother.Configuration {
    static let test = AircraftMotionSmoother.Configuration(
        airbornePositionResponseSeconds: 1.0,
        surfacePositionResponseSeconds: 2.0,
        takeoffPositionResponseSeconds: 0.65,
        landingPositionResponseSeconds: 0.85,
        airborneTrackResponseSeconds: 0.75,
        surfaceTrackResponseSeconds: 1.5,
        takeoffTrackResponseSeconds: 0.35,
        landingTrackResponseSeconds: 0.9,
        maximumUpdateGapSeconds: 1.0,
        stationaryGroundSpeedThresholdMetersPerSecond: 2.0
    )
}
