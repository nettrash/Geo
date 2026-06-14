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
