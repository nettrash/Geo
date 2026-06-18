//
//  SkylineGeometryTests.swift
//  GeoTests
//
//  Tests for the geometry the terrain-aware skyline relies on:
//  great-circle projection (forward), apparent altitude angle
//  (with Earth-curvature drop), and the "max-angle wins" picking
//  rule that turns elevation samples into a skyline.
//

import XCTest
import CoreLocation
@testable import Geo

final class SkylineGeometryTests: XCTestCase {

    // MARK: - Geodesic projection

    func testProjectNorthFromEquatorByOneDegree() {
        // 1° of latitude is ~111 km. Projecting that distance due
        // north from the equator should land at lat ≈ 1°, lon ≈ 0°.
        let origin = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let p = Geometry.project(from: origin, bearing: 0, distance: 111_320)
        XCTAssertEqual(p.latitude, 1.0, accuracy: 0.005)
        XCTAssertEqual(p.longitude, 0.0, accuracy: 0.005)
    }

    func testProjectEastFromEquator() {
        let origin = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let p = Geometry.project(from: origin, bearing: 90, distance: 111_320)
        XCTAssertEqual(p.latitude, 0.0, accuracy: 0.005)
        XCTAssertEqual(p.longitude, 1.0, accuracy: 0.005)
    }

    func testProjectShortDistanceMatchesFlatEarth() {
        // Over 1 km the spherical / flat-earth answers should agree
        // to within a few centimetres. Heading SE from a midlatitude
        // origin: dx ≈ d·sin(45°), dy ≈ d·cos(45°).
        let origin = CLLocationCoordinate2D(latitude: 47.6062, longitude: -122.3321)
        let p = Geometry.project(from: origin, bearing: 45, distance: 1_000)

        let expectedNorth = 1_000.0 * cos(45 * .pi / 180) // metres
        let actualNorth = (p.latitude - origin.latitude) * 111_320
        XCTAssertEqual(actualNorth, expectedNorth, accuracy: 1)
    }

    // MARK: - Apparent altitude angle

    func testApparentAngleAtSameAltitudeIsZero() {
        // 100 m away at the same altitude, ignoring curvature drop
        // (which is ~0.0008 m at 100 m), the apparent angle should be
        // very close to zero.
        let a = Geometry.apparentAltitudeAngle(observerAltitude: 100,
                                               targetAltitude: 100,
                                               distance: 100)
        XCTAssertEqual(a, 0, accuracy: 1e-4)
    }

    func testApparentAngleHigherTargetIsPositive() {
        // Mountain 1 km away, 500 m above me → arctan(0.5/1) ≈ 26.5°.
        // Curvature drop at 1 km is negligible (~0.08 m), so the
        // angle barely changes.
        let a = Geometry.apparentAltitudeAngle(observerAltitude: 0,
                                               targetAltitude: 500,
                                               distance: 1_000)
        XCTAssertEqual(a * 180 / .pi, 26.57, accuracy: 0.1)
    }

    func testApparentAngleAtGeometricHorizonIsTheDip() {
        // For an observer at altitude h, the geometric horizon (a sea-level
        // point at distance sqrt(2Rh)) does NOT sit at eye level — it appears
        // BELOW horizontal by the classic "dip of the horizon", ≈ −sqrt(2h/R).
        // You always look slightly DOWN to the sea horizon from any height.
        // (A previous version of this test asserted exactly 0; that dropped the
        // observer-height term and was geometrically wrong.)
        let h: Double = 100
        let R = Geometry.earthRadius
        let d = Geometry.horizonDistance(observerAltitude: h)
        let a = Geometry.apparentAltitudeAngle(observerAltitude: h,
                                               targetAltitude: 0,
                                               distance: d)
        XCTAssertEqual(a, -(2 * h / R).squareRoot(), accuracy: 1e-4)
        XCTAssertLessThan(a, 0)
    }

    func testApparentAngleBeyondHorizonIsNegative() {
        // A sea-level point past the geometric horizon should appear
        // *below* the observer's eye level — angle < 0.
        let h: Double = 100
        let d = Geometry.horizonDistance(observerAltitude: h) * 1.5
        let a = Geometry.apparentAltitudeAngle(observerAltitude: h,
                                               targetAltitude: 0,
                                               distance: d)
        XCTAssertLessThan(a, -1e-3)
    }

    // MARK: - Skyline picker (max-angle wins)

    /// The picker that lives inside `SkylineCalculator.computeSkyline`.
    /// Re-implemented here to keep the unit test independent of
    /// network-dependent code paths.
    private func pickSkyline(samples: [(distance: Double, altitude: Double)],
                             observerAltitude: Double)
        -> (distance: Double, altitude: Double)?
    {
        var best: (sample: (distance: Double, altitude: Double),
                   angle: Double)?
        for s in samples {
            let a = Geometry.apparentAltitudeAngle(
                observerAltitude: observerAltitude,
                targetAltitude: s.altitude,
                distance: s.distance
            )
            if best == nil || a > best!.angle {
                best = (s, a)
            }
        }
        return best?.sample
    }

    func testSkylinePicksMountainOverFlatTerrain() throws {
        // From sea level: a 1500 m peak 5 km away should easily beat
        // a 50 m hill 500 m away, AND the geometric horizon at 200
        // km, because its apparent angle is by far the largest.
        let samples: [(Double, Double)] = [
            (500, 50),
            (5_000, 1_500),
            (200_000, 0)
        ]
        let pick = try XCTUnwrap(pickSkyline(samples: samples, observerAltitude: 0))
        XCTAssertEqual(pick.distance, 5_000, accuracy: 1)
        XCTAssertEqual(pick.altitude, 1_500, accuracy: 1)
    }

    func testSkylinePicksGeometricHorizonOnFlatPlain() throws {
        // On a flat sea-level plain the silhouette IS the geometric horizon:
        // among sea-level samples, the one nearest the horizon distance has the
        // largest (least-negative, = the dip) apparent angle and wins. Closer
        // samples look steeply down (the −h/d term dominates); samples past the
        // horizon are hidden by the Earth's bulge and look lower again.
        // (A previous version expected the *closest* sample to win — backwards:
        // it ignored the observer-height term that makes near sea-level points
        // appear far below eye level.)
        let h: Double = 100
        let horizon = Geometry.horizonDistance(observerAltitude: h)
        let samples: [(Double, Double)] = [
            (1_000, 0),
            (horizon, 0),
            (200_000, 0)
        ]
        let pick = try XCTUnwrap(pickSkyline(samples: samples, observerAltitude: h))
        XCTAssertEqual(pick.distance, horizon, accuracy: 1)
    }

    func testSkylineIgnoresSubmergedSamples() throws {
        // A point well below sea level shouldn't beat a higher peak.
        let samples: [(Double, Double)] = [
            (5_000, -50),
            (5_000, 200)
        ]
        let pick = try XCTUnwrap(pickSkyline(samples: samples, observerAltitude: 0))
        XCTAssertEqual(pick.altitude, 200, accuracy: 1)
    }
}
