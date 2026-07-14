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
import CoreGraphics
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

    // MARK: - Refraction

    func testEffectiveRadiusFoldsInStandardRefraction() {
        // R_eff = R / (1 − k) with k = 0.13 → ~7 323 km.
        XCTAssertEqual(Geometry.effectiveEarthRadius,
                       Geometry.earthRadius / (1 - 0.13),
                       accuracy: 1)
        XCTAssertGreaterThan(Geometry.effectiveEarthRadius, Geometry.earthRadius)
    }

    func testRefractionLiftsDistantTerrain() {
        // A 2 800 m ridge 185 km from an observer at 200 m sits below
        // the pure-geometry sightline (curvature drop ~2 686 m) but is
        // genuinely visible in standard atmosphere (refracted drop
        // ~2 337 m). The skyline must be computed with the refracted
        // radius or ranges like this vanish from the silhouette.
        let geometric = Geometry.apparentAltitudeAngle(
            observerAltitude: 200, targetAltitude: 2_800, distance: 185_000)
        let refracted = Geometry.apparentAltitudeAngle(
            observerAltitude: 200, targetAltitude: 2_800, distance: 185_000,
            radius: Geometry.effectiveEarthRadius)
        XCTAssertLessThan(geometric, 0)
        XCTAssertGreaterThan(refracted, 0)
    }

    // MARK: - Adaptive bearing refinement (pair selection)

    func testAdaptiveBearingsPicksAngleJumpPair() {
        // Flat silhouette except a 2° apparent-angle cliff between the
        // samples at 10° and 12° → exactly one midpoint, at 11°.
        var samples: [(bearing: Double, angleDeg: Double, distance: Double)] = []
        for b in stride(from: 0.0, through: 20.0, by: 2.0) {
            samples.append((bearing: b, angleDeg: b >= 12 ? 3.0 : 1.0, distance: 10_000))
        }
        let mids = SkylineCalculator.adaptiveRefinementBearings(samples: samples)
        XCTAssertEqual(mids, [11.0])
    }

    func testAdaptiveBearingsPicksDistanceRatioPair() {
        // Same apparent angle everywhere, but the winning distance jumps
        // 5 km → 40 km between 100° and 102° (a near/far transition the
        // angle threshold alone can miss) → midpoint at 101°.
        var samples: [(bearing: Double, angleDeg: Double, distance: Double)] = []
        for b in stride(from: 90.0, through: 110.0, by: 2.0) {
            samples.append((bearing: b, angleDeg: 1.0, distance: b >= 102 ? 40_000 : 5_000))
        }
        let mids = SkylineCalculator.adaptiveRefinementBearings(samples: samples)
        XCTAssertEqual(mids, [101.0])
    }

    func testAdaptiveBearingsRespectsCapAndKeepsWorstPairs() {
        // Quadratically growing angles: every adjacent jump past i = 4
        // exceeds the 0.8° threshold and the jumps grow with bearing, so a
        // cap of 5 must keep exactly the five LARGEST discontinuities —
        // the midpoints of the last five pairs.
        var samples: [(bearing: Double, angleDeg: Double, distance: Double)] = []
        for i in 0..<30 {
            samples.append((bearing: Double(2 * i),
                            angleDeg: 0.1 * Double(i * i),
                            distance: 10_000))
        }
        let mids = SkylineCalculator.adaptiveRefinementBearings(samples: samples, maxExtra: 5)
        XCTAssertEqual(mids.count, 5)
        XCTAssertEqual(Set(mids), Set([49.0, 51.0, 53.0, 55.0, 57.0]))
        // Worst first: severity ordering puts the biggest jump (58°↔... pair
        // midpoint 57°) at the front.
        XCTAssertEqual(mids.first, 57.0)
    }

    func testAdaptiveBearingsDetectsWrapPair() {
        // The 358°↔2° adjacency wraps through north: its midpoint is 0°.
        // The sample at 2° also jumps against its 6° neighbour → mid 4°.
        let samples: [(bearing: Double, angleDeg: Double, distance: Double)] = [
            (bearing: 2, angleDeg: 5.0, distance: 10_000),
            (bearing: 6, angleDeg: 1.0, distance: 10_000),
            (bearing: 350, angleDeg: 1.0, distance: 10_000),
            (bearing: 354, angleDeg: 1.0, distance: 10_000),
            (bearing: 358, angleDeg: 1.0, distance: 10_000)
        ]
        let mids = SkylineCalculator.adaptiveRefinementBearings(samples: samples)
        XCTAssertTrue(mids.contains(0.0), "wrap pair 358°↔2° must yield midpoint 0°, got \(mids)")
        XCTAssertTrue(mids.contains(4.0))
        XCTAssertEqual(mids.count, 2, "the 6°↔350° gap is too wide to subdivide")
    }

    // MARK: - Welded-anchor screen interpolation

    func testWeldedAnchorScreenPointFraction() {
        // Query 25 % of the way from lo (10°) to hi (12°) → quarter point
        // of the screen segment.
        let p = weldedAnchorScreenPoint(bearing: 10.5,
                                        loBearing: 10, hiBearing: 12,
                                        loScreen: CGPoint(x: 100, y: 200),
                                        hiScreen: CGPoint(x: 200, y: 240))
        XCTAssertEqual(p.x, 125, accuracy: 1e-9)
        XCTAssertEqual(p.y, 210, accuracy: 1e-9)
    }

    func testWeldedAnchorScreenPointLandsOnSegment() {
        // For any bearing inside the bracket the anchor must be collinear
        // with — and between — the two projected sample points; that's what
        // guarantees the pill's dot sits exactly on the drawn polyline.
        let lo = CGPoint(x: 40, y: 300)
        let hi = CGPoint(x: 220, y: 180)
        for q in stride(from: 100.0, through: 104.0, by: 0.5) {
            let p = weldedAnchorScreenPoint(bearing: q,
                                            loBearing: 100, hiBearing: 104,
                                            loScreen: lo, hiScreen: hi)
            // Collinear: cross product of (p−lo) × (hi−lo) is zero.
            let cross = (p.x - lo.x) * (hi.y - lo.y) - (p.y - lo.y) * (hi.x - lo.x)
            XCTAssertEqual(Double(cross), 0, accuracy: 1e-6)
            XCTAssertGreaterThanOrEqual(p.x, lo.x)
            XCTAssertLessThanOrEqual(p.x, hi.x)
        }
        // Degenerate zero-span bracket returns the lo point.
        let z = weldedAnchorScreenPoint(bearing: 100, loBearing: 100, hiBearing: 100,
                                        loScreen: lo, hiScreen: hi)
        XCTAssertEqual(z, lo)
    }

    func testWeldedAnchorScreenPointWrapCase() {
        // Bracket spans the 0° seam: lo 354°, hi 0° (span 6°), query 358°
        // → 4/6 of the way along the screen segment.
        let p = weldedAnchorScreenPoint(bearing: 358,
                                        loBearing: 354, hiBearing: 0,
                                        loScreen: CGPoint(x: 0, y: 0),
                                        hiScreen: CGPoint(x: 60, y: 30))
        XCTAssertEqual(p.x, 40, accuracy: 1e-9)
        XCTAssertEqual(p.y, 20, accuracy: 1e-9)
    }

    // MARK: - Importance-based peak-label selection

    func testPeakLabelScoreBigDistantSummitBeatsSmallNearBump() {
        // The regression the score fixes: nearest-first labelled a 400 m
        // bump 3 km away over a 4 000 m summit 30 km away. With
        // altitude − 8 m/km the summit wins by an order of magnitude.
        let summit = peakLabelScore(altitude: 4_000, distance: 30_000)
        let bump = peakLabelScore(altitude: 400, distance: 3_000)
        XCTAssertEqual(summit, 3_760, accuracy: 1e-9)
        XCTAssertEqual(bump, 376, accuracy: 1e-9)
        XCTAssertGreaterThan(summit, bump)
    }

    func testPeakLabelScoreBetweenEqualSummitsNearerWins() {
        // Same altitude → the distance penalty is the tie-breaker, so the
        // nearer of two similar summits keeps its slot.
        let near = peakLabelScore(altitude: 1_000, distance: 5_000)
        let far = peakLabelScore(altitude: 1_000, distance: 20_000)
        XCTAssertGreaterThan(near, far)
    }

    func testSelectWeldedPeakLabelsRespectsCapAndSpacingInScoreOrder() {
        func label(_ name: String, x: CGFloat) -> PeakHorizonLabel {
            PeakHorizonLabel(peakID: UUID(), name: name, altitude: 1_000,
                             position: CGPoint(x: x, y: 100))
        }
        // Three candidates within one 54 pt spacing slot: the HIGHEST score
        // must win it (not insertion order, not the nearest), and the two
        // losers are dropped; a fourth candidate far enough away survives.
        let crowdedWinner = label("big", x: 100)
        let crowdedLoserA = label("smallA", x: 110)
        let crowdedLoserB = label("smallB", x: 130)
        let separate = label("separate", x: 400)
        let kept = selectWeldedPeakLabels(
            candidates: [
                (label: crowdedLoserA, score: 500),
                (label: crowdedWinner, score: 4_000),
                (label: crowdedLoserB, score: 900),
                (label: separate, score: 100)
            ],
            minSpacing: 54, maxCount: 16)
        XCTAssertEqual(kept.map { $0.name }, ["big", "separate"])

        // Cap respected — and it keeps the TOP-scored labels when all are
        // spaced far enough apart to qualify.
        let many = (0..<10).map { i in
            (label: label("p\(i)", x: CGFloat(i) * 100), score: Double(i))
        }
        let capped = selectWeldedPeakLabels(candidates: many, minSpacing: 54, maxCount: 3)
        XCTAssertEqual(capped.count, 3)
        XCTAssertEqual(Set(capped.map { $0.name }), Set(["p9", "p8", "p7"]))
    }

    // MARK: - Distance schedule density

    func testSkylineDistanceScheduleHasNoRidgeSwallowingGaps() {
        // The silhouette can only ever be as good as the sampling: any
        // consecutive pair with a big ratio is a distance band whose
        // terrain is invisible to the picker. Pin the schedule to a
        // ≤1.16× ratio at every step (≈ ±7 % miss window after the
        // refinement round halves it), full coverage 100 m → 200 km,
        // strictly increasing, and a bounded query budget.
        let ds = SkylineCalculator.skylineDistancesMeters
        XCTAssertEqual(ds.first, 100)
        XCTAssertEqual(ds.last, SkylineCalculator.skylineMaxRangeMeters)
        XCTAssertLessThan(ds.count, 60, "schedule ballooning would blow the per-pass query budget")
        for i in 1..<ds.count {
            XCTAssertGreaterThan(ds[i], ds[i - 1], "schedule must be strictly increasing")
            if ds[i - 1] >= 1_000 {
                XCTAssertLessThanOrEqual(ds[i] / ds[i - 1], 1.16,
                                         "gap between \(ds[i - 1]) and \(ds[i]) can swallow a ridge")
            } else {
                XCTAssertLessThanOrEqual(ds[i] - ds[i - 1], 250,
                                         "close-in sampling must stay ~200 m")
            }
        }
    }
}
