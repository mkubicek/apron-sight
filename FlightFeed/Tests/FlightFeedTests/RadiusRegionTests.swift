import XCTest
@testable import FlightFeed

final class RadiusRegionTests: XCTestCase {

    func testBoundingBoxAroundZurich() {
        let region = RadiusRegion(latitudeDegrees: 47.4647, longitudeDegrees: 8.5492, radiusKm: 50)
        let box = region.boundingBox

        XCTAssertEqual(box.latMax - box.latMin, 100.0 / 111.32, accuracy: 0.01,
                       "latitude span ≈ 2 * 50/111.32 deg")

        let lonSpan = box.lonMax - box.lonMin
        let expectedLonSpan = 2 * 50 / (111.32 * cos(47.4647 * .pi / 180))
        XCTAssertEqual(lonSpan, expectedLonSpan, accuracy: 0.01)

        XCTAssertGreaterThan(box.latMax, region.latitudeDegrees)
        XCTAssertLessThan(box.latMin, region.latitudeDegrees)
    }

    func testContainsTrueRadius() {
        let region = RadiusRegion(latitudeDegrees: 0, longitudeDegrees: 0, radiusKm: 100)
        // Point at exactly ~99 km north on the equator.
        XCTAssertTrue(region.contains(latitude: 99 / 111.32, longitude: 0))
        // Point at ~150 km north — outside.
        XCTAssertFalse(region.contains(latitude: 150 / 111.32, longitude: 0))
    }

    func testHaversineSymmetric() {
        let d1 = RadiusRegion.haversineMeters(lat1: 47.46, lon1: 8.55, lat2: 47.55, lon2: 8.66)
        let d2 = RadiusRegion.haversineMeters(lat1: 47.55, lon1: 8.66, lat2: 47.46, lon2: 8.55)
        XCTAssertEqual(d1, d2, accuracy: 1e-6)
        XCTAssertGreaterThan(d1, 10_000) // ~13km
        XCTAssertLessThan(d1, 20_000)
    }

    func testPolarBoundingBoxFullSweep() {
        let region = RadiusRegion(latitudeDegrees: 89.99, longitudeDegrees: 0, radiusKm: 50)
        let box = region.boundingBox
        XCTAssertEqual(box.lonMin, -180)
        XCTAssertEqual(box.lonMax, 180)
    }

    // MARK: - centerMoved hysteresis

    func testCenterMovedReturnsTrueWhenPreviousNil() {
        let region = RadiusRegion(latitudeDegrees: 47.45, longitudeDegrees: 8.55, radiusKm: 50)
        XCTAssertTrue(region.centerMoved(beyondMeters: 1_000, from: nil),
                      "First start has no previous region, must restart")
    }

    func testCenterMovedReturnsFalseForIdenticalCentre() {
        let region = RadiusRegion(latitudeDegrees: 47.45, longitudeDegrees: 8.55, radiusKm: 50)
        XCTAssertFalse(region.centerMoved(beyondMeters: 1_000, from: region))
    }

    func testCenterMovedReturnsFalseForSubThresholdShift() {
        // ~5 m shift in latitude (well under 1 km threshold).
        let previous = RadiusRegion(latitudeDegrees: 47.450000, longitudeDegrees: 8.55, radiusKm: 50)
        let next = RadiusRegion(latitudeDegrees: 47.450050, longitudeDegrees: 8.55, radiusKm: 50)
        XCTAssertFalse(next.centerMoved(beyondMeters: 1_000, from: previous),
                       "Sub-metre GPS jitter must not trigger feed restart")
    }

    func testCenterMovedReturnsTrueForSuperThresholdShift() {
        // ~10 km shift north — clearly above 1 km threshold.
        let previous = RadiusRegion(latitudeDegrees: 47.45, longitudeDegrees: 8.55, radiusKm: 50)
        let next = RadiusRegion(latitudeDegrees: 47.55, longitudeDegrees: 8.55, radiusKm: 50)
        XCTAssertTrue(next.centerMoved(beyondMeters: 1_000, from: previous))
    }

    func testCenterMovedAtThresholdBoundary() {
        // ~999 m shift — should NOT trigger; ~1100 m should.
        let previous = RadiusRegion(latitudeDegrees: 0, longitudeDegrees: 0, radiusKm: 50)
        let near = RadiusRegion(latitudeDegrees: 999.0 / 111_320.0, longitudeDegrees: 0, radiusKm: 50)
        let far = RadiusRegion(latitudeDegrees: 1100.0 / 111_320.0, longitudeDegrees: 0, radiusKm: 50)
        XCTAssertFalse(near.centerMoved(beyondMeters: 1_000, from: previous))
        XCTAssertTrue(far.centerMoved(beyondMeters: 1_000, from: previous))
    }
}
