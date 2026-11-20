//
//  PeakFinderResilienceTests.swift
//  GeoTests
//
//  Covers the two rules that turned a loaded Overpass instance into a
//  permanently empty Nature tab (#26): when a previous nearby-peak result may
//  be reused, and the mirror list a search fails over across.
//
//  Both are pure/static on purpose, so no network and no location manager is
//  involved — the behaviours below are exactly the ones a live device cannot
//  reproduce deterministically.
//

import XCTest
@testable import Geo

final class PeakFinderResilienceTests: XCTestCase {

    /// Mirror the production tuning; if someone changes the constants in
    /// `PeakFinder` these tests still describe the *rules*, not the numbers.
    private let maxCacheAge: TimeInterval = 15 * 60
    private let retryBackoff: TimeInterval = 60

    private func canReuse(successAge: TimeInterval?, failureAge: TimeInterval?,
                          now: Date = Date()) -> Bool {
        PeakFinder.canReuseResult(now: now,
                                  lastSuccessAt: successAge.map { now.addingTimeInterval($0) },
                                  lastFailureAt: failureAge.map { now.addingTimeInterval($0) },
                                  maxCacheAge: maxCacheAge,
                                  retryBackoff: retryBackoff)
    }

    func testNothingSearchedYetIsNeverReused() {
        XCTAssertFalse(canReuse(successAge: nil, failureAge: nil))
    }

    func testFreshResultIsReusedWithoutAskingTheNetwork() {
        XCTAssertTrue(canReuse(successAge: -60, failureAge: nil))
    }

    /// The regression: the old guard only looked at distance, so a stationary
    /// user (or one whose location stream iOS paused) never refetched.
    func testStaleResultIsRefetchedEvenWithoutMovement() {
        XCTAssertFalse(canReuse(successAge: -2 * maxCacheAge, failureAge: nil))
    }

    /// Once stale, the result is still shown while the backoff from a failed
    /// attempt runs — so the peaks on screen are never dropped for nothing, and
    /// a loaded endpoint is not hammered on every 5 s refresh tick.
    func testStaleResultIsKeptWhileRetryBackoffRuns() {
        XCTAssertTrue(canReuse(successAge: -2 * maxCacheAge, failureAge: -retryBackoff / 2))
    }

    func testStaleResultIsRefetchedOnceBackoffExpires() {
        XCTAssertFalse(canReuse(successAge: -2 * maxCacheAge, failureAge: -2 * retryBackoff))
    }

    func testSearchFailsOverAcrossDistinctMirrors() {
        XCTAssertGreaterThanOrEqual(PeakFinder.overpassEndpoints.count, 3,
                                    "a single Overpass host is the outage we are fixing")
        let hosts = Set(PeakFinder.overpassEndpoints.compactMap { URL(string: $0)?.host })
        XCTAssertEqual(hosts.count, PeakFinder.overpassEndpoints.count,
                       "mirrors must be different hosts, not the same box twice")
        XCTAssertTrue(PeakFinder.overpassEndpoints.allSatisfy { $0.hasSuffix("/api/interpreter") })
    }

    func testRotationVisitsEveryMirrorExactlyOnce() {
        let count = PeakFinder.overpassEndpoints.count
        for start in [-4, -1, 0, 1, count, count + 7] {
            let rotated = PeakFinder.rotatedEndpoints(startingAt: start)
            XCTAssertEqual(rotated.count, count)
            XCTAssertEqual(Set(rotated), Set(PeakFinder.overpassEndpoints),
                           "rotation must cover every mirror, never duplicate one")
        }
        XCTAssertEqual(PeakFinder.rotatedEndpoints(startingAt: 1).first,
                       PeakFinder.overpassEndpoints[1],
                       "the cursor must actually change which mirror is tried first")
    }
}
