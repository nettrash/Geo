//
//  GeomagneticTests.swift
//  GeoTests
//
//  Fixture tables for the Magnetic Conditions core. Every table here is
//  duplicated verbatim in Android `GeomagneticTest.kt`, so a divergence in
//  either platform's math fails on that platform and nowhere else.
//
//  The numbers are not invented: the magnetic-latitude fixtures were checked
//  against `aacgmv2` 2.7.1 while `tools/gen_mlat_delta.py` was written, the
//  oval numbers come from the NOAA SWPC aurora tutorial, and the ap table is
//  the published Kp-to-ap conversion. Do not "tidy" a constant to make a test
//  pass — the test is the constant's proof.
//
//  The SWPC parse contract and the cache round-trip live with the service
//  that owns them — `SpaceWeatherServiceTests` — not here; this file is the
//  pure core only.
//

import XCTest
import CryptoKit
import CoreLocation
@testable import Geo

final class GeomagneticTests: XCTestCase {

    /// Fixed clock, shared with the Android fixtures (nowMs 1_700_000_000_000).
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// UTC, always injected — a test that reads the device's calendar passes
    /// in Cupertino and fails in Auckland.
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    // MARK: - Grid loading

    /// The shipped correction grid. It is a resource of the app target, so it
    /// resolves from the test bundle when the test target carries a copy and
    /// from the host app otherwise. A miss is a hard failure, never a skip:
    /// the whole feature is wrong without this file.
    private func gridData() throws -> Data {
        let name = MLatDeltaGrid.resourceName
        let ext = MLatDeltaGrid.resourceExtension
        let url = Bundle(for: GeomagneticTests.self).url(forResource: name, withExtension: ext)
               ?? Bundle.main.url(forResource: name, withExtension: ext)
        return try Data(contentsOf: XCTUnwrap(url, "\(name).\(ext) is in neither the test nor the app bundle"))
    }

    private func loadGrid() throws -> MLatDeltaGrid {
        try XCTUnwrap(MLatDeltaGrid.decode(gridData()))
    }

    // MARK: - Dipole

    func testDipoleDegenerateCases() {
        // At the pole itself the magnetic latitude is 90 by construction; at
        // the geographic north pole it is the pole latitude; on the equator
        // under the pole's meridian it is the dipole tilt (9.1698°, which
        // agrees with NCEI's published WMM2025 pole to about 0.04° — that is
        // the claim, not "three decimals").
        XCTAssertEqual(Geomagnetic.dipoleMagneticLatitude(latitude: Geomagnetic.dipolePoleLatDeg,
                                                          longitude: Geomagnetic.dipolePoleLonDeg),
                       90.0, accuracy: 1e-3)
        XCTAssertEqual(Geomagnetic.dipoleMagneticLatitude(latitude: 90, longitude: 0),
                       Geomagnetic.dipolePoleLatDeg, accuracy: 1e-3)
        XCTAssertEqual(Geomagnetic.dipoleMagneticLatitude(latitude: 0,
                                                          longitude: Geomagnetic.dipolePoleLonDeg),
                       9.1698, accuracy: 1e-3)
    }

    func testRawDipoleMagneticLatitudes() {
        // The UNCORRECTED dipole, pinned so the grid test below is measuring
        // the correction and not a drifting baseline.
        let fixtures: [(String, Double, Double, Double)] = [
            ("Tromso", 69.6492, 18.9553, 67.50), ("Reykjavik", 64.1466, -21.9426, 68.79),
            ("Fairbanks", 64.8378, -147.7164, 65.67), ("Edmonton", 53.5461, -113.4938, 59.98),
            ("Moscow", 55.7558, 37.6173, 51.70), ("London", 51.5074, -0.1278, 53.34),
            ("Berlin", 52.5200, 13.4050, 52.17), ("Seattle", 47.6062, -122.3321, 53.02),
            ("Chicago", 41.8781, -87.6298, 50.69), ("Hobart", -42.8821, 147.3272, -49.56)
        ]
        for (name, lat, lon, expected) in fixtures {
            XCTAssertEqual(Geomagnetic.dipoleMagneticLatitude(latitude: lat, longitude: lon),
                           expected, accuracy: 1e-2, name)
        }
    }

    func testDipoleMagneticLongitudeOnThePoleMeridian() {
        // The pole's own meridian is magnetic longitude 180 at the equator and
        // the antimeridian of it is 0 — the only two values the formula can be
        // pinned to without a second model to compare against.
        XCTAssertEqual(abs(Geomagnetic.dipoleMagneticLongitude(latitude: 0,
                                                               longitude: Geomagnetic.dipolePoleLonDeg)),
                       180.0, accuracy: 1e-6)
        XCTAssertEqual(Geomagnetic.dipoleMagneticLongitude(latitude: 0,
                                                           longitude: Geomagnetic.dipolePoleLonDeg + 180),
                       0.0, accuracy: 1e-6)
    }

    // MARK: - Correction grid

    func testGridResourceHashIsPinned() throws {
        // The asset is generated, not hand-edited. If this hash moves, either
        // `tools/gen_mlat_delta.py` was re-run (then re-pin it in BOTH test
        // files) or the file was corrupted in transit.
        let digest = SHA256.hash(data: try gridData()).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "270ce131ed654c14fc686f2ed072f9291889f5874a5f4199ab5829e7a73a85ed")
        XCTAssertEqual(try gridData().count, Geomagnetic.mlatGridByteCount)
    }

    func testGridDecodeRejectsWrongByteCounts() {
        // One byte either way and every node after the damage shifts a column.
        // Refusing to decode costs the aurora row; decoding anyway would show
        // a confidently wrong verdict.
        XCTAssertNil(MLatDeltaGrid.decode(Data(repeating: 0, count: 4679)))
        XCTAssertNil(MLatDeltaGrid.decode(Data(repeating: 0, count: 4681)))
        XCTAssertNotNil(MLatDeltaGrid.decode(Data(repeating: 0, count: 4680)))
    }

    func testGridLongitudeWrapsAtTheAntimeridian() throws {
        // Exactly equal, not approximately: −180 and +180 are the same column.
        let grid = try loadGrid()
        for lat in [-70.0, -40, 0, 40, 55, 70] {
            XCTAssertEqual(grid.delta(latitude: lat, longitude: -180),
                           grid.delta(latitude: lat, longitude: 180), "\(lat)")
        }
    }

    func testGridNodeLookupReturnsTheStoredValue() throws {
        // Row 54 / column 40 is 55 °N 20 °E. Landing exactly on a node must
        // return that node, which pins the row-major index order.
        let grid = try loadGrid()
        let stored = Double(grid.raw[54 * Geomagnetic.mlatGridCols + 40]) * Geomagnetic.mlatGridScaleDeg
        XCTAssertEqual(grid.delta(latitude: 55, longitude: 20), stored, accuracy: 1e-9)
    }

    func testGridMidpointIsTheMeanOfItsNodes() throws {
        // Bilinear, so the halfway point between two nodes is their mean in
        // both axes. A nearest-neighbour or transposed lookup fails here.
        let grid = try loadGrid()
        let south = grid.delta(latitude: 55, longitude: 20)
        let north = grid.delta(latitude: 57.5, longitude: 20)
        let east = grid.delta(latitude: 55, longitude: 25)
        XCTAssertEqual(grid.delta(latitude: 56.25, longitude: 20), (south + north) / 2, accuracy: 1e-9)
        XCTAssertEqual(grid.delta(latitude: 55, longitude: 22.5), (south + east) / 2, accuracy: 1e-9)
    }

    func testGridIsExactlyZeroInsideTheLowLatitudeTaper() throws {
        // AACGM-v2 is undefined near the magnetic equator, so the correction
        // is tapered to zero there and the app shows plain dipole latitude.
        // It costs nothing: the oval never reaches |mlat| 35 at any Kp.
        let grid = try loadGrid()
        XCTAssertEqual(grid.delta(latitude: 0, longitude: 0), 0.0)
        XCTAssertEqual(grid.delta(latitude: 10, longitude: 60), 0.0)
        XCTAssertEqual(grid.delta(latitude: -20, longitude: -150), 0.0)
    }

    func testGridDeltaIsZeroForANonFiniteFix() throws {
        // A NaN out of a wedged location provider must never reach the
        // interpolation: `Int(Double.nan)` TRAPS in Swift, so this is a crash
        // on iOS and a NaN correction — hence a NaN magnetic latitude and a
        // blank verdict — on Android. Both hand back a flat zero instead.
        let grid = try loadGrid()
        XCTAssertEqual(grid.delta(latitude: .nan, longitude: 20), 0.0)
        XCTAssertEqual(grid.delta(latitude: 55, longitude: .nan), 0.0)
        XCTAssertEqual(grid.delta(latitude: .infinity, longitude: .infinity), 0.0)
    }

    func testGridsAreEqualExactlyWhenTheirNodesAre() throws {
        // Value equality over the whole table, which is what lets the card
        // diff its state and skip a redraw. Both halves matter: an identity
        // comparison would call two decodes of the same asset different, and
        // an == that only checked the byte COUNT would call a corrupted grid
        // the same as the shipped one and silently keep the wrong correction.
        let data = try gridData()
        XCTAssertEqual(MLatDeltaGrid.decode(data), MLatDeltaGrid.decode(data))

        var mutated = try loadGrid().raw
        mutated[54 * Geomagnetic.mlatGridCols + 40] &+= 1   // 55 °N 20 °E, one tenth of a degree
        XCTAssertEqual(mutated.count, try loadGrid().raw.count)
        XCTAssertNotEqual(try loadGrid(), MLatDeltaGrid(raw: mutated))
    }

    func testCorrectedMagneticLatitudeReachesAACGM() throws {
        // Dipole + grid against `aacgmv2` at 110 km, epoch 2026.0. The worst
        // grid error observed while generating the asset was 0.066°; the 0.5°
        // budget here is a quarter of a Kp step.
        let grid = try loadGrid()
        let fixtures: [(String, Double, Double, Double)] = [
            ("London", 51.5074, -0.1278, 47.71), ("Lancaster", 54.0466, -2.8007, 50.86),
            ("Edinburgh", 55.9533, -3.1883, 53.14), ("Reykjavik", 64.1466, -21.9426, 64.21),
            ("Berlin", 52.5200, 13.4050, 48.83), ("Oslo", 59.9139, 10.7522, 57.15),
            ("Yekaterinburg", 56.8389, 60.6057, 54.01), ("Moscow", 55.7558, 37.6173, 52.70),
            ("Helsinki", 60.1699, 24.9384, 57.23), ("Tromso", 69.6492, 18.9553, 67.25),
            ("Fairbanks", 64.8378, -147.7164, 65.19), ("Edmonton", 53.5461, -113.4938, 60.20),
            ("Seattle", 47.6062, -122.3321, 52.88), ("Chicago", 41.8781, -87.6298, 51.36),
            ("Hobart", -42.8821, 147.3272, -53.72)
        ]
        for (name, lat, lon, expected) in fixtures {
            XCTAssertEqual(Geomagnetic.magneticLatitude(latitude: lat, longitude: lon, grid: grid),
                           expected, accuracy: 0.5, name)
        }
    }

    // MARK: - The London regression (the load-bearing test)

    func testLondonRegression() throws {
        // The reason the grid is in the bundle at all. At Kp 7 the oval edge
        // is 52.1892 magnetic. The raw dipole puts London at 53.34 — inside
        // the oval, margin +1.15, "the oval reaches you" — and that is wrong
        // by 2.5 whole Kp steps. AACGM puts it at 47.69, margin −4.50, a
        // horizon glow at best.
        //
        // Both halves are asserted on purpose: if the grid is ever removed,
        // zeroed or silently bypassed, the second half fails and says why.
        let grid = try loadGrid()
        let kp = 7.0
        XCTAssertEqual(Geomagnetic.ovalEdgeMLat(kp: kp), 52.1892, accuracy: 1e-4)

        let corrected = Geomagnetic.magneticLatitude(latitude: 51.5074, longitude: -0.1278, grid: grid)
        XCTAssertEqual(Geomagnetic.margin(magneticLatitudeDeg: corrected, kp: kp), -4.50, accuracy: 0.05)
        XCTAssertEqual(Geomagnetic.visibility(magneticLatitudeDeg: corrected, kp: kp), .horizonGlow)

        let dipole = Geomagnetic.dipoleMagneticLatitude(latitude: 51.5074, longitude: -0.1278)
        XCTAssertEqual(Geomagnetic.margin(magneticLatitudeDeg: dipole, kp: kp), 1.15, accuracy: 0.05)
        XCTAssertEqual(Geomagnetic.visibility(magneticLatitudeDeg: dipole, kp: kp), .ovalReaches)
        XCTAssertNotEqual(Geomagnetic.visibility(magneticLatitudeDeg: dipole, kp: kp),
                          Geomagnetic.visibility(magneticLatitudeDeg: corrected, kp: kp),
                          "the raw dipole must not agree with the corrected verdict here")
    }

    func testHobartSouthernRegression() throws {
        // The mirror image: south of the equator the dipole UNDER-promises,
        // and the abs() in `margin` is what makes one rule cover both
        // hemispheres. Corrected −53.70 is inside the Kp 7 oval; the raw
        // dipole −49.56 is not.
        let grid = try loadGrid()
        let kp = 7.0
        let corrected = Geomagnetic.magneticLatitude(latitude: -42.8821, longitude: 147.3272, grid: grid)
        let dipole = Geomagnetic.dipoleMagneticLatitude(latitude: -42.8821, longitude: 147.3272)
        XCTAssertEqual(Geomagnetic.visibility(magneticLatitudeDeg: corrected, kp: kp), .ovalReaches)
        XCTAssertEqual(Geomagnetic.visibility(magneticLatitudeDeg: dipole, kp: kp), .horizonGlow)
    }

    // MARK: - Auroral oval

    func testOvalEdgeByKp() {
        let expected: [(Double, Double)] = [(0, 66.5000), (1, 64.4556), (3, 60.3668),
                                            (5, 56.2780), (7, 52.1892), (9, 48.1004)]
        for (kp, edge) in expected {
            XCTAssertEqual(Geomagnetic.ovalEdgeMLat(kp: kp), edge, accuracy: 0.01, "Kp \(kp)")
        }
    }

    func testG5EdgeBracketsNOAAsOwnFigure() {
        // Cross-source check: our Kp 9 edge minus the horizon reach lands on
        // NOAA's published G5 statement of "40° geomagnetic latitude". Two
        // independently chosen constants meeting a third figure to 0.2° is
        // the only external validation this model gets.
        let reach = Geomagnetic.ovalEdgeMLat(kp: 9) - Geomagnetic.horizonReachDeg
        XCTAssertEqual(reach, 40.0, accuracy: 0.2)
    }

    func testVisibilityBands() {
        XCTAssertEqual(Geomagnetic.visibility(marginDeg: 5), .overhead)
        XCTAssertEqual(Geomagnetic.visibility(marginDeg: 2), .overhead)      // inclusive edge
        XCTAssertEqual(Geomagnetic.visibility(marginDeg: 1.99), .ovalReaches)
        XCTAssertEqual(Geomagnetic.visibility(marginDeg: 0), .ovalReaches)   // inclusive edge
        XCTAssertEqual(Geomagnetic.visibility(marginDeg: -0.01), .horizonGlow)
        XCTAssertEqual(Geomagnetic.visibility(marginDeg: -8), .horizonGlow)  // inclusive edge
        XCTAssertEqual(Geomagnetic.visibility(marginDeg: -8.01), .notVisible)
    }

    func testRangeKmFromMargin() {
        XCTAssertEqual(Geomagnetic.rangeKm(marginDeg: -4.5), 500.4, accuracy: 0.5)
        XCTAssertEqual(Geomagnetic.rangeKm(marginDeg: 4.5), 500.4, accuracy: 0.5)  // sign-free
    }

    func testRequiredKpRoundsUpToTheNextThird() {
        // London's raw requirement is 5.2778, which MUST round UP to 5.333.
        // Rounding down would promise an aurora the oval cannot deliver at
        // that Kp, which is the one direction this can be wrong in.
        XCTAssertEqual(try XCTUnwrap(Geomagnetic.kpNeededForHorizonGlow(magneticLatitudeDeg: 47.71)),
                       5.333, accuracy: 1e-3)
        XCTAssertEqual(try XCTUnwrap(Geomagnetic.kpNeededForHorizonGlow(magneticLatitudeDeg: 48.83)),
                       5.000, accuracy: 1e-3)
        XCTAssertEqual(try XCTUnwrap(Geomagnetic.kpNeededForHorizonGlow(magneticLatitudeDeg: 51.36)),
                       3.667, accuracy: 1e-3)
        XCTAssertEqual(try XCTUnwrap(Geomagnetic.kpNeededForHorizonGlow(magneticLatitudeDeg: 52.70)),
                       3.000, accuracy: 1e-3)
        XCTAssertEqual(try XCTUnwrap(Geomagnetic.kpNeededForHorizonGlow(magneticLatitudeDeg: 67.25)),
                       0.0, accuracy: 1e-9)
        // 35° magnetic would need Kp 11.4948. There is no such Kp.
        XCTAssertNil(Geomagnetic.kpNeededForHorizonGlow(magneticLatitudeDeg: 35.0))
    }

    func testRequiredKpForLondonRoundsUpNotDown() throws {
        // London's exact requirement is Kp 5.2778. Rounding to the NEAREST
        // third gives 5.333 as well, so that alone proves nothing; rounding
        // DOWN gives 5.0, a threshold the oval does not actually reach. Only
        // the up-rounding is pinned here, from both sides.
        let needed = try XCTUnwrap(Geomagnetic.kpNeededForHorizonGlow(magneticLatitudeDeg: 47.71))
        XCTAssertEqual(needed, 5.333, accuracy: 1e-3)
        XCTAssertGreaterThan(needed, 5.2778)
        XCTAssertNotEqual(needed, 5.0, accuracy: 1e-9)
    }

    func testRequiredKpLabelsAreThirdsNeverDecimals() {
        XCTAssertEqual(Geomagnetic.requiredKpLabel(magneticLatitudeDeg: 47.71), "about Kp 5+")
        XCTAssertEqual(Geomagnetic.requiredKpLabel(magneticLatitudeDeg: 48.83), "about Kp 5")
        XCTAssertEqual(Geomagnetic.requiredKpLabel(magneticLatitudeDeg: 51.36), "about Kp 4-")
        XCTAssertEqual(Geomagnetic.requiredKpLabel(magneticLatitudeDeg: 52.70), "about Kp 3")
        XCTAssertEqual(Geomagnetic.requiredKpLabel(magneticLatitudeDeg: 67.25), "any night")
        XCTAssertNil(Geomagnetic.requiredKpLabel(magneticLatitudeDeg: 35.0))
    }

    func testRequiredKpIsTheLowestKpThatShowsAnything() throws {
        // The threshold has to be tight from both sides: at exactly k the spot
        // is no longer `notVisible`, and a third of a step below it (0.34, so
        // the probe clears the rounding) it still is. Tromso is excluded by
        // construction — its threshold is 0, and no Kp is low enough to put
        // the oval above it.
        for mlat in [47.71, 48.83, 51.36, 52.70] {
            let k = try XCTUnwrap(Geomagnetic.kpNeededForHorizonGlow(magneticLatitudeDeg: mlat))
            XCTAssertNotEqual(Geomagnetic.visibility(magneticLatitudeDeg: mlat, kp: k), .notVisible, "\(mlat)")
            XCTAssertEqual(Geomagnetic.visibility(magneticLatitudeDeg: mlat, kp: k - 0.34), .notVisible, "\(mlat)")
        }
    }

    // MARK: - Kp, ap and the G scale

    func testGScaleIsAFloorOnTheIntegerStep() {
        XCTAssertEqual(Geomagnetic.gScale(kp: 4.667), .g0)
        XCTAssertEqual(Geomagnetic.gScale(kp: 5.0), .g1)
        XCTAssertEqual(Geomagnetic.gScale(kp: 5.667), .g1)
        XCTAssertEqual(Geomagnetic.gScale(kp: 6.0), .g2)
        XCTAssertEqual(Geomagnetic.gScale(kp: 7.0), .g3)
        XCTAssertEqual(Geomagnetic.gScale(kp: 7.667), .g3)
        XCTAssertEqual(Geomagnetic.gScale(kp: 8.0), .g4)
        XCTAssertEqual(Geomagnetic.gScale(kp: 9.0), .g5)
    }

    func testKpNineMinusIsG4NotG5() {
        // 8.667 is "9−", one third BELOW Kp 9, so it is a G4 storm.
        // `round(8.667) == 9` is the bug this test exists to catch: it would
        // promote every 9− forecast to "extreme" and, with it, the whole
        // severity of the card's copy.
        XCTAssertEqual(Geomagnetic.gScale(kp: 8.667), .g4)
        XCTAssertNotEqual(Geomagnetic.gScale(kp: 8.667), .g5)
        XCTAssertEqual(Geomagnetic.kpThirdsLabel(8.667), "9-")
    }

    func testKpThirdsLabels() {
        let expected: [(Double, String)] = [(0.0, "0"), (0.333, "0+"), (0.667, "1-"), (1.0, "1"),
                                            (4.667, "5-"), (5.333, "5+"), (8.667, "9-"), (9.0, "9")]
        for (kp, label) in expected {
            XCTAssertEqual(Geomagnetic.kpThirdsLabel(kp), label, "\(kp)")
        }
    }

    func testApTableShape() {
        // 28 steps, 0 through 9 in thirds. Strictly monotonic, and there is no
        // `9+`: Kp stops at 9, so the table stops at ap 400. The step clamps at
        // both ends, so nothing off the scale can index off the table either.
        // A non-finite Kp is not a Kp at all and clamps onto the first step:
        // without that guard `Int(Double.nan)` TRAPS here on iOS, so a single
        // corrupt cached row would take the app down rather than the row.
        XCTAssertEqual(Geomagnetic.apTable.count, 28)
        for i in 1..<Geomagnetic.apTable.count {
            XCTAssertGreaterThan(Geomagnetic.apTable[i], Geomagnetic.apTable[i - 1], "step \(i)")
        }
        XCTAssertEqual(Geomagnetic.kpStep(9.0), 27)
        XCTAssertEqual(Geomagnetic.kpStep(9.5), 27)
        XCTAssertEqual(Geomagnetic.kpStep(-1.0), 0)
        XCTAssertEqual(Geomagnetic.kpStep(.nan), 0)
        XCTAssertEqual(Geomagnetic.kpStep(.infinity), 0)
        XCTAssertEqual(Geomagnetic.kpThirdsLabel(9.5), "9")
    }

    func testApTableIsStrictlyMonotonic() {
        // ap rises with every third of a Kp step. A duplicated or transposed
        // entry would slip past every named-value check above.
        for i in 1..<Geomagnetic.apTable.count {
            XCTAssertGreaterThan(Geomagnetic.apTable[i], Geomagnetic.apTable[i - 1], "step \(i)")
        }
    }

    func testApForKnownKp() {
        XCTAssertEqual(Geomagnetic.ap(kp: 0.0), 0)
        XCTAssertEqual(Geomagnetic.ap(kp: 5.0), 48)
        XCTAssertEqual(Geomagnetic.ap(kp: 6.0), 80)
        XCTAssertEqual(Geomagnetic.ap(kp: 7.0), 132)
        XCTAssertEqual(Geomagnetic.ap(kp: 8.667), 300)
        XCTAssertEqual(Geomagnetic.ap(kp: 9.0), 400)
        // Every step resolves to its own table entry.
        for step in 0..<Geomagnetic.apTable.count {
            XCTAssertEqual(Geomagnetic.ap(kp: Double(step) / 3.0), Geomagnetic.apTable[step], "step \(step)")
        }
    }

    // MARK: - Field strength, declination and the compass

    func testHorizontalIntensity() {
        XCTAssertEqual(Geomagnetic.horizontalIntensityNT(magneticLatitudeDeg: 0), 29717.17, accuracy: 1)
        XCTAssertEqual(Geomagnetic.horizontalIntensityNT(magneticLatitudeDeg: 50), 19101.8, accuracy: 1)
        XCTAssertEqual(Geomagnetic.horizontalIntensityNT(magneticLatitudeDeg: 67), 11611.4, accuracy: 1)
        XCTAssertEqual(Geomagnetic.horizontalIntensityNT(magneticLatitudeDeg: 90), 0.0, accuracy: 1)
    }

    func testHorizontalIntensityStaysInBandBelowSeventyDegrees() {
        // Everywhere a user can stand and see an oval, H is a five-figure
        // number. If this band ever breaks, the compass line is reading a
        // moment in the wrong unit.
        for mlat in stride(from: -70.0, through: 70.0, by: 5.0) {
            let h = Geomagnetic.horizontalIntensityNT(magneticLatitudeDeg: mlat)
            XCTAssertGreaterThanOrEqual(h, 10_000, "\(mlat)")
            XCTAssertLessThanOrEqual(h, 30_000, "\(mlat)")
        }
    }

    func testDeclinationSigma() {
        // σ_D = sqrt(0.26² + (5417/H)²). The FORMULA is authoritative; the
        // prose roundings (~0.36° and ~0.60°) are not, so do not adjust the
        // constants to reproduce them.
        XCTAssertEqual(Geomagnetic.declinationSigmaDeg(horizontalIntensityNT: 20000), 0.37545, accuracy: 0.005)
        XCTAssertEqual(Geomagnetic.declinationSigmaDeg(horizontalIntensityNT: 10000), 0.60087, accuracy: 0.005)
        // At the magnetic pole H goes to zero and the model divides by it.
        // Fall back to the floor rather than return an infinity the UI would
        // render — and treat a non-finite H the same way, because a NaN would
        // propagate silently instead of showing as an obviously broken number.
        XCTAssertEqual(Geomagnetic.declinationSigmaDeg(horizontalIntensityNT: 0.0),
                       Geomagnetic.declSigmaBaseDeg, accuracy: 0.0)
        XCTAssertEqual(Geomagnetic.declinationSigmaDeg(horizontalIntensityNT: .nan),
                       Geomagnetic.declSigmaBaseDeg, accuracy: 0.0)
    }

    func testCompassBands() {
        XCTAssertEqual(Geomagnetic.compassBand(kp: 4, horizontalIntensityNT: 19102), .normal)
        XCTAssertEqual(Geomagnetic.compassBand(kp: 7, horizontalIntensityNT: 19102), .oneToTwo)
        XCTAssertEqual(Geomagnetic.compassBand(kp: 7, horizontalIntensityNT: 11611), .oneToTwo)
        XCTAssertEqual(Geomagnetic.compassBand(kp: 9, horizontalIntensityNT: 19102), .twoToFive)
        XCTAssertEqual(Geomagnetic.compassBand(kp: 9, horizontalIntensityNT: 11611), .overFive)

        XCTAssertEqual(Geomagnetic.compassOffsetDeg(kp: 7, horizontalIntensityNT: 19102), 1.199, accuracy: 0.01)
        XCTAssertEqual(Geomagnetic.compassOffsetDeg(kp: 7, horizontalIntensityNT: 11611), 1.973, accuracy: 0.01)
        XCTAssertEqual(Geomagnetic.compassOffsetDeg(kp: 9, horizontalIntensityNT: 19102), 4.489, accuracy: 0.01)
        XCTAssertEqual(Geomagnetic.compassOffsetDeg(kp: 9, horizontalIntensityNT: 11611), 7.359, accuracy: 0.01)
    }

    func testCompassOffsetIsMonotonicInKp() {
        var previous = -1.0
        for kp in stride(from: 0.0, through: 9.0, by: 0.5) {
            let theta = Geomagnetic.compassOffsetDeg(kp: kp, horizontalIntensityNT: 19102)
            XCTAssertGreaterThanOrEqual(theta, previous, "Kp \(kp)")
            previous = theta
        }
    }

    func testCompassIsSilentBelowG3() {
        // At Kp 6.99 the arithmetic gives ~1.19°, but that is a G2 storm and
        // the offset is smaller than a phone compass's own error. The card
        // says nothing rather than implying a correction to dial in.
        XCTAssertGreaterThan(Geomagnetic.compassOffsetDeg(kp: 6.99, horizontalIntensityNT: 19102), 1.0)
        XCTAssertEqual(Geomagnetic.compassBand(kp: 6.99, horizontalIntensityNT: 19102), .normal)
        XCTAssertEqual(Geomagnetic.compassBand(kp: 7.0, horizontalIntensityNT: 19102), .oneToTwo)
    }

    func testCompassBandIsMonotonicInKp() throws {
        // Spec section 6 is a claim about the BAND, not the offset, and the
        // offset test above cannot see it: the band puts a G3 gate and a
        // threshold ladder on top, so an out-of-order constant or a flipped
        // comparison could step the advisory DOWN while the offset climbs —
        // "needle off by 1–2°" at Kp 8 and "normal" at Kp 9. `CompassBand`
        // carries no raw value, so the order is spelled out here; it is the
        // declaration order, which is what Kotlin's `ordinal` compares.
        let order: [CompassBand] = [.normal, .underOne, .oneToTwo, .twoToFive, .overFive]
        for h in [19102.0, 11611.0] {
            var previous = 0
            for step in 0...90 {
                let kp = Double(step) / 10.0
                let band = Geomagnetic.compassBand(kp: kp, horizontalIntensityNT: h)
                let rank = try XCTUnwrap(order.firstIndex(of: band), "\(band)")
                XCTAssertGreaterThanOrEqual(rank, previous, "H \(h) Kp \(kp)")
                previous = rank
            }
        }
    }

    // MARK: - GNSS advisory

    func testGnssAdvisoryIsLatitudeGated() {
        // Measured PPP error only climbed at high latitude, so a G3 in Berlin
        // is nominal while the same storm at Tromso is not.
        XCTAssertEqual(Geomagnetic.gnssAdvisory(gScale: .g2, magneticLatitudeDeg: 60), .nominal)
        XCTAssertEqual(Geomagnetic.gnssAdvisory(gScale: .g3, magneticLatitudeDeg: 40), .nominal)
        XCTAssertEqual(Geomagnetic.gnssAdvisory(gScale: .g3, magneticLatitudeDeg: 60), .mayDegrade)
        XCTAssertEqual(Geomagnetic.gnssAdvisory(gScale: .g5, magneticLatitudeDeg: 40), .mayDegrade)
        XCTAssertEqual(Geomagnetic.gnssAdvisory(gScale: .g5, magneticLatitudeDeg: 60), .degraded)
        XCTAssertEqual(Geomagnetic.gnssAdvisory(gScale: .g3, magneticLatitudeDeg: nil), .nominal)
        // The gate is on |mlat|, so the southern hemisphere reads the same.
        XCTAssertEqual(Geomagnetic.gnssAdvisory(gScale: .g5, magneticLatitudeDeg: -60), .degraded)
    }

    // MARK: - Pole bearing

    func testPoleBearings() {
        let fixtures: [(String, Double, Double, Double)] = [
            ("Moscow", 55.7558, 37.6173, 346.056), ("Vladivostok", 43.1198, 131.8869, 4.643),
            ("Fairbanks", 64.8378, -147.7164, 21.929), ("London", 51.5074, -0.1278, 345.237),
            ("Chicago", 41.8781, -87.6298, 3.691), ("Hobart", -42.8821, 147.3272, 189.111)
        ]
        for (name, lat, lon, expected) in fixtures {
            XCTAssertEqual(Geomagnetic.poleBearing(latitude: lat, longitude: lon),
                           expected, accuracy: 0.01, name)
        }
    }

    func testSouthernPoleBearingIsNorthernTurnedBy180() {
        // Both poles and the observer sit on one great circle, so the southern
        // bearing is exact, not an approximation.
        let lat = -42.8821, lon = 147.3272
        let poleLat = Geomagnetic.dipolePoleLatDeg, poleLon = Geomagnetic.dipolePoleLonDeg
        let toNorth = Geometry.bearing(from: .init(latitude: lat, longitude: lon),
                                       to: .init(latitude: poleLat, longitude: poleLon))
        XCTAssertFalse(Geomagnetic.isNorthernMagnetic(latitude: lat, longitude: lon))
        XCTAssertEqual(Geomagnetic.poleBearing(latitude: lat, longitude: lon),
                       (toNorth + 180).truncatingRemainder(dividingBy: 360), accuracy: 0.01)
    }

    func testPoleBearingBranchesOnTheMagneticHemisphere() {
        // The dipole is tilted 9.17°, so either side of the equator there is a
        // band where the two hemispheres disagree — geographically south but
        // magnetically north, and the reverse. The pole you turn to face is
        // decided by the MAGNETIC sign: that is the oval you could actually
        // see, and it is the sign the aurora verdict already keys off.
        let fixtures: [(Double, Double, Bool)] = [
            (-5.0, -72.8013, true), (-4.0, -60.0, true),    // south of the equator, magnetically north
            (1.0, 100.0, false), (3.0, 110.0, false)        // north of the equator, magnetically south
        ]
        for (lat, lon, northern) in fixtures {
            let name = "\(lat), \(lon)"
            XCTAssertEqual(Geomagnetic.isNorthernMagnetic(latitude: lat, longitude: lon), northern, name)
            // The whole point of the fixture: the geographic sign says the
            // opposite, so a geographic branch would send the user round.
            XCTAssertNotEqual(lat >= 0, northern, name)

            let toNorth = Geometry.bearing(from: .init(latitude: lat, longitude: lon),
                                           to: .init(latitude: Geomagnetic.dipolePoleLatDeg,
                                                     longitude: Geomagnetic.dipolePoleLonDeg))
            let expected = northern ? toNorth : (toNorth + 180).truncatingRemainder(dividingBy: 360)
            XCTAssertEqual(Geomagnetic.poleBearing(latitude: lat, longitude: lon),
                           expected, accuracy: 0.01, name)
        }
    }

    // MARK: - Darkness

    func testDarkElevationConstantsMatchSolar() {
        // Two files hold these numbers so the parity block stays diffable
        // against Kotlin. This is the pin that keeps them equal.
        XCTAssertEqual(Geomagnetic.darkElevationDeg, Solar.astroDarkElevation)
        XCTAssertEqual(Geomagnetic.idealDarkElevationDeg, Solar.idealDarkElevation)
    }

    func testArcticSummerHasNoDarknessButReportsWhenItReturns() throws {
        // Tromso on midsummer's day: the sun never drops to −12°, so there is
        // no window at all — and the card owes the user a date rather than an
        // empty row.
        let calendar = utc
        let midsummer = try XCTUnwrap(calendar.date(from: DateComponents(year: 2023, month: 6, day: 21, hour: 12)))
        XCTAssertNil(Solar.nightWindow(date: midsummer, latitude: 69.6492, longitude: 18.9553,
                                       calendar: calendar))

        let outlook = Geomagnetic.auroraOutlook(magneticLatitudeDeg: 67.25, kp: 6,
                                                latitude: 69.6492, longitude: 18.9553,
                                                now: midsummer, calendar: calendar)
        XCTAssertFalse(outlook.hasDarkness)
        XCTAssertNotNil(outlook.nextDarknessDate)
        XCTAssertGreaterThan(try XCTUnwrap(outlook.nextDarknessDate), midsummer)
    }

    func testNightWindowSpansMidnight() throws {
        // THE classic bug: a "night" built from one day's two crossings runs
        // from morning to evening of the same date. London on the winter
        // solstice must start on the 21st and end on the 22nd.
        let calendar = utc
        let solstice = try XCTUnwrap(calendar.date(from: DateComponents(year: 2023, month: 12, day: 21, hour: 15)))
        let window = try XCTUnwrap(Solar.nightWindow(date: solstice, latitude: 51.5074, longitude: -0.1278,
                                                     calendar: calendar))

        XCTAssertLessThan(window.start, window.end)
        XCTAssertEqual(calendar.component(.day, from: window.start), 21)
        XCTAssertEqual(calendar.component(.day, from: window.end), 22)
        XCTAssertGreaterThan(window.duration, 8 * 3600)

        // The ideal (−18°) band is strictly inside the −12° one.
        let idealStart = try XCTUnwrap(window.idealStart)
        let idealEnd = try XCTUnwrap(window.idealEnd)
        XCTAssertGreaterThan(idealStart, window.start)
        XCTAssertLessThan(idealEnd, window.end)
    }

    func testNightWindowSitsInsideCivilTwilight() throws {
        // Consistency with the solar model the rest of the app already ships:
        // it cannot be astronomically dark before civil dusk, nor still dark
        // after the next civil dawn.
        let calendar = utc
        let solstice = try XCTUnwrap(calendar.date(from: DateComponents(year: 2023, month: 12, day: 21, hour: 15)))
        let midnightUTC = try XCTUnwrap(calendar.date(from: DateComponents(year: 2023, month: 12, day: 21)))
        let window = try XCTUnwrap(Solar.nightWindow(date: solstice, latitude: 51.5074, longitude: -0.1278,
                                                     calendar: calendar))

        let duskMinutes = try XCTUnwrap(Solar.eventUTCMinutes(year: 2023, month: 12, day: 21,
                                                              latitude: 51.5074, longitude: -0.1278,
                                                              elevationDeg: Solar.civilElevation, rising: false))
        let dawnMinutes = try XCTUnwrap(Solar.eventUTCMinutes(year: 2023, month: 12, day: 22,
                                                              latitude: 51.5074, longitude: -0.1278,
                                                              elevationDeg: Solar.civilElevation, rising: true))
        let civilDusk = midnightUTC.addingTimeInterval(duskMinutes * 60)
        let civilDawn = midnightUTC.addingTimeInterval((1440 + dawnMinutes) * 60)

        XCTAssertLessThanOrEqual(civilDusk, window.start)
        XCTAssertLessThanOrEqual(window.end, civilDawn)
    }

    func testEquinoxNightAtTheEquatorIsAboutTenHours() throws {
        // Twelve hours of daylight, minus twilight at both ends.
        let calendar = utc
        let equinox = try XCTUnwrap(calendar.date(from: DateComponents(year: 2023, month: 3, day: 21, hour: 12)))
        let window = try XCTUnwrap(Solar.nightWindow(date: equinox, latitude: 0, longitude: 0,
                                                     calendar: calendar))
        XCTAssertEqual(window.duration / 3600, 10.0, accuracy: 1.0)
    }

    func testDarkWindowAlreadyUnderWayIsPreferredOverTonights() throws {
        // At 02:00 the window that matters started YESTERDAY evening. Asking
        // only for "today's" window would report darkness as ~17 hours away
        // and quietly suppress the alert while the sky is at its darkest.
        let calendar = utc
        let twoAM = try XCTUnwrap(calendar.date(from: DateComponents(year: 2023, month: 12, day: 22, hour: 2)))
        let window = try XCTUnwrap(Geomagnetic.darkWindow(latitude: 51.5074, longitude: -0.1278,
                                                          now: twoAM, calendar: calendar))
        XCTAssertLessThanOrEqual(window.start, twoAM)
        XCTAssertGreaterThan(window.end, twoAM)
        XCTAssertEqual(calendar.component(.day, from: window.start), 21)
    }

    // MARK: - Aggregation and freshness

    /// A two-bin series `ageHours` old whose newest bin starts `binOffsetHours`
    /// from `now` (0 = the bin containing now).
    private func series(ageHours: Double, kp: Double, binOffsetHours: Double = 0) -> KpSeries {
        KpSeries(fetchedAt: now.addingTimeInterval(-ageHours * 3600),
                 points: [KpPoint(time: now.addingTimeInterval((binOffsetHours - 3) * 3600),
                                  kp: kp - 1, provenance: .observed),
                          KpPoint(time: now.addingTimeInterval(binOffsetHours * 3600),
                                  kp: kp, provenance: .observed)])
    }

    /// A payload shaped like the real product: 3-hour bins running from
    /// `spanStartHours` to `spanEndHours` RELATIVE TO THE FETCH, observed up
    /// to the fetch stamp and forecast after it, fetched `ageHours` ago.
    ///
    /// The live endpoint returns 81 bins spanning −177 h to +62.5 h (59
    /// observed, 5 estimated, 17 predicted), which is why a cached copy can
    /// still answer for "now" about 65 hours after it was fetched — the
    /// measurement the coverage rule is built on.
    private func forecastSeries(ageHours: Double,
                                kp: Double,
                                spanStartHours: Double = -177.0,
                                spanEndHours: Double = 62.5) -> KpSeries {
        let fetchedAt = now.addingTimeInterval(-ageHours * 3600)
        var points: [KpPoint] = []
        var offset = spanStartHours
        while offset <= spanEndHours {
            points.append(KpPoint(time: fetchedAt.addingTimeInterval(offset * 3600),
                                  kp: kp,
                                  provenance: offset <= 0 ? .observed : .predicted))
            offset += Geomagnetic.kpBinHours
        }
        return KpSeries(fetchedAt: fetchedAt, points: points)
    }

    private func londonConditions(_ series: KpSeries?) throws -> MagneticConditions {
        Geomagnetic.conditions(series: series, latitude: 51.5074, longitude: -0.1278,
                               grid: try loadGrid(), now: now, calendar: utc)
    }

    func testFreshnessBands() throws {
        XCTAssertEqual(try londonConditions(series(ageHours: 2, kp: 6)).freshness, .live)
        // Past the live window the band is decided by COVERAGE: nine hours old
        // and a bin still contains now is cached; nine hours old with nothing
        // covering now is expired, however far it is from the backstop.
        XCTAssertEqual(try londonConditions(series(ageHours: 9, kp: 6)).freshness, .cached)
        XCTAssertEqual(try londonConditions(series(ageHours: 9, kp: 6, binOffsetHours: -9)).freshness, .expired)
        XCTAssertEqual(try londonConditions(series(ageHours: 60, kp: 6, binOffsetHours: -60)).freshness, .expired)
        XCTAssertEqual(try londonConditions(nil).freshness, Freshness.none)
    }

    func testLiveSeriesWithoutACoveringBinStillResolvesItsNewestObservedBin() throws {
        // Five hours old with a payload whose newest bin ended long ago: the
        // live tier keeps the full fallback, so the current value comes from
        // the newest observed bin at or before now — not from array position,
        // which SWPC does not order for us. (Past the live window this shape
        // is expired instead: see `testFreshnessBands`.)
        let conditions = try londonConditions(series(ageHours: 5, kp: 6, binOffsetHours: -9))
        XCTAssertEqual(conditions.freshness, .live)
        XCTAssertEqual(try XCTUnwrap(conditions.kpNow), 6.0, accuracy: 1e-9)
        XCTAssertEqual(conditions.kpProvenance, .observed)
        XCTAssertEqual(conditions.binStart, now.addingTimeInterval(-9 * 3600))
    }

    func testKpAboveTheScaleIsClampedToNine() throws {
        // SWPC publishes Kp on 0…9. A malformed row — or a cache written by a
        // build that got the parse wrong — must not carry 9.33 into the ap
        // lookup or the compass band, where it would index off the end of a
        // 28-entry table. It is pinned to 9.0 at the door.
        let conditions = try londonConditions(series(ageHours: 1, kp: 9.33))
        XCTAssertEqual(try XCTUnwrap(conditions.kpNow), 9.0, accuracy: 1e-9)
        XCTAssertEqual(conditions.gScale, .g5)
        XCTAssertEqual(Geomagnetic.ap(kp: try XCTUnwrap(conditions.kpNow)), 400)
        XCTAssertEqual(Geomagnetic.kpThirdsLabel(try XCTUnwrap(conditions.kpNow)), "9")
    }

    func testNegativeKpFromACorruptCacheIsClampedToZero() throws {
        // The other end of the same clamp. A negative Kp is not a quiet sky,
        // it is a broken payload; the card shows the bottom of the scale
        // rather than a G value derived from a number that cannot exist.
        let conditions = try londonConditions(series(ageHours: 1, kp: -1.0))
        XCTAssertEqual(try XCTUnwrap(conditions.kpNow), 0.0, accuracy: 1e-9)
        XCTAssertEqual(conditions.gScale, .g0)
        XCTAssertEqual(Geomagnetic.ap(kp: try XCTUnwrap(conditions.kpNow)), 0)
        XCTAssertEqual(conditions.compass, .normal)
    }

    func testExpiredCacheDropsKpButKeepsLatitudeAndThreshold() throws {
        // 60 hours old. A stale number on a row labelled "now" is a lie, so
        // Kp goes; magnetic latitude and "you need about Kp 5+ here" do not
        // depend on the storm and stay.
        let conditions = try londonConditions(series(ageHours: 60, kp: 6, binOffsetHours: -60))
        XCTAssertEqual(conditions.freshness, .expired)
        XCTAssertNil(conditions.kpNow)
        XCTAssertEqual(conditions.gScale, .g0)
        XCTAssertEqual(try XCTUnwrap(conditions.magneticLatitudeDeg), 47.71, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(conditions.aurora.kpNeededForHorizonGlow), 5.333, accuracy: 1e-3)
        XCTAssertEqual(conditions.aurora.visibility, .unknown)
        XCTAssertNil(conditions.aurora.marginDeg)
    }

    func testEmptySeriesIsNoDataAndDoesNotCrash() throws {
        let conditions = try londonConditions(KpSeries(fetchedAt: now, points: []))
        XCTAssertEqual(conditions.freshness, Freshness.none)
        XCTAssertNil(conditions.kpNow)
        XCTAssertNil(conditions.dataAge)
        XCTAssertEqual(conditions.aurora.visibility, .unknown)
    }

    func testMissingGridSuppressesTheAuroraRowEntirely() {
        // Honesty contract item 12: without the correction there is no aurora
        // verdict at all. Falling back to the raw dipole here is the +5.63°
        // London bug wearing a different hat.
        let conditions = Geomagnetic.conditions(series: series(ageHours: 1, kp: 7),
                                                latitude: 51.5074, longitude: -0.1278,
                                                grid: nil, now: now, calendar: utc)
        XCTAssertNil(conditions.magneticLatitudeDeg)
        XCTAssertNil(conditions.horizontalIntensityNT)
        XCTAssertNil(conditions.aurora.kpNeededForHorizonGlow)
        XCTAssertEqual(conditions.aurora.visibility, .unknown)
        XCTAssertEqual(conditions.gnss, .nominal)
        XCTAssertEqual(conditions.compass, .normal)
        // The Kp half of the card still works — it needs no position at all.
        XCTAssertEqual(conditions.kpNow, 7.0)
        XCTAssertEqual(conditions.gScale, .g3)
    }

    func testConditionsWithoutAFixHasNoOvalAndNoBearing() {
        let conditions = Geomagnetic.conditions(series: series(ageHours: 1, kp: 7),
                                                latitude: nil, longitude: nil,
                                                grid: nil, now: now, calendar: utc)
        XCTAssertNil(conditions.aurora.poleBearingDeg)
        XCTAssertFalse(conditions.aurora.hasDarkness)
        XCTAssertEqual(conditions.aurora.visibility, .unknown)
    }

    // MARK: - The alert gate

    /// Hand-built conditions carrying exactly the fields the gate reads.
    /// `darkStartsInHours` nil means there is no dark window tonight.
    private func alertFixture(kp: Double? = 6.0,
                              marginDeg: Double = -4.0,
                              freshness: Freshness = .live,
                              dataAgeHours: Double? = 1.0,
                              darkStartsInHours: Double? = 0) -> MagneticConditions {
        var outlook = AuroraOutlook()
        outlook.visibility = Geomagnetic.visibility(marginDeg: marginDeg)
        outlook.marginDeg = marginDeg
        outlook.rangeKm = Geomagnetic.rangeKm(marginDeg: marginDeg)
        outlook.kpNeededForHorizonGlow = 5.0
        outlook.hasDarkness = darkStartsInHours != nil
        outlook.windowStart = darkStartsInHours.map { now.addingTimeInterval($0 * 3600) }
        outlook.windowEnd = darkStartsInHours.map { now.addingTimeInterval(($0 + 8) * 3600) }

        var conditions = MagneticConditions()
        conditions.kpNow = kp
        conditions.kpProvenance = .observed
        conditions.gScale = kp.map { Geomagnetic.gScale(kp: $0) } ?? .g0
        conditions.aurora = outlook
        conditions.freshness = freshness
        conditions.dataAge = dataAgeHours.map { $0 * 3600 }
        return conditions
    }

    private func shouldNotify(_ conditions: MagneticConditions,
                              enabled: Bool = true,
                              lastNotifiedAt: Date? = nil) -> Bool {
        AuroraAlert.shouldNotify(conditions: conditions, enabled: enabled,
                                 lastNotifiedAt: lastNotifiedAt, now: now)
    }

    func testAlertFiresOnAGenuineOpportunity() {
        // Kp 6, the oval 4° north of the user (a horizon glow), dark now.
        XCTAssertTrue(shouldNotify(alertFixture()))
        // And when the oval is overhead.
        XCTAssertTrue(shouldNotify(alertFixture(kp: 5.0, marginDeg: 0.5)))
    }

    func testAlertNeedsUsableData() {
        // The freshness tier IS the age test now. Expired means no bin covers
        // now — perfect conditions on it are not conditions at all, they are
        // what the sky was doing two days ago — while cached means a NOAA bin
        // does cover now, whatever the copy's age, so it alerts.
        XCTAssertFalse(shouldNotify(alertFixture(freshness: .expired, dataAgeHours: 60)))
        XCTAssertFalse(shouldNotify(alertFixture(freshness: Freshness.none, dataAgeHours: nil)))
        XCTAssertTrue(shouldNotify(alertFixture(freshness: .cached, dataAgeHours: 13)))
        XCTAssertTrue(shouldNotify(alertFixture(freshness: .cached, dataAgeHours: 11)))
    }

    func testAlertNeedsKpFiveOrMore() {
        XCTAssertFalse(shouldNotify(alertFixture(kp: 4.9, marginDeg: 3)))
        XCTAssertTrue(shouldNotify(alertFixture(kp: 5.0, marginDeg: 3)))
        XCTAssertFalse(shouldNotify(alertFixture(kp: nil, marginDeg: 3)))
    }

    func testAlertNeedsTheOvalToReachAtLeastTheHorizon() {
        XCTAssertTrue(shouldNotify(alertFixture(marginDeg: -4)))     // horizon glow
        XCTAssertFalse(shouldNotify(alertFixture(marginDeg: -12)))   // not visible
    }

    func testAlertNeedsDarkness() {
        // No dark sky tonight, however big the storm. Waking somebody for an
        // aurora they cannot see is the fastest way to lose the permission.
        XCTAssertFalse(shouldNotify(alertFixture(marginDeg: 3, darkStartsInHours: nil)))
        XCTAssertFalse(shouldNotify(alertFixture(darkStartsInHours: 7)))
        XCTAssertTrue(shouldNotify(alertFixture(darkStartsInHours: 4)))
        XCTAssertTrue(shouldNotify(alertFixture(darkStartsInHours: 0)))   // already under way
    }

    func testAlertDoesNotFireOnceTonightsWindowHasEnded() {
        // A window that started nine hours ago and ended an hour ago still
        // passes the lookahead arithmetic — it is "in the past", not "too far
        // ahead". Only the end stamp catches it.
        XCTAssertFalse(shouldNotify(alertFixture(darkStartsInHours: -9)))
    }

    func testAlertRespectsTheCooldown() {
        XCTAssertFalse(shouldNotify(alertFixture(), lastNotifiedAt: now.addingTimeInterval(-19 * 3600)))
        XCTAssertTrue(shouldNotify(alertFixture(), lastNotifiedAt: now.addingTimeInterval(-21 * 3600)))
    }

    func testAlertIsOffWhenNotOptedIn() {
        XCTAssertFalse(shouldNotify(alertFixture(), enabled: false))
    }

    func testAlertNeedsALocationFix() {
        // Without a fix there is no magnetic latitude, so there is no verdict
        // and nothing to alert about.
        let conditions = Geomagnetic.conditions(series: series(ageHours: 1, kp: 7),
                                                latitude: nil, longitude: nil,
                                                grid: nil, now: now, calendar: utc)
        XCTAssertFalse(shouldNotify(conditions))
    }

    // MARK: - Coverage, not the clock

    func testSixtyHourOldCacheStillCoveringNowIsCachedNotExpiredAsUnderTheOldFortyEightHourCap() throws {
        // THE regression test for the 48 h cap this change removed. Sixty
        // hours is inside the payload's own forward reach, so NOAA's forecast
        // still has a bin containing now and the card can still say what Kp is
        // — which is precisely what a three-day forecast is for.
        let series = forecastSeries(ageHours: 60, kp: 6)
        XCTAssertNotNil(Geomagnetic.coveringPoint(in: series.points, now: now))

        let conditions = try londonConditions(series)
        XCTAssertEqual(conditions.freshness, .cached)
        XCTAssertEqual(try XCTUnwrap(conditions.kpNow), 6.0, accuracy: 1e-9)
        // It is a forecast bin, and the card's caption says so.
        XCTAssertEqual(conditions.kpProvenance, .predicted)
        XCTAssertEqual(conditions.binStart, now)
        XCTAssertEqual(conditions.gScale, .g2)
    }

    func testSixtyHourOldCacheThatNoLongerCoversNowIsExpiredWithTheOnDeviceRowsIntact() throws {
        // The same sixty hours, well inside the 72 h backstop, but a payload
        // whose forward run stopped 48 h after the fetch and so has nothing to
        // say about now. Coverage, not the clock, is what expires it — and the
        // rows that never needed the network survive, which is the whole
        // offline tier of this card.
        let series = forecastSeries(ageHours: 60, kp: 6, spanEndHours: 48)
        XCTAssertNil(Geomagnetic.coveringPoint(in: series.points, now: now))

        let conditions = try londonConditions(series)
        XCTAssertEqual(conditions.freshness, .expired)
        XCTAssertNil(conditions.kpNow)
        XCTAssertNil(conditions.kpProvenance)
        XCTAssertNil(conditions.binStart)
        XCTAssertEqual(conditions.gScale, .g0)

        let mlat = try XCTUnwrap(conditions.magneticLatitudeDeg)
        XCTAssertEqual(mlat, 47.71, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(conditions.aurora.kpNeededForHorizonGlow), 5.333, accuracy: 1e-3)
        XCTAssertEqual(Geomagnetic.requiredKpLabel(magneticLatitudeDeg: mlat), "about Kp 5+")
    }

    func testEightyHourOldCacheExpiresOnTheBackstopEvenWhileItCoversNow() throws {
        // The backstop. This payload reaches 90 h past its own fetch — further
        // forward than the real product has ever run — so coverage alone would
        // let it speak for now at eighty hours old. `cachedMaxAgeHours` is what
        // stops a corrupt or far-future cache doing that.
        let series = forecastSeries(ageHours: 80, kp: 6, spanEndHours: 90)
        XCTAssertNotNil(Geomagnetic.coveringPoint(in: series.points, now: now))

        let conditions = try londonConditions(series)
        XCTAssertEqual(conditions.freshness, .expired)
        XCTAssertNil(conditions.kpNow)
        XCTAssertNotNil(conditions.magneticLatitudeDeg)
    }

    func testSixHourBoundaryIsStillLive() throws {
        // Exactly `liveMaxAgeHours` old and with no bin over now: the live
        // window is an age test and nothing else, so this is still live and
        // still answers from the three-tier fallback. A hair past it the
        // coverage gate takes over and the very same payload is expired.
        XCTAssertEqual(Geomagnetic.freshness(dataAge: 6 * 3600, hasCoveringBin: false), .live)

        let series = forecastSeries(ageHours: 6, kp: 6, spanEndHours: 0)
        XCTAssertNil(Geomagnetic.coveringPoint(in: series.points, now: now))

        let conditions = try londonConditions(series)
        XCTAssertEqual(conditions.freshness, .live)
        XCTAssertEqual(try XCTUnwrap(conditions.kpNow), 6.0, accuracy: 1e-9)
        XCTAssertEqual(conditions.binStart, now.addingTimeInterval(-6 * 3600))

        XCTAssertEqual(try londonConditions(forecastSeries(ageHours: 6.01, kp: 6, spanEndHours: 0)).freshness,
                       .expired)
    }

    func testCoveringPointHoldsForExactlyItsOwnThreeHours() {
        let bin = KpPoint(time: now, kp: 5, provenance: .predicted)
        // A second before the bin opens nothing covers now …
        XCTAssertNil(Geomagnetic.coveringPoint(in: [bin], now: now.addingTimeInterval(-1)))
        // … from its first instant to its last it does …
        XCTAssertEqual(Geomagnetic.coveringPoint(in: [bin], now: now), bin)
        XCTAssertEqual(Geomagnetic.coveringPoint(in: [bin], now: now.addingTimeInterval(3 * 3600 - 1)), bin)
        // … and the instant the next bin would begin, it does not: the window
        // is half-open, so two adjacent bins never both cover the same moment.
        XCTAssertNil(Geomagnetic.coveringPoint(in: [bin], now: now.addingTimeInterval(3 * 3600)))
        XCTAssertNil(Geomagnetic.coveringPoint(in: [], now: now))
    }

    func testAlertFiresFromAFortyHourOldCacheWhoseForecastCoversNow() throws {
        // The offline-trek case, and the whole point of carrying a three-day
        // forecast up the hill: the payload was pulled at the trailhead nearly
        // two days ago, one of NOAA's own bins covers tonight, and London is
        // dark with the oval within horizon reach. Resolved through the real
        // `conditions`, so it is the coverage rule deciding and not a hand-set
        // freshness.
        let conditions = try londonConditions(forecastSeries(ageHours: 40, kp: 6))
        XCTAssertEqual(conditions.freshness, .cached)
        XCTAssertNotNil(conditions.kpNow)
        // Every other gate is genuinely open, so coverage is what is being
        // tested here and not, say, a missing darkness window.
        XCTAssertEqual(conditions.aurora.visibility, .horizonGlow)
        XCTAssertTrue(conditions.aurora.hasDarkness)
        XCTAssertTrue(shouldNotify(conditions))
    }

    func testAlertDoesNotFireWhenNoBinCoversNow() throws {
        // The other half of the same rule. Once no bin covers now there is no
        // Kp to alert on, however recently the copy was fetched: a cache only
        // just too old to be live is in exactly the same position as a
        // three-day-old one.
        for ageHours in [7.0, 24.0, 40.0, 60.0, 71.0] {
            let conditions = try londonConditions(forecastSeries(ageHours: ageHours, kp: 6, spanEndHours: 0))
            XCTAssertEqual(conditions.freshness, .expired, "\(ageHours) h")
            XCTAssertNil(conditions.kpNow, "\(ageHours) h")
            XCTAssertFalse(shouldNotify(conditions), "\(ageHours) h")
        }
        // And however young the copy is: a payload with nothing at or before
        // now has no bin to read at all, so there is no Kp to alert on. (A
        // live copy that does have a past bin still uses the fallback — six
        // hours old is data about now whichever bin it lands on.)
        let futureOnly = KpSeries(fetchedAt: now.addingTimeInterval(-3600),
                                  points: [KpPoint(time: now.addingTimeInterval(3 * 3600),
                                                   kp: 7, provenance: .predicted),
                                           KpPoint(time: now.addingTimeInterval(6 * 3600),
                                                   kp: 7, provenance: .predicted)])
        let young = try londonConditions(futureOnly)
        XCTAssertEqual(young.freshness, .live)
        XCTAssertNil(young.kpNow)
        XCTAssertFalse(shouldNotify(young))
    }
}
