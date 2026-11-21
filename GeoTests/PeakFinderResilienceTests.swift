//
//  PeakFinderResilienceTests.swift
//  GeoTests
//
//  Covers what turned a loaded Overpass instance into a permanently empty
//  Nature tab (#26), and what the tab shows while the network is down:
//
//  • `PeakFinderResilienceTests` — the pure rules: when a previous nearby-peak
//    result may be reused, and the mirror list a search fails over across.
//  • `PeakFinderOutageTests` — whole searches against a stubbed Overpass and an
//    injected clock: local peaks shown at once and through an outage, nothing
//    aged out while nothing can be confirmed, the "possibly outdated" flag,
//    the retry backoff and the restored snapshot.
//
//  NO test touches the real network: `OverpassStub` answers every Overpass
//  request (and fails any elevation lookup), and every stubbed peak carries an
//  `ele` tag, so no DEM lookup is needed in the first place.
//

import XCTest
import Combine
import CoreLocation
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

    /// Nothing has ever loaded and the last attempt failed seconds ago: the
    /// screen stays as it is instead of firing another request at a loaded
    /// mirror on every 5 s tick. The next attempt happens when the backoff
    /// expires — which is the only thing standing between an outage and a
    /// client that DDoSes a shared public endpoint.
    func testFailedSearchIsNotRetriedUntilBackoffExpiresWithNothingOnScreen() {
        XCTAssertTrue(canReuse(successAge: nil, failureAge: -retryBackoff / 2))
        XCTAssertFalse(canReuse(successAge: nil, failureAge: -2 * retryBackoff))
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

// MARK: - Whole searches against a stubbed Overpass

final class PeakFinderOutageTests: XCTestCase {

    /// A valley in the Pennine Alps. Every stubbed peak lies inside the live
    /// 5 km query and above the horizon from the 2000 m observer.
    private var here: CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: 45.9, longitude: 7.6),
                   altitude: 2000, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date())
    }
    private let observerAltitude: Double = 2000

    private let alpha = StubPeak(name: "Stub Alpha", lat: 45.92, lon: 7.60, ele: 3100)
    private let beta = StubPeak(name: "Stub Beta", lat: 45.90, lon: 7.63, ele: 2900)
    private let gamma = StubPeak(name: "Stub Gamma", lat: 45.88, lon: 7.60, ele: 3300)

    /// ~9 km from `here`: a downloaded pack that covers this spot.
    private let packPeak = NearbyPeak(name: "Pack Peak",
                                      coordinate: CLLocationCoordinate2D(latitude: 45.95, longitude: 7.70),
                                      altitude: 3500, distance: 0, bearing: 0)
    /// ~100 km away: beyond the 80 km render distance, so it covers nothing here.
    private let farPackPeak = NearbyPeak(name: "Far Pack Peak",
                                         coordinate: CLLocationCoordinate2D(latitude: 46.8, longitude: 7.6),
                                         altitude: 3000, distance: 0, bearing: 0)

    /// What a previous run would have left on disk around `here`.
    private let snapshotEntries: [(name: String, lat: Double, lon: Double, alt: Double)] = [
        ("Snap One", 45.93, 7.58, 3200),
        ("Snap Two", 45.87, 7.65, 3000)
    ]

    override func setUp() {
        super.setUp()
        Self.removeSnapshot()
        OverpassStub.install()
    }

    override func tearDown() {
        OverpassStub.uninstall()
        Self.removeSnapshot()
        XCTAssertEqual(OverpassStub.elevationRequestCount, 0,
                       "a stubbed peak without `ele` sent a DEM lookup")
        super.tearDown()
    }

    // MARK: Helpers

    private static func removeSnapshot() {
        if let url = PeakFinder.cacheURL { try? FileManager.default.removeItem(at: url) }
    }

    /// Write a snapshot in `PeakFinder`'s on-disk format, as a previous run would.
    private func writeSnapshot(savedAt: Date) throws {
        let url = try XCTUnwrap(PeakFinder.cacheURL)
        let object: [String: Any] = [
            "centerLatitude": 45.9,
            "centerLongitude": 7.6,
            // `JSONEncoder`'s default `Date` strategy: seconds since 2001-01-01.
            "savedAt": savedAt.timeIntervalSinceReferenceDate,
            "entries": snapshotEntries.map {
                ["name": $0.name, "latitude": $0.lat, "longitude": $0.lon, "altitude": $0.alt] as [String: Any]
            }
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
    }

    private func readSnapshot() throws -> [String: Any] {
        let data = try Data(contentsOf: try XCTUnwrap(PeakFinder.cacheURL))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Bundled-data stand-in: one famous summit ~13 km from `here`.
    private func knownMountains() -> MountainData {
        let coordinates = MountainCoordinates()
        coordinates.latitude = 45.85
        coordinates.longitude = 7.75
        let mountain = MountainInfo()
        mountain.name = "Known Summit"
        mountain.height = 4000
        mountain.coordinates = coordinates
        let list = MountainList()
        list.mountains = [mountain]
        let data = MountainData()
        data.highest = list
        return data
    }

    @MainActor
    private func makeFinder(_ clock: TestClock) -> PeakFinder {
        let finder = PeakFinder()
        finder.now = { clock.now }
        return finder
    }

    @MainActor
    private func search(_ finder: PeakFinder, offline: [NearbyPeak] = [],
                        known: MountainData? = nil, at location: CLLocation? = nil) async {
        await finder.searchPeaks(near: location ?? here, mountainsData: known,
                                 offlinePeaks: offline, observerAltitude: observerAltitude)
    }

    /// A search left running in the background, for "what is on screen while
    /// the network is still being asked".
    @MainActor
    private func startSearch(_ finder: PeakFinder, offline: [NearbyPeak] = [],
                             known: MountainData? = nil) -> Task<Void, Never> {
        let location = here
        let altitude = observerAltitude
        return Task { @MainActor in
            await finder.searchPeaks(near: location, mountainsData: known,
                                     offlinePeaks: offline, observerAltitude: altitude)
        }
    }

    @MainActor
    private func names(_ finder: PeakFinder) -> [String] { finder.peaks.map(\.name).sorted() }

    /// Never throws: a test that holds a request open must still release it and
    /// await its search, or a later mirror attempt could outlive the stub.
    @MainActor
    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting until \(what)") }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor
    private func expectRealGeometry(_ peaks: [NearbyPeak], from location: CLLocation,
                                    file: StaticString = #filePath, line: UInt = #line) {
        for peak in peaks {
            let summit = CLLocation(latitude: peak.coordinate.latitude, longitude: peak.coordinate.longitude)
            XCTAssertEqual(peak.distance, location.distance(from: summit), accuracy: 1,
                           "\(peak.name): the overlay fades and scales markers by distance",
                           file: file, line: line)
            XCTAssertEqual(peak.bearing, Geometry.bearing(from: location.coordinate, to: peak.coordinate),
                           accuracy: 0.01, "\(peak.name)", file: file, line: line)
        }
    }

    // MARK: Local peaks are always shown

    /// The 1.2 promise: with NO signal the bundled summits and a downloaded
    /// pack still name the mountains. The failure branch used to return before
    /// either was merged, so a downloaded pack showed 0 peaks offline.
    @MainActor
    func testLocalPeaksAreShownWithNoSignal() async {
        let finder = makeFinder(TestClock())
        await search(finder, offline: [packPeak], known: knownMountains())

        XCTAssertNotNil(finder.lastSearchError, "every mirror failed")
        XCTAssertEqual(OverpassStub.requestCount, PeakFinder.overpassEndpoints.count)
        XCTAssertEqual(names(finder), ["Known Summit", "Pack Peak"],
                       "local sources must survive a failed search")
        expectRealGeometry(finder.peaks, from: here)
    }

    /// Local peaks must not wait for the network: a failover across every
    /// mirror can take ~25 s, and with no signal that wait used to end in
    /// nothing at all.
    @MainActor
    func testLocalPeaksArePublishedBeforeTheNetworkAnswers() async {
        OverpassStub.reply { _, index in index == 0 ? .hold : .failure(.notConnectedToInternet) }
        let finder = makeFinder(TestClock())
        let search = startSearch(finder, offline: [packPeak], known: knownMountains())
        await waitUntil("the first mirror holds the request") { OverpassStub.heldCount == 1 }

        // The search is still waiting on that first mirror.
        XCTAssertEqual(names(finder), ["Known Summit", "Pack Peak"],
                       "local peaks must be on screen while the mirrors are still being asked")
        expectRealGeometry(finder.peaks, from: here)

        OverpassStub.releaseHeld(with: .failure(.timedOut))
        await search.value
        XCTAssertEqual(names(finder), ["Known Summit", "Pack Peak"])
    }

    // MARK: Nothing expires during an outage

    /// `peakTTL` (1 h) used to prune on every path, so an outage longer than an
    /// hour emptied the horizon it was meant to keep. Nothing can be
    /// re-confirmed during an outage, so nothing may expire.
    @MainActor
    func testCarriedOverPeaksSurviveAnOutageLongerThanTheTTL() async {
        let clock = TestClock()
        let finder = makeFinder(clock)
        let answer = OverpassStub.answer([alpha, beta])
        OverpassStub.reply { _, _ in .body(answer) }
        await search(finder)
        XCTAssertEqual(names(finder), ["Stub Alpha", "Stub Beta"])

        OverpassStub.reply { _, _ in .failure(.notConnectedToInternet) }
        for hour in 1...2 {
            clock.advance(by: 61 * 60)   // past the TTL, the cache age and the backoff
            let asked = OverpassStub.requestCount
            await search(finder)
            XCTAssertGreaterThan(OverpassStub.requestCount, asked, "hour \(hour): the retry went out")
            XCTAssertEqual(names(finder), ["Stub Alpha", "Stub Beta"],
                           "hour \(hour): an outage must not expire what it cannot re-confirm")
            XCTAssertTrue(finder.peaksAreStale, "hour \(hour)")
        }
    }

    @MainActor
    func testRestoredSnapshotSurvivesAnOutageLongerThanTheTTL() async throws {
        let clock = TestClock()
        try writeSnapshot(savedAt: clock.now.addingTimeInterval(-10 * 60))
        let finder = makeFinder(clock)
        await search(finder)
        XCTAssertEqual(names(finder), ["Snap One", "Snap Two"])
        XCTAssertTrue(finder.peaksAreStale)

        clock.advance(by: 61 * 60)
        await search(finder)
        XCTAssertEqual(names(finder), ["Snap One", "Snap Two"],
                       "the restored snapshot is what an outage is supposed to show")
        XCTAssertTrue(finder.peaksAreStale)
    }

    /// The other half of the rule: a CONFIRMED answer still expires what it no
    /// longer returns, so peaks do not accumulate for ever.
    @MainActor
    func testConfirmedAnswerStillExpiresPeaksItNoLongerReturns() async {
        let clock = TestClock()
        let finder = makeFinder(clock)
        let first = OverpassStub.answer([alpha, beta])
        OverpassStub.reply { _, _ in .body(first) }
        await search(finder)

        clock.advance(by: 61 * 60)
        let second = OverpassStub.answer([gamma])
        OverpassStub.reply { _, _ in .body(second) }
        await search(finder)
        XCTAssertEqual(names(finder), ["Stub Gamma"])
        XCTAssertFalse(finder.peaksAreStale)
    }

    // MARK: The "possibly outdated" flag

    @MainActor
    func testStaleFlagAndErrorSurviveTheReuseTick() async {
        let clock = TestClock()
        let finder = makeFinder(clock)
        let answer = OverpassStub.answer([alpha, beta])
        OverpassStub.reply { _, _ in .body(answer) }
        await search(finder)

        clock.advance(by: 16 * 60)   // older than the 15 min cache age
        OverpassStub.reply { _, _ in .failure(.notConnectedToInternet) }
        await search(finder)
        XCTAssertTrue(finder.peaksAreStale)
        let error = finder.lastSearchError
        XCTAssertNotNil(error)

        let asked = OverpassStub.requestCount
        clock.advance(by: 5)         // the next refresh tick, inside the 60 s backoff
        await search(finder)
        XCTAssertEqual(OverpassStub.requestCount, asked, "a tick inside the backoff must not ask again")
        XCTAssertTrue(finder.peaksAreStale, "the reuse path confirms nothing, so the label stays")
        XCTAssertEqual(finder.lastSearchError, error)
        XCTAssertEqual(names(finder), ["Stub Alpha", "Stub Beta"])
    }

    @MainActor
    func testInFlightTickKeepsTheStaleFlagAndSuccessClearsIt() async {
        let clock = TestClock()
        let finder = makeFinder(clock)
        let answer = OverpassStub.answer([alpha, beta])
        OverpassStub.reply { _, _ in .body(answer) }
        await search(finder)

        clock.advance(by: 16 * 60)
        OverpassStub.reply { _, _ in .failure(.notConnectedToInternet) }
        await search(finder)
        XCTAssertTrue(finder.peaksAreStale)
        let error = finder.lastSearchError
        XCTAssertNotNil(error)

        clock.advance(by: 61)        // the backoff has run out
        let first = OverpassStub.requestCount
        OverpassStub.reply { _, index in index == first ? .hold : .failure(.notConnectedToInternet) }
        let retry = startSearch(finder)
        await waitUntil("the retry holds a request") { OverpassStub.heldCount == 1 }

        await search(finder)         // a refresh tick lands mid-search
        XCTAssertTrue(finder.peaksAreStale, "an in-flight tick confirms nothing")
        XCTAssertEqual(finder.lastSearchError, error)

        OverpassStub.releaseHeld(with: .body(answer))
        await retry.value
        XCTAssertFalse(finder.peaksAreStale, "a confirmed answer clears the label")
        XCTAssertNil(finder.lastSearchError)
        XCTAssertEqual(names(finder), ["Stub Alpha", "Stub Beta"])
    }

    /// A downloaded pack is the explicit offline answer: labelling it "possibly
    /// outdated" in the no-signal case it exists for would be wrong, and v1.3
    /// never did.
    @MainActor
    func testOfflinePackCoveringHereIsNeverPossiblyOutdated() async {
        let clock = TestClock()
        let finder = makeFinder(clock)
        let answer = OverpassStub.answer([alpha, beta])
        OverpassStub.reply { _, _ in .body(answer) }
        await search(finder, offline: [packPeak])
        XCTAssertFalse(finder.peaksAreStale)

        OverpassStub.reply { _, _ in .failure(.notConnectedToInternet) }
        clock.advance(by: 16 * 60)
        await search(finder, offline: [packPeak])
        XCTAssertNotNil(finder.lastSearchError, "the search did fail")
        XCTAssertEqual(names(finder), ["Pack Peak", "Stub Alpha", "Stub Beta"])
        XCTAssertFalse(finder.peaksAreStale, "a pack covers here")

        // A pack whose peaks all lie beyond the 80 km render distance covers
        // nothing here: the carried-over peaks are possibly outdated again.
        clock.advance(by: 61)
        await search(finder, offline: [farPackPeak])
        XCTAssertTrue(finder.peaksAreStale)
    }

    @MainActor
    func testRestoredSnapshotUnderAnOfflinePackIsNotPossiblyOutdated() async throws {
        let clock = TestClock()
        try writeSnapshot(savedAt: clock.now.addingTimeInterval(-10 * 60))
        let finder = makeFinder(clock)
        await search(finder, offline: [packPeak])
        XCTAssertEqual(names(finder), ["Pack Peak", "Snap One", "Snap Two"])
        XCTAssertFalse(finder.peaksAreStale)
    }

    // MARK: The retry backoff runs from completion

    @MainActor
    func testRetryBackoffRunsFromWhenTheFailureArrived() async {
        let clock = TestClock()
        let finder = makeFinder(clock)
        // Each mirror takes 10 s to give up, so the failure arrives 30 s after
        // the search began.
        OverpassStub.reply { _, _ in clock.advance(by: 10); return .failure(.timedOut) }
        await search(finder)
        let asked = OverpassStub.requestCount

        clock.advance(by: 59)
        await search(finder)
        XCTAssertEqual(OverpassStub.requestCount, asked,
                       "59 s after the failure arrived is still inside the 60 s backoff")

        clock.advance(by: 2)
        await search(finder)
        XCTAssertGreaterThan(OverpassStub.requestCount, asked, "the backoff has run out")
    }

    // MARK: The persisted snapshot

    @MainActor
    func testRestoredSnapshotIsPublishedWithRealGeometry() async throws {
        let clock = TestClock()
        try writeSnapshot(savedAt: clock.now.addingTimeInterval(-60 * 60))
        let finder = makeFinder(clock)
        var published: [[NearbyPeak]] = []
        let subscription = finder.$peaks.sink { published.append($0) }
        OverpassStub.reply { _, index in index == 0 ? .hold : .failure(.notConnectedToInternet) }
        let search = startSearch(finder)
        await waitUntil("the search reaches the network") { OverpassStub.heldCount == 1 }

        let first = published.first { !$0.isEmpty } ?? []
        XCTAssertEqual(first.map(\.name).sorted(), ["Snap One", "Snap Two"],
                       "the snapshot is on screen before the network answers")
        expectRealGeometry(first, from: here)
        XCTAssertTrue(finder.peaksAreStale, "restored from disk, nothing confirmed yet")

        OverpassStub.releaseHeld(with: .failure(.notConnectedToInternet))
        await search.value
        subscription.cancel()
    }

    @MainActor
    func testSnapshotCentreIsStoredRoundedToTwoDecimals() async throws {
        let finder = makeFinder(TestClock())
        let answer = OverpassStub.answer([alpha])
        OverpassStub.reply { _, _ in .body(answer) }
        let precise = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 45.91234, longitude: 7.65678),
                                 altitude: 2000, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date())
        await search(finder, at: precise)

        let snapshot = try readSnapshot()
        XCTAssertEqual(try XCTUnwrap(snapshot["centerLatitude"] as? Double), 45.91, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(snapshot["centerLongitude"] as? Double), 7.66, accuracy: 1e-9)
        let entries = try XCTUnwrap(snapshot["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.compactMap { $0["latitude"] as? Double }, [45.92],
                       "peak entries keep their exact position")
    }
}

// MARK: - Test doubles

/// A peak as an Overpass `out body` node returns it; always with an `ele` tag.
struct StubPeak: Sendable {
    let name: String
    let lat: Double
    let lon: Double
    let ele: Int
}

/// Stands in for every Overpass mirror, so a search runs with NO real network.
/// `URLProtocol.registerClass` puts it in front of `URLSession.shared`, which
/// is what `PeakFinder` fetches with. A test-installed handler picks each reply
/// from the request (its host) and its 0-based index since `install()` — the
/// index, not the host, is what identifies "the first mirror tried", because
/// the mirror a search starts with rotates process-wide.
final class OverpassStub: URLProtocol, @unchecked Sendable {

    enum Reply: Sendable {
        /// The transport never got an answer (no signal, DNS, timeout …).
        case failure(URLError.Code)
        /// An HTTP answer with a JSON body.
        case body(String, status: Int = 200)
        /// Held open until `releaseHeld(with:)`: a mirror slow to answer.
        case hold
    }

    typealias Handler = @Sendable (_ request: URLRequest, _ index: Int) -> Reply

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var held: [OverpassStub] = []
    nonisolated(unsafe) private static var elevationRequests = 0

    /// Start intercepting. Until `reply` says otherwise every request fails
    /// the way it does with no signal.
    static func install() {
        lock.withLock {
            handler = { _, _ in .failure(.notConnectedToInternet) }
            requests = []
            held = []
            elevationRequests = 0
        }
        _ = URLProtocol.registerClass(OverpassStub.self)
    }

    static func reply(_ newHandler: @escaping Handler) {
        lock.withLock { handler = newHandler }
    }

    /// Fail anything still held, then stop intercepting.
    static func uninstall() {
        reply { _, _ in .failure(.cancelled) }
        releaseHeld(with: .failure(.cancelled))
        URLProtocol.unregisterClass(OverpassStub.self)
    }

    static var requestCount: Int { lock.withLock { requests.count } }
    static var requestedHosts: [String] { lock.withLock { requests.compactMap { $0.url?.host } } }
    static var heldCount: Int { lock.withLock { held.count } }
    static var elevationRequestCount: Int { lock.withLock { elevationRequests } }

    /// Answer every held request with `reply`.
    static func releaseHeld(with reply: Reply) {
        let pending = lock.withLock { () -> [OverpassStub] in
            defer { held = [] }
            return held
        }
        pending.forEach { $0.respond(reply) }
    }

    /// An Overpass JSON answer for `peaks`, with an optional `remark` exactly
    /// where Overpass puts one.
    static func answer(_ peaks: [StubPeak], remark: String? = nil) -> String {
        var object: [String: Any] = [
            "version": 0.6,
            "generator": "Overpass API (GeoTests stub)",
            "elements": peaks.enumerated().map { index, peak in
                ["type": "node", "id": index + 1, "lat": peak.lat, "lon": peak.lon,
                 "tags": ["name": peak.name, "natural": "peak", "ele": String(peak.ele)]] as [String: Any]
            }
        ]
        if let remark { object["remark"] = remark }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return url.path.hasSuffix("/interpreter") || url.host == "api.open-meteo.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.host == "api.open-meteo.com" {
            // A DEM lookup means a stubbed peak lost its `ele` tag. Fail it
            // rather than let it reach the network; `tearDown` reports it.
            Self.lock.withLock { Self.elevationRequests += 1 }
            respond(.failure(.notConnectedToInternet))
            return
        }
        let (index, handler) = Self.lock.withLock { () -> (Int, Handler?) in
            Self.requests.append(request)
            return (Self.requests.count - 1, Self.handler)
        }
        respond(handler?(request, index) ?? .failure(.notConnectedToInternet))
    }

    override func stopLoading() {}

    private func respond(_ reply: Reply) {
        switch reply {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .body(let json, let status):
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                                 headerFields: ["Content-Type": "application/json"]) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .hold:
            Self.lock.withLock { Self.held.append(self) }
        }
    }
}

/// A controllable clock for `PeakFinder.now`. Thread-safe, because a stub reply
/// (on a URL-loading thread) may advance it to model a slow failover.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date()) { current = start }

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}
