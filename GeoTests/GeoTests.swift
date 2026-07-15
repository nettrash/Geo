//
//  GeoTests.swift
//  GeoTests
//
//  Created by nettrash on 08/09/2023.
//

import XCTest
@testable import Geo

final class GeoTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // Any test you write for XCTest can be annotated as throws and async.
        // Mark your test throws to produce an unexpected failure when your test encounters an uncaught error.
        // Mark your test async to allow awaiting for asynchronous code to complete. Check the results with assertions afterwards.
    }

    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        self.measure {
            // Put the code you want to measure the time of here.
        }
    }

}

/// Golden-history tests for the de-trended pressure-tendency fit (M5a).
/// Mirrored by Android `StormWarningTest` — identical scenarios and
/// thresholds, so a divergence in either platform's math shows up as a
/// failing test on that side.
final class StormWarningTests: XCTestCase {

    /// Standard-atmosphere pressure ratio P(alt)/P(0); mirrors the
    /// private helper inside `StormWarning` so the synthetic histories
    /// are generated with the same physics the fit removes.
    private func ratio(_ altM: Double) -> Double {
        pow(1.0 - altM / 44330.0, 5.255)
    }

    /// Build 13 samples at 15-minute spacing ending at `now` (a 3-hour
    /// window). `pressureKPa(idx)` / `altitudeM(idx)` drive each sample.
    private func history(now: Date,
                         pressureKPa: (Int) -> Double,
                         altitudeM: (Int) -> Double) -> [PressureSample] {
        (0...12).map { idx in
            PressureSample(date: now.addingTimeInterval(Double(idx - 12) * 15 * 60),
                           pressureKPa: pressureKPa(idx),
                           altitudeM: altitudeM(idx))
        }
    }

    func testConstantAltitudeFallFiresFallingFast() {
        let now = Date()
        // 1013 → 1007 hPa over 3 h at a fixed altitude: −6 hPa, alert.
        let samples = history(now: now,
                              pressureKPa: { 101.3 - Double($0) * (0.6 / 12.0) },
                              altitudeM: { _ in 0 })
        let trend = StormWarning.tendency(samples, now: now)
        XCTAssertEqual(trend.classification, .fallingFast)
        XCTAssertTrue(trend.isAlert)
        XCTAssertEqual(trend.changeHPaOver3h, -6.0, accuracy: 0.2)
    }

    func testAltitudeExplainedFallIsSteady() {
        let now = Date()
        // Pressure drops only because the user climbs 0 → 500 m at a
        // constant weather (1013 hPa sea-level): de-trend must cancel it.
        let samples = history(now: now,
                              pressureKPa: { 101.3 * self.ratio(Double($0) * (500.0 / 12.0)) },
                              altitudeM: { Double($0) * (500.0 / 12.0) })
        let trend = StormWarning.tendency(samples, now: now)
        XCTAssertEqual(trend.classification, .steady)
        XCTAssertFalse(trend.isAlert)
        XCTAssertEqual(trend.changeHPaOver3h, 0.0, accuracy: 0.2)
    }

    func testRisingFiresNothing() {
        let now = Date()
        let samples = history(now: now,
                              pressureKPa: { 101.3 + Double($0) * (0.6 / 12.0) },
                              altitudeM: { _ in 0 })
        let trend = StormWarning.tendency(samples, now: now)
        XCTAssertEqual(trend.classification, .rising)
        XCTAssertFalse(trend.isAlert)
    }

    func testInsufficientSamplesIsUnknown() {
        let now = Date()
        let samples = [
            PressureSample(date: now.addingTimeInterval(-3600), pressureKPa: 101.3, altitudeM: 0),
            PressureSample(date: now, pressureKPa: 100.7, altitudeM: 0)
        ]
        let trend = StormWarning.tendency(samples, now: now)
        XCTAssertEqual(trend.classification, .unknown)
        XCTAssertFalse(trend.isAlert)
    }

    func testShortSpanIsUnknown() {
        let now = Date()
        // Four samples but only a 30-minute span (< 1.5 h minimum).
        let samples = (0...3).map { idx in
            PressureSample(date: now.addingTimeInterval(Double(idx - 3) * 10 * 60),
                           pressureKPa: 101.3 - Double(idx) * 0.2,
                           altitudeM: 0)
        }
        let trend = StormWarning.tendency(samples, now: now)
        XCTAssertEqual(trend.classification, .unknown)
    }
}

/// Solar-event math tests (M-feature: golden-hour / sunrise-sunset panel).
/// Mirrored by Android `SolarTest` — same golden cases and tolerances, so
/// a divergence in either platform's NOAA implementation fails its tests.
/// All asserted values are minutes past 00:00 UTC of the given date.
final class SolarTests: XCTestCase {

    // London, ~(51.4778, 0), midsummer 2023-06-21: sunrise ≈ 03:43 UTC,
    // sunset ≈ 20:21 UTC (well-known published values).
    func testLondonMidsummerAnchor() {
        let sunrise = Solar.eventUTCMinutes(year: 2023, month: 6, day: 21,
                                            latitude: 51.4778, longitude: 0.0,
                                            elevationDeg: Solar.sunriseElevation, rising: true)
        let sunset = Solar.eventUTCMinutes(year: 2023, month: 6, day: 21,
                                           latitude: 51.4778, longitude: 0.0,
                                           elevationDeg: Solar.sunriseElevation, rising: false)
        XCTAssertEqual(try XCTUnwrap(sunrise), 223, accuracy: 15)   // 03:43 UTC
        XCTAssertEqual(try XCTUnwrap(sunset), 1221, accuracy: 15)   // 20:21 UTC
    }

    // Equator, equinox-ish: day ≈ 12 h, solar noon ≈ 12:00 UTC at lon 0.
    func testEquatorEquinoxDayLength() {
        let sunrise = try? XCTUnwrap(Solar.eventUTCMinutes(year: 2023, month: 3, day: 21,
                                     latitude: 0, longitude: 0,
                                     elevationDeg: Solar.sunriseElevation, rising: true))
        let sunset = try? XCTUnwrap(Solar.eventUTCMinutes(year: 2023, month: 3, day: 21,
                                    latitude: 0, longitude: 0,
                                    elevationDeg: Solar.sunriseElevation, rising: false))
        let noon = Solar.solarNoonUTCMinutes(year: 2023, month: 3, day: 21, longitude: 0)
        XCTAssertEqual(try XCTUnwrap(sunset! - sunrise!), 727, accuracy: 20)  // ~12 h 07 m
        XCTAssertEqual(noon, 727, accuracy: 15)                               // ~12:07 UTC
    }

    // Sunrise / sunset are symmetric about solar noon.
    func testSymmetryAboutNoon() throws {
        let noon = Solar.solarNoonUTCMinutes(year: 2023, month: 6, day: 21, longitude: 8)
        let sunrise = try XCTUnwrap(Solar.eventUTCMinutes(year: 2023, month: 6, day: 21,
                                    latitude: 46, longitude: 8,
                                    elevationDeg: Solar.sunriseElevation, rising: true))
        let sunset = try XCTUnwrap(Solar.eventUTCMinutes(year: 2023, month: 6, day: 21,
                                   latitude: 46, longitude: 8,
                                   elevationDeg: Solar.sunriseElevation, rising: false))
        XCTAssertEqual(noon - sunrise, sunset - noon, accuracy: 0.1)
    }

    // Altitude horizon-dip: from a summit the sun rises earlier and sets
    // later than at sea level.
    func testAltitudeMakesSunriseEarlierSunsetLater() throws {
        func sunrise(_ alt: Double) throws -> Double {
            try XCTUnwrap(Solar.eventUTCMinutes(year: 2023, month: 6, day: 21,
                          latitude: 46, longitude: 8,
                          elevationDeg: Solar.sunriseElevation - Solar.horizonDipDegrees(altitude: alt),
                          rising: true))
        }
        func sunset(_ alt: Double) throws -> Double {
            try XCTUnwrap(Solar.eventUTCMinutes(year: 2023, month: 6, day: 21,
                          latitude: 46, longitude: 8,
                          elevationDeg: Solar.sunriseElevation - Solar.horizonDipDegrees(altitude: alt),
                          rising: false))
        }
        XCTAssertLessThan(try sunrise(3000), try sunrise(0))
        XCTAssertGreaterThan(try sunset(3000), try sunset(0))
        XCTAssertEqual(Solar.horizonDipDegrees(altitude: 0), 0, accuracy: 1e-9)
    }

    // Event ordering across the day.
    func testEventOrdering() throws {
        func ev(_ elev: Double, _ rising: Bool) throws -> Double {
            try XCTUnwrap(Solar.eventUTCMinutes(year: 2023, month: 6, day: 21,
                          latitude: 46, longitude: 8, elevationDeg: elev, rising: rising))
        }
        let dawn = try ev(Solar.civilElevation, true)
        let sunrise = try ev(Solar.sunriseElevation, true)
        let noon = Solar.solarNoonUTCMinutes(year: 2023, month: 6, day: 21, longitude: 8)
        let sunset = try ev(Solar.sunriseElevation, false)
        let dusk = try ev(Solar.civilElevation, false)
        XCTAssertTrue(dawn < sunrise && sunrise < noon && noon < sunset && sunset < dusk)
    }

    // High Arctic midsummer: the sun never sets — sunrise/sunset undefined,
    // and the aggregate reports polar day.
    func testPolarDay() {
        let sunrise = Solar.eventUTCMinutes(year: 2023, month: 6, day: 21,
                                            latitude: 80, longitude: 0,
                                            elevationDeg: Solar.sunriseElevation, rising: true)
        XCTAssertNil(sunrise)

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let date = utc.date(from: DateComponents(year: 2023, month: 6, day: 21, hour: 12))!
        let times = Solar.times(date: date, latitude: 80, longitude: 0, altitude: 0, calendar: utc)
        XCTAssertTrue(times.isPolarDay)
        XCTAssertNil(times.sunset)
    }

    // Date-line clock zone (UTC+13, e.g. Samoa, lon −171.8): the day's solar
    // events must fall on the queried LOCAL day, not be shifted +1 day —
    // and the countdown to today's sunrise must be minutes, not ~24 h.
    func testFarEastClockZoneAnchorsToLocalDay() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 13 * 3600))
        let query = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 6, day: 21,
                                                                hour: 6, minute: 30)))
        let times = Solar.times(date: query, latitude: -13.76, longitude: -171.8, altitude: 0, calendar: cal)
        let sunrise = try XCTUnwrap(times.sunrise)
        XCTAssertEqual(cal.dateComponents([.year, .month, .day], from: sunrise),
                       cal.dateComponents([.year, .month, .day], from: query))
        XCTAssertLessThan(sunrise.timeIntervalSince(query), 3 * 3600)  // ~19 min, not 24 h
    }
}

/// Trip-summary stats tests (M5c). Mirrored by Android `TripStatsTest` —
/// same golden inputs and expected values, so a divergence fails on the
/// affected platform.
final class TripStatsTests: XCTestCase {

    private func sample(_ t: Int64, _ alt: Double,
                        lat: Double = 45, lon: Double = 8, speed: Double = 1) -> TripSample {
        TripSample(timeMs: t, altitude: alt, latitude: lat, longitude: lon, speed: speed)
    }

    func testEmptyAndSingle() {
        XCTAssertEqual(TripStats.summary([]), TripSummary())
        let s = TripStats.summary([sample(0, 123)])
        XCTAssertEqual(s.totalAscent, 0)
        XCTAssertEqual(s.totalDescent, 0)
        XCTAssertEqual(s.maxAltitude, 123)
        XCTAssertEqual(s.minAltitude, 123)
    }

    func testFlatWithJitterIsFiltered() {
        let alts: [Double] = [100, 101, 100, 102, 99, 101, 100]
        let s = TripStats.summary(alts.enumerated().map { sample(Int64($0.offset * 1000), $0.element) })
        XCTAssertEqual(s.totalAscent, 0, accuracy: 1e-9)    // all deltas < 3 m
        XCTAssertEqual(s.totalDescent, 0, accuracy: 1e-9)
        XCTAssertEqual(s.maxAltitude, 102)
        XCTAssertEqual(s.minAltitude, 99)
    }

    func testSlowClimbCapturedDespiteSmallSteps() {
        let alts: [Double] = [100, 102, 104, 106, 108, 110]   // +2 m steps, +10 m total
        let s = TripStats.summary(alts.enumerated().map { sample(Int64($0.offset * 1000), $0.element) })
        XCTAssertEqual(s.totalAscent, 8, accuracy: 1e-9)      // two confirmed 4 m steps; 2 m residual dropped
        XCTAssertEqual(s.totalDescent, 0, accuracy: 1e-9)
    }

    func testAscentDescent() {
        let s = TripStats.summary([sample(0, 100), sample(1000, 200), sample(2000, 150)])
        XCTAssertEqual(s.totalAscent, 100, accuracy: 1e-9)
        XCTAssertEqual(s.totalDescent, 50, accuracy: 1e-9)
        XCTAssertEqual(s.maxAltitude, 200)
        XCTAssertEqual(s.minAltitude, 100)
    }

    func testDistanceHaversine() {
        let s = TripStats.summary([sample(0, 100, lat: 45, lon: 8, speed: 2),
                                   sample(1000, 100, lat: 45.001, lon: 8, speed: 2)])
        XCTAssertEqual(s.distance, 111.2, accuracy: 1.5)   // ~0.001° lat ≈ 111 m
        XCTAssertEqual(s.movingTime, 1, accuracy: 1e-9)
    }

    func testMovingTimeExcludesStops() {
        let s = TripStats.summary([sample(0, 100, speed: 2),
                                   sample(10_000, 100, speed: 2),     // moving 10 s
                                   sample(20_000, 100, speed: 0.1),   // stopped 10 s
                                   sample(30_000, 100, speed: 1)])    // moving 10 s
        XCTAssertEqual(s.movingTime, 20, accuracy: 1e-9)
    }

    func testMovingTimeSegmentCap() {
        let s = TripStats.summary([sample(0, 100, speed: 2), sample(120_000, 100, speed: 2)])
        XCTAssertEqual(s.movingTime, 60, accuracy: 1e-9)   // 120 s gap capped to 60 s
    }

    func testInvalidGpsSkippedInDistance() {
        let s = TripStats.summary([sample(0, 100, lat: 0, lon: 0, speed: 2),    // (0,0) invalid
                                   sample(1000, 100, lat: 45.001, lon: 8, speed: 2)])
        XCTAssertEqual(s.distance, 0, accuracy: 1e-9)
    }
}

/// Manual-calibration math tests (M5b). Mirrored by Android
/// `AtmosphereCalibrationTest`.
final class AtmosphereCalibrationTests: XCTestCase {

    /// TM5b.1 acceptance: the solved reference pressure fed back into the
    /// forward helper reproduces the entered altitude (<0.5 m). The live
    /// pressure is derived from the altitude + a plausible QNH so the pair
    /// is realistic (and stays inside the 30–110 kPa clamp window).
    func testSolveReferencePressureRoundTrip() {
        for known in [-200.0, 0, 500, 1500, 3000, 5500, 8000] {
            for qnhTrue in [98.0, 101.325, 103.0] {
                let p = qnhTrue * pow(1 - known / 44330, 5.255)   // station pressure at `known`
                let solved = Atmosphere.solveReferencePressure(knownAltitudeM: known, livePressureKPa: p)
                let back = Atmosphere.altitude(pressureKPa: p, referenceKPa: solved)
                XCTAssertEqual(back, known, accuracy: 0.5)
            }
        }
    }

    func testCalibrationWeightDecaysLinearly() {
        let full = Atmosphere.calibrationDecayHours * 3600
        XCTAssertEqual(Atmosphere.calibrationWeight(ageSeconds: 0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(Atmosphere.calibrationWeight(ageSeconds: full / 2), 0.5, accuracy: 1e-9)
        XCTAssertEqual(Atmosphere.calibrationWeight(ageSeconds: full), 0.0, accuracy: 1e-9)
        XCTAssertEqual(Atmosphere.calibrationWeight(ageSeconds: full * 2), 0.0, accuracy: 1e-9)
        XCTAssertEqual(Atmosphere.calibrationWeight(ageSeconds: -10), 1.0, accuracy: 1e-9)   // future-dated → fresh
    }
}

/// Real-time tracking-graph tests: the top "TRACKING ALTITUDE" graph on
/// the Stat tab keeps its barometer series live when GPS is unavailable by
/// recording a `.nan` gap for the missing series (rather than collapsing
/// that line to sea level). Exercises `History.addTrackingInformation`
/// directly — it's pure in-memory work, no Core Data.
final class TrackingGraphTests: XCTestCase {

    private let slots = 30   // History.amountOfValuesToShow (private)

    func testBarometerOnlyRecordsGapForGps() {
        let h = History()
        h.addTrackingInformation(barometerHeight: 1200, gpsAltitude: nil)
        let last = try! XCTUnwrap(h.trackingAltitudeDataSet.last)
        XCTAssertEqual(last.Value[0], 1200, accuracy: 1e-9)   // barometer drawn
        XCTAssertTrue(last.Value[1].isNaN)                    // GPS = gap
        // Auto-scale is keyed off the finite barometer sample and ignores NaN.
        XCTAssertLessThanOrEqual(h.trackingAltitudeDataSetMin, 1200)
        XCTAssertGreaterThanOrEqual(h.trackingAltitudeDataSetMax, 1200)
    }

    func testGpsOnlyRecordsGapForBarometer() {
        let h = History()   // e.g. a device with no barometer
        h.addTrackingInformation(barometerHeight: nil, gpsAltitude: 800)
        let last = try! XCTUnwrap(h.trackingAltitudeDataSet.last)
        XCTAssertTrue(last.Value[0].isNaN)                    // barometer = gap
        XCTAssertEqual(last.Value[1], 800, accuracy: 1e-9)    // GPS drawn
    }

    func testBothSeriesRecorded() {
        let h = History()
        h.addTrackingInformation(barometerHeight: 1000, gpsAltitude: 1010)
        let last = try! XCTUnwrap(h.trackingAltitudeDataSet.last)
        XCTAssertEqual(last.Value[0], 1000, accuracy: 1e-9)
        XCTAssertEqual(last.Value[1], 1010, accuracy: 1e-9)
    }

    func testSeedPlaceholdersAreNaN() {
        let h = History()
        h.addTrackingInformation(barometerHeight: 500, gpsAltitude: nil)
        XCTAssertEqual(h.trackingAltitudeDataSet.count, slots)     // seeded to full width
        // Every slot but the last real sample is a NaN placeholder (drawn as
        // nothing), so the graph fills from the right instead of showing a
        // flat sea-level line on launch.
        let seeds = h.trackingAltitudeDataSet.dropLast()
        XCTAssertTrue(seeds.allSatisfy { $0.Value[0].isNaN && $0.Value[1].isNaN })
    }

    func testAllGapSampleKeepsDefaultScale() {
        let h = History()
        // No finite sample at all (both series missing): the window falls back
        // to the default altitude range rather than producing NaN bounds.
        h.addTrackingInformation(barometerHeight: nil, gpsAltitude: nil)
        XCTAssertEqual(h.trackingAltitudeDataSetMin, h.altitudeMinDefault)
        XCTAssertEqual(h.trackingAltitudeDataSetMax, h.altitudeMaxDefault)
        XCTAssertFalse(h.trackingAltitudeDataSetMin.isNaN)
        XCTAssertFalse(h.trackingAltitudeDataSetMax.isNaN)
    }

    func testRingBufferStaysAtWidth() {
        let h = History()
        for i in 0..<(slots * 2) {
            h.addTrackingInformation(barometerHeight: CGFloat(100 + i), gpsAltitude: nil)
        }
        XCTAssertEqual(h.trackingAltitudeDataSet.count, slots)     // oldest scrolled off
        let last = try! XCTUnwrap(h.trackingAltitudeDataSet.last)
        XCTAssertEqual(last.Value[0], CGFloat(100 + slots * 2 - 1), accuracy: 1e-9)
    }
}

/// Horizon-visibility test — the Nature tab only annotates peaks actually above
/// the Earth's bulge from the observer. Mirrored by Android
/// `GeoCalculationsTest`'s `isAboveHorizon` cases.
final class HorizonVisibilityTests: XCTestCase {

    func testTallNearbyPeakIsVisible() {
        // 3000 m peak 20 km away, observer at 500 m: comfortably over the horizon.
        XCTAssertTrue(Geometry.isAboveHorizon(observerAltitude: 500, targetAltitude: 3000, distance: 20_000))
    }

    func testLowFarPeakBelowSeaLevelObserverIsHidden() {
        // A 200 m hill 120 km away, observer at the shore (0 m): its own horizon
        // reaches ~54 km, the observer adds ~0 — so at 120 km it's hidden.
        XCTAssertFalse(Geometry.isAboveHorizon(observerAltitude: 0, targetAltitude: 200, distance: 120_000))
    }

    func testHeightExtendsVisibility() {
        // The SAME far hill becomes visible once the observer is high enough that
        // the two horizon distances together span the gap.
        XCTAssertFalse(Geometry.isAboveHorizon(observerAltitude: 0, targetAltitude: 500, distance: 150_000))
        XCTAssertTrue(Geometry.isAboveHorizon(observerAltitude: 3000, targetAltitude: 500, distance: 150_000))
    }

    func testExactlyAtCombinedHorizonIsVisible() {
        // At d == √(2R·h_obs)+√(2R·h_peak) the peak just grazes the horizon (≤).
        let r = Geometry.effectiveEarthRadius
        let d = (2 * r * 100).squareRoot() + (2 * r * 100).squareRoot()
        XCTAssertTrue(Geometry.isAboveHorizon(observerAltitude: 100, targetAltitude: 100, distance: d, radius: r))
        XCTAssertFalse(Geometry.isAboveHorizon(observerAltitude: 100, targetAltitude: 100, distance: d + 1, radius: r))
    }
}
