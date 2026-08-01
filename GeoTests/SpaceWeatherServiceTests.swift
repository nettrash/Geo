//
//  SpaceWeatherServiceTests.swift
//  GeoTests
//
//  The SWPC parse contract and the on-disk cache round-trip. `GeomagneticTests`
//  covers the pure core and hands these two subjects here, to the file that
//  owns the wire format.
//
//  Every numbered rule below is a way this integration fails SILENTLY — no
//  crash, no error, just a card that is confidently wrong about which evening
//  it is describing — so each one is a named test rather than a line inside a
//  bigger one. The numbering matches the comments in `SpaceWeatherService`
//  itself, and Android `me.nettrash.geo.util.SpaceWeatherRepository` implements
//  the same list in the same order.
//
//  Nothing here touches the network: the request-shape and cache rules run
//  against a `URLProtocol` stub and a temporary directory, both injected
//  through the service's own two seams.
//

import XCTest
@testable import Geo

final class SpaceWeatherServiceTests: XCTestCase {

    /// Fixed clock, the same instant the Geomagnetic fixtures use
    /// (nowMs 1_700_000_000_000 — 2023-11-14T22:13:20Z).
    private let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)

    /// UTC, always injected — a test that reads the device's calendar passes
    /// in Cupertino and fails in Auckland.
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    // MARK: - Wire fixtures

    /// The live shape of the product, verified against the endpoint: an array
    /// of objects, `noaa_scale` null, three bins carrying all three provenance
    /// tags, oldest first.
    private static let objectRows = """
    [{"time_tag":"2026-07-18T00:00:00","kp":1.67,"observed":"observed","noaa_scale":null},
     {"time_tag":"2026-07-18T03:00:00","kp":2.33,"observed":"estimated","noaa_scale":null},
     {"time_tag":"2026-07-18T06:00:00","kp":5.00,"observed":"predicted","noaa_scale":null}]
    """

    /// The very same three bins, emitted in a different order.
    private static let shuffledObjectRows = """
    [{"time_tag":"2026-07-18T06:00:00","kp":5.00,"observed":"predicted","noaa_scale":null},
     {"time_tag":"2026-07-18T00:00:00","kp":1.67,"observed":"observed","noaa_scale":null},
     {"time_tag":"2026-07-18T03:00:00","kp":2.33,"observed":"estimated","noaa_scale":null}]
    """

    /// The same three bins in the legacy header-row form, with the separator
    /// written as a space, milliseconds attached and Kp quoted — which is how
    /// the sibling products under `/products/` still emit it.
    private static let legacyRows = """
    [["time_tag","Kp","observed","noaa_scale"],
     ["2026-07-18 00:00:00.000","1.67","observed",null],
     ["2026-07-18 03:00:00.000","2.33","estimated",null],
     ["2026-07-18 06:00:00.000","5.00","predicted",null]]
    """

    private func parse(_ json: String) -> KpSeries? {
        SpaceWeatherService.parseKpForecast(Data(json.utf8), fetchedAt: fetchedAt)
    }

    // MARK: - 1. The provenance field is named `observed`

    func testProvenanceComesFromTheObservedField() throws {
        // 1. SWPC calls it `observed`, not `provenance`, and its values are the
        //    exact strings the enum is backed by, so they map straight through.
        let series = try XCTUnwrap(parse(Self.objectRows))
        XCTAssertEqual(series.fetchedAt, fetchedAt)
        XCTAssertEqual(series.points.map(\.provenance), [.observed, .estimated, .predicted])
        XCTAssertEqual(series.points.map(\.kp), [1.67, 2.33, 5.00])
    }

    func testAMislabelledProvenanceFieldFallsBackToForecast() throws {
        // A row that names the field `provenance` is a field we no longer
        // recognise. Calling the number *observed* on that basis would be a
        // claim we cannot support, so it degrades to `.predicted` — which the
        // card captions "forecast".
        let mislabelled = try XCTUnwrap(parse("""
        [{"time_tag":"2026-07-18T00:00:00","kp":1.67,"provenance":"observed"}]
        """))
        XCTAssertEqual(mislabelled.points.first?.provenance, .predicted)

        // An unrecognised value in the right field degrades the same way.
        let unknown = try XCTUnwrap(parse("""
        [{"time_tag":"2026-07-18T00:00:00","kp":1.67,"observed":"provisional"}]
        """))
        XCTAssertEqual(unknown.points.first?.provenance, .predicted)
    }

    // MARK: - 2. Always sort by time_tag, never by array position

    func testShuffledInputProducesAnIdenticalSeries() throws {
        // 2. SWPC's ordering is inconsistent across products — `/products/*`
        //    oldest first, `alerts.json` and `json/rtsw/*` newest first — so
        //    the same rows in a different order must decode to the same series.
        //    Equal as whole values, not merely "the same set": if anything
        //    downstream ever indexed by position this fails here first.
        let ordered = try XCTUnwrap(parse(Self.objectRows))
        let shuffled = try XCTUnwrap(parse(Self.shuffledObjectRows))
        XCTAssertEqual(shuffled, ordered)
        XCTAssertEqual(shuffled.points.map(\.time), shuffled.points.map(\.time).sorted())
        XCTAssertEqual(shuffled.points.first?.provenance, .observed)
        XCTAssertEqual(shuffled.points.last?.provenance, .predicted)
    }

    // MARK: - 3. time_tag has no zone suffix and IS UTC

    func testTimeTagIsUTCWhateverTheDeviceZone() throws {
        // 3. Read in the device's own zone this is silently wrong by up to 14
        //    hours and nothing on the card looks broken while it happens — the
        //    bins simply describe the wrong evening. The device is forced to
        //    UTC+13 for the duration and restored in `defer`, so the override
        //    is undone however this test leaves.
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        NSTimeZone.default = TimeZone(secondsFromGMT: 13 * 3600) ?? .gmt

        let parsed = try XCTUnwrap(SpaceWeatherService.parseSwpcTimeTag("2026-07-25T15:00:00"))
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: parsed)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 7)
        XCTAssertEqual(parts.day, 25)
        XCTAssertEqual(parts.hour, 15)
        XCTAssertEqual(parts.minute, 0)
        XCTAssertEqual(parts.second, 0)

        // The override really is in effect: the same wall-clock reading in the
        // device zone is a different instant, which is exactly the 13 hours a
        // default `ISO8601DateFormatter` would have lost here.
        var device = Calendar(identifier: .gregorian)
        device.timeZone = NSTimeZone.default
        let asLocal = try XCTUnwrap(device.date(from: DateComponents(year: 2026, month: 7, day: 25, hour: 15)))
        XCTAssertNotEqual(asLocal, parsed)
        XCTAssertEqual(parsed.timeIntervalSince(asLocal), 13 * 3600, accuracy: 1)

        // And the whole-product path agrees with the single-tag path.
        let series = try XCTUnwrap(parse("""
        [{"time_tag":"2026-07-25T15:00:00","kp":1.67,"observed":"observed","noaa_scale":null}]
        """))
        XCTAssertEqual(series.points.first?.time, parsed)
    }

    // MARK: - 4. Dual-format parse

    func testLegacyHeaderRowFormDecodesToTheSameSeries() throws {
        // 4. Objects first, then the header-row array-of-arrays. Both forms of
        //    the same three bins must produce the same series, including the
        //    separator and millisecond normalisation the legacy rows need.
        let modern = try XCTUnwrap(parse(Self.objectRows))
        let legacy = try XCTUnwrap(parse(Self.legacyRows))
        XCTAssertEqual(legacy, modern)
    }

    func testLegacyFormWithoutTheColumnsWeNeedReturnsNil() {
        // A header row we cannot read is a format we do not understand, not an
        // empty product: nil, so the caller keeps the cache.
        XCTAssertNil(parse("""
        [["time_tag","planetary_k_index"],
         ["2026-07-18 00:00:00.000","1.67"]]
        """))
    }

    // MARK: - 5. noaa_scale is ignored entirely

    func testNoaaScaleIsIgnoredWhetherNullOrPopulated() throws {
        // 5. It is null in every observed row, and its storm-time content is
        //    unverified. G is derived locally from Kp by the floor rule, so a
        //    fixture claiming "G3" over a Kp 1.67 bin must change nothing at
        //    all — not the series, not the G scale.
        let nulls = try XCTUnwrap(parse("""
        [{"time_tag":"2026-07-18T00:00:00","kp":1.67,"observed":"observed","noaa_scale":null}]
        """))
        let claimed = try XCTUnwrap(parse("""
        [{"time_tag":"2026-07-18T00:00:00","kp":1.67,"observed":"observed","noaa_scale":"G3"}]
        """))
        XCTAssertEqual(claimed, nulls)
        XCTAssertEqual(Geomagnetic.gScale(kp: try XCTUnwrap(claimed.points.first).kp), .g0)
    }

    // MARK: - 6. Kp is parsed as a Double, never string-matched

    func testScientificNotationKpParsesAsADouble() throws {
        // 6. Sibling products emit `2.5999999e+000`, quoted in the legacy form
        //    and bare in the modern one. Only a real numeric parse survives
        //    either; matching on the digits would drop the row.
        let quoted = try XCTUnwrap(parse("""
        [{"time_tag":"2026-07-18T00:00:00","kp":"2.5999999e+000","observed":"observed"}]
        """))
        XCTAssertEqual(try XCTUnwrap(quoted.points.first).kp, 2.6, accuracy: 1e-6)

        let bare = try XCTUnwrap(parse("""
        [{"time_tag":"2026-07-18T00:00:00","kp":2.5999999e+000,"observed":"observed"}]
        """))
        XCTAssertEqual(try XCTUnwrap(bare.points.first).kp, 2.6, accuracy: 1e-6)

        // Integers and quoted decimals land on the same Double too.
        let mixed = try XCTUnwrap(parse("""
        [{"time_tag":"2026-07-18T00:00:00","kp":5,"observed":"observed"},
         {"time_tag":"2026-07-18T03:00:00","kp":"5.0","observed":"observed"}]
        """))
        XCTAssertEqual(mixed.points.map(\.kp), [5.0, 5.0])
    }

    // MARK: - 7. Never a conditional GET, and never a query string

    func testEndpointIsAConstantURLWithNoQueryString() {
        // The property the privacy policy claims: the request is byte-identical
        // for every copy of the app on Earth. Spelled as a literal in the
        // service so no parameter can be appended without anyone noticing.
        XCTAssertEqual(SpaceWeatherService.endpoint.absoluteString,
                       "https://services.swpc.noaa.gov/products/noaa-planetary-k-index-forecast.json")
        XCTAssertNil(URLComponents(url: SpaceWeatherService.endpoint,
                                   resolvingAgainstBaseURL: false)?.query)
    }

    func testRequestIsNeverConditional() async throws {
        // 7. SWPC rewrites its whole tree every minute, so `last-modified` is
        //    always seconds old regardless of when the content changed and an
        //    `If-Modified-Since` would never hit. Freshness comes from the
        //    payload's own `time_tag` and our fetch stamp instead.
        let directory = try temporaryDirectory()
        StubURLProtocol.reset(responder: { _ in (200, Data(Self.objectRows.utf8)) })
        let service = SpaceWeatherService(session: Self.stubSession(), cacheDirectory: directory)

        await service.refreshIfStale(now: fetchedAt)

        let requests = StubURLProtocol.captured()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "If-Modified-Since"))
        XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url, SpaceWeatherService.endpoint)
        XCTAssertNil(request.url?.query)
    }

    // MARK: - 8. A failed or empty fetch never overwrites a good cache

    func testFailedOrEmptyFetchNeverOverwritesAGoodCache() async throws {
        // 8. A cache that still answers "you need about Kp 5+ here" beats an
        //    empty card, so only a successful, non-empty parse may replace it.
        //    Each probe steps the clock past the 3 h fetch gate; the cached
        //    series stays 9 h old or more throughout so a fetch is always due.
        let directory = try temporaryDirectory()
        let cachedAt = fetchedAt.addingTimeInterval(-9 * 3600)
        let good = KpSeries(fetchedAt: cachedAt,
                            points: [KpPoint(time: cachedAt, kp: 6.0, provenance: .observed)])
        let service = SpaceWeatherService(session: Self.stubSession(), cacheDirectory: directory)
        await service.writeCache(good)

        StubURLProtocol.reset(responder: { _ in (200, Data("{ not json".utf8)) })
        await service.refreshIfStale(now: fetchedAt)
        var snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.series, good, "malformed body")

        StubURLProtocol.reset(responder: { _ in (200, Data("[]".utf8)) })
        await service.refreshIfStale(now: fetchedAt.addingTimeInterval(4 * 3600))
        snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.series, good, "empty product")

        StubURLProtocol.reset(responder: { _ in (500, Data()) })
        await service.refreshIfStale(now: fetchedAt.addingTimeInterval(8 * 3600))
        snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.series, good, "HTTP 500")

        // The control: a good product DOES replace it, so the three assertions
        // above are not passing because nothing can ever update.
        StubURLProtocol.reset(responder: { _ in (200, Data(Self.objectRows.utf8)) })
        await service.refreshIfStale(now: fetchedAt.addingTimeInterval(12 * 3600))
        snapshot = await service.snapshot()
        XCTAssertEqual(try XCTUnwrap(snapshot.series).points.count, 3)
        XCTAssertNotEqual(snapshot.series, good)
    }

    // MARK: - 9. A row with a null or absent kp is skipped

    func testRowWithNullOrAbsentKpIsSkippedAndTheOthersSurvive() throws {
        // 9. One unusable bin is not a broken product. Dropping the whole
        //    series over it would empty a card that had every other bin.
        let series = try XCTUnwrap(parse("""
        [{"time_tag":"2026-07-18T00:00:00","kp":1.67,"observed":"observed","noaa_scale":null},
         {"time_tag":"2026-07-18T03:00:00","kp":null,"observed":"observed","noaa_scale":null},
         {"time_tag":"2026-07-18T06:00:00","observed":"estimated","noaa_scale":null},
         {"time_tag":"2026-07-18T09:00:00","kp":3.33,"observed":"predicted","noaa_scale":null}]
        """))
        XCTAssertEqual(series.points.count, 2)
        XCTAssertEqual(series.points.map(\.kp), [1.67, 3.33])

        // A row with no usable time_tag goes the same way.
        let badStamp = try XCTUnwrap(parse("""
        [{"time_tag":"not a date","kp":1.67,"observed":"observed"},
         {"time_tag":"2026-07-18T00:00:00","kp":2.33,"observed":"observed"}]
        """))
        XCTAssertEqual(badStamp.points.map(\.kp), [2.33])
    }

    // MARK: - 10. Empty array is no data; malformed JSON is nil

    func testEmptyArrayIsZeroBinsAndResolvesToNoData() throws {
        // 10. An empty array is a successful parse of zero bins, not a
        //     failure — and `Geomagnetic` resolves it to `Freshness.none`
        //     rather than "live with no value", or a crash.
        let series = try XCTUnwrap(parse("[]"))
        XCTAssertTrue(series.points.isEmpty)

        let conditions = Geomagnetic.conditions(series: series,
                                                latitude: 51.5074, longitude: -0.1278,
                                                grid: nil, now: fetchedAt, calendar: utc)
        XCTAssertEqual(conditions.freshness, Freshness.none)
        XCTAssertNil(conditions.dataAge)
        XCTAssertNil(conditions.kpNow)
        XCTAssertEqual(conditions.gScale, .g0)
    }

    func testMalformedJSONReturnsNil() {
        // 10. Neither wire format parses, so the caller keeps what it has.
        //     Every one of these is a shape a truncated or proxied response
        //     can actually take.
        XCTAssertNil(parse("{ not json"))
        XCTAssertNil(parse(""))
        XCTAssertNil(parse("null"))
        XCTAssertNil(parse("{\"time_tag\":\"2026-07-18T00:00:00\",\"kp\":1.67}"))
        XCTAssertNil(parse("[1,2,3]"))
        XCTAssertNil(parse("<html><body>502 Bad Gateway</body></html>"))
    }

    // MARK: - Cache round-trip

    func testCacheRoundTripsThroughDisk() async throws {
        // Written by one launch, read by the next. Driven through the real
        // write and read paths rather than a copy of them, because the disk
        // type is deliberately NOT `KpSeries` — the mapping between the two is
        // the part that can silently drop a field.
        let directory = try temporaryDirectory()
        let series = KpSeries(fetchedAt: fetchedAt, points: [
            KpPoint(time: fetchedAt.addingTimeInterval(-3 * 3600), kp: 4.667, provenance: .observed),
            KpPoint(time: fetchedAt, kp: 5.333, provenance: .estimated),
            KpPoint(time: fetchedAt.addingTimeInterval(3 * 3600), kp: 6.0, provenance: .predicted)
        ])

        await SpaceWeatherService(cacheDirectory: directory).writeCache(series)
        let reloaded = await SpaceWeatherService(cacheDirectory: directory).snapshot()

        XCTAssertEqual(reloaded.series, series)
    }

    func testLegacyCacheBlobMissingTheNewestFieldStillDecodes() async throws {
        // A cache written by an older build has no `provenance` on its points.
        // Every field of the disk type is optional with a default precisely so
        // that file still decodes — the same forward/backward-compatibility
        // rule `OfflinePackTests.testLegacyPackWithDEMBlobsStillDecodes` pins
        // for packs — instead of being discarded on the first launch after an
        // update, which is when a user is least able to refetch.
        let legacy = #"""
        {"fetchedAt":"2023-11-14T22:13:20Z",
         "points":[{"time":"2023-11-14T19:00:00Z","kp":4.667},
                   {"time":"2023-11-14T22:00:00Z","kp":5.333}]}
        """#

        let file = try SpaceWeatherService.cacheDecoder.decode(SpaceWeatherService.CacheFile.self,
                                                               from: Data(legacy.utf8))
        XCTAssertEqual(file.fetchedAt, fetchedAt)
        XCTAssertEqual(file.points?.count, 2)
        XCTAssertNil(file.points?.first?.provenance)

        // And it loads: the missing tag becomes `.predicted`, which the card
        // captions "forecast" rather than claiming the number was observed.
        let directory = try temporaryDirectory()
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("SpaceWeatherCache.json"))
        let snapshot = await SpaceWeatherService(cacheDirectory: directory).snapshot()
        let loaded = try XCTUnwrap(snapshot.series)

        XCTAssertEqual(loaded.fetchedAt, fetchedAt)
        XCTAssertEqual(loaded.points.map(\.kp), [4.667, 5.333])
        XCTAssertEqual(loaded.points.map(\.provenance), [.predicted, .predicted])
    }

    func testCacheWithNoUsablePointsIsNotLoaded() async throws {
        // Half a cache is not a cache. A file whose points all lack a time or
        // a Kp leaves the service empty rather than carrying an empty series
        // with a fetch stamp, which would read as "live, no value".
        let directory = try temporaryDirectory()
        let blob = #"{"fetchedAt":"2023-11-14T22:13:20Z","points":[{"kp":5.0},{"time":"2023-11-14T22:00:00Z"}]}"#
        try Data(blob.utf8).write(to: directory.appendingPathComponent("SpaceWeatherCache.json"))

        let loaded = await SpaceWeatherService(cacheDirectory: directory).snapshot()
        XCTAssertNil(loaded.series)
    }

    // MARK: - Fixtures

    /// A scratch directory, removed when the test finishes.
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpaceWeatherServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private static func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// Captures the outgoing request and replays a canned response, so the request
/// shape and the "never overwrite a good cache" rule can be asserted without a
/// network. The state is static because that is the only handle `URLSession`
/// gives a protocol class; the tests that use it run one request at a time.
private final class StubURLProtocol: URLProtocol {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responder: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func reset(responder: @escaping @Sendable (URLRequest) -> (Int, Data)) {
        lock.withLock {
            Self.responder = responder
            requests = []
        }
    }

    static func captured() -> [URLRequest] {
        lock.withLock { requests }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body): (Int, Data) = Self.lock.withLock {
            Self.requests.append(request)
            return Self.responder?(request) ?? (200, Data("[]".utf8))
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status,
                                             httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
