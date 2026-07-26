//
//  SpaceWeatherService.swift
//  Geo
//
//  The whole network surface of the Magnetic Conditions card: ONE GET of
//  NOAA SWPC's planetary-Kp product, a JSON cache under Caches, and the
//  bundled AACGM correction grid decoded once.
//
//  Nothing here knows where the user is. The request is byte-identical for
//  every copy of the app on Earth — no query string, no coordinates, not even
//  quantised ones, no identifier — which makes it a strictly smaller footprint
//  than the Overpass and Open-Meteo calls the app already makes. Everything
//  location-dependent on the card (magnetic latitude, oval margin, pole
//  bearing, darkness window, compass band, GNSS advisory) is computed
//  on-device by `Geomagnetic` from the one global number this file fetches.
//
//  Conventions follow `TerrainElevationService`: an actor, a `URLSession`
//  injected as the only unit-test seam, an 8 s timeout, one retry on a
//  transient status, and graceful `nil` instead of a thrown error — the card
//  degrades to "showing what Geo computes on-device" and never surfaces a
//  failure. `User-Agent` matches `PeakFinder` so an operator watching their
//  logs sees one client across both public endpoints.
//
//  Mirrored by Android `me.nettrash.geo.util.SpaceWeatherRepository` +
//  `SpaceWeatherStore`; the numbered parse contract below is the same list of
//  named failure modes, in the same order, on both platforms.
//

import Foundation

/// Everything the card needs in one actor hop: the cached product and the
/// decoded grid. The card owns its own "a fetch is in flight" flag, because
/// that is a property of the view's own await, not of the stored data.
struct SpaceWeatherSnapshot: Sendable {
    let series: KpSeries?
    let grid: MLatDeltaGrid?
}

/// Async, actor-isolated so the cached series and the decoded grid are safe
/// across the card, the Info tab and the scene-phase refresh all touching it
/// at once.
actor SpaceWeatherService {

    static let shared = SpaceWeatherService()

    /// NOAA SWPC's 3-hourly planetary Kp, −7 d to +3 d, every row tagged
    /// `observed` / `estimated` / `predicted`. Public domain (NWS use policy):
    /// no key, no attribution legally required.
    ///
    /// A CONSTANT URL. There is no query string and there never will be — that
    /// is the property the privacy policy claims, so it is spelled out here
    /// rather than assembled from `URLComponents` where a parameter could one
    /// day be appended without anyone noticing.
    static let endpoint = URL(string: "https://services.swpc.noaa.gov/products/noaa-planetary-k-index-forecast.json")!

    /// Same identification string as `PeakFinder`, so the two public endpoints
    /// we contact see one client rather than two anonymous ones.
    private static let userAgent = "me.nettrash.Geo/1.0 (+https://nettrash.me)"

    /// The most recent product we hold, from disk or from the network.
    private var series: KpSeries?

    /// The bundled correction grid, decoded at most once per launch.
    private var grid: MLatDeltaGrid?
    private var didLoadGrid = false

    /// The persisted cache is loaded lazily on the first touch — an actor's
    /// `init` is nonisolated and cannot touch isolated state under Swift 6
    /// (the same reason `TerrainElevationService` carries this flag).
    private var didLoad = false

    /// True while a request is in flight, so a tab switch during a fetch
    /// doesn't start a second one and the card can tell "expired" from
    /// "still checking".
    private var isFetching = false

    /// When we last *attempted* a fetch, in this process. Gating on the
    /// attempt rather than the success is what stops an offline device
    /// re-issuing an 8 s request on every tab switch; the cache stamp below
    /// carries the same gate across launches.
    private var lastAttemptAt: Date = .distantPast

    /// HTTP timeout. The payload is ~500 B gzipped and CloudFront answers in
    /// under 100 ms from Europe, so 8 s is already generous — it exists to cap
    /// a dead network, not a slow one.
    private let timeout: TimeInterval = 8

    /// On-disk cache. `nil` only if the system can't hand us a Caches
    /// directory, in which case persistence is silently disabled and the
    /// series lives for the process lifetime only.
    private let cacheURL: URL?

    private let session: URLSession

    /// `session` and `cacheDirectory` are the only two seams in this file and
    /// both default to what the app uses. The app never passes a directory —
    /// omitting it resolves the same Caches path this file always used — and
    /// the tests hand in a temporary one so a round-trip can be asserted
    /// without writing over the real cache.
    init(session: URLSession = .shared, cacheDirectory: URL? = nil) {
        self.session = session
        let dir = cacheDirectory
               ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        self.cacheURL = dir?.appendingPathComponent("SpaceWeatherCache.json")
    }

    // MARK: - What the UI asks for

    /// The cached product plus the decoded grid, in one hop. Never fetches:
    /// the card renders whatever we already have and lets `refreshIfStale`
    /// catch up in its own time.
    func snapshot() -> SpaceWeatherSnapshot {
        loadIfNeeded()
        return SpaceWeatherSnapshot(series: series, grid: correctionGrid())
    }

    /// The bundled AACGM-minus-dipole correction table, decoded once.
    ///
    /// A `nil` here is not recoverable and must NOT be papered over: without
    /// the grid there is no corrected magnetic latitude, and the raw dipole is
    /// +5.63° in London — a whole aurora verdict wrong. The card hides the
    /// aurora and magnetic-latitude rows instead. A build-phase script fails
    /// the build if the asset is missing, wrong-sized or all-zero, so this
    /// branch should only ever be reachable from a corrupted install.
    func correctionGrid() -> MLatDeltaGrid? {
        if !didLoadGrid {
            didLoadGrid = true
            grid = MLatDeltaGrid.bundled()
            if grid == nil {
                AppLog.spaceWeather.error("Correction grid did not decode — the aurora and magnetic-latitude rows stay hidden rather than falling back to the raw dipole")
            }
        }
        return grid
    }

    // MARK: - Refresh

    /// Fetch the product if what we hold is older than one Kp bin, and store
    /// the result. Never throws, never blocks the caller on a failure, and a
    /// failed or empty fetch NEVER overwrites a good cache — a cache that
    /// still answers "you need about Kp 5+ here" beats an empty card.
    ///
    /// Kp is published in 3-hour bins, so a refetch sooner than
    /// `fetchMinIntervalHours` cannot return a new number at any price. Safe
    /// to call from every foreground entry point (card `.onAppear`, Info tab,
    /// scene-active) because of that gate.
    func refreshIfStale(now: Date = Date()) async {
        loadIfNeeded()

        let interval = Geomagnetic.fetchMinIntervalHours * 3600
        guard !isFetching else { return }
        if let series, now.timeIntervalSince(series.fetchedAt) < interval { return }
        guard now.timeIntervalSince(lastAttemptAt) >= interval else { return }

        lastAttemptAt = now
        isFetching = true
        defer { isFetching = false }

        guard let fetched = await fetch(now: now) else {
            AppLog.spaceWeather.info("Kp product unavailable; keeping the cached series")
            return
        }
        // An empty product is a transport or upstream problem dressed up as a
        // 200, not news that geomagnetic activity stopped existing. Same
        // reasoning as `OfflinePackManager.updatePack` refusing to overwrite a
        // good pack with an empty peak list.
        guard !fetched.points.isEmpty else {
            AppLog.spaceWeather.info("Kp product parsed to zero bins; keeping the cached series")
            return
        }

        series = fetched
        writeCache(fetched)
        AppLog.spaceWeather.info("Kp product refreshed: \(fetched.points.count, privacy: .public) bins")
    }

    // MARK: - HTTP

    private func fetch(now: Date) async -> KpSeries? {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        // Never a conditional GET. SWPC rewrites its whole tree every minute,
        // so `last-modified` is always ~40 s old regardless of when the
        // content actually changed and an `If-Modified-Since` would never hit.
        // Freshness comes from the payload's own `time_tag` and our fetch
        // stamp, so we ask URLSession not to revalidate from its own cache
        // either. `Accept-Encoding` is deliberately NOT set by hand —
        // URLSession negotiates gzip and the 6905 B payload lands in ~500 B.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await sendWithRetry(request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                AppLog.spaceWeather.error("Kp request returned HTTP \(status, privacy: .public)")
                return nil
            }
            return Self.parseKpForecast(data, fetchedAt: now)
        } catch {
            AppLog.spaceWeather.error("Kp request failed: \(String(describing: error))")
            return nil
        }
    }

    /// Issue `request`, retrying ONCE on a throttling / transient server
    /// response (429 or 5xx). Honours `Retry-After` when present (delta
    /// seconds, capped at 5 s), otherwise waits a flat 0.5 s.
    ///
    /// The backoff is DETERMINISTIC, never `random`: this service issues one
    /// request at a time, at most once per 3 h, so there is no fleet of
    /// concurrent lanes to de-synchronise (which is the only reason
    /// `TerrainElevationService` varies its own fallback), and a fixed delay
    /// is one less thing that behaves differently between the two platforms.
    /// Actor-isolated; `Task.sleep` suspends, never blocks.
    private func sendWithRetry(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, Self.isTransient(http.statusCode) {
            let wait = Self.retryDelay(from: http, fallback: 0.5)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            (data, response) = try await session.data(for: request)
        }
        return (data, response)
    }

    /// 429 (Too Many Requests) and any 5xx are worth one retry.
    private static func isTransient(_ status: Int) -> Bool {
        status == 429 || (500..<600).contains(status)
    }

    /// Seconds to wait before the single retry: the `Retry-After` header
    /// (delta-seconds form) if the server sent one, otherwise `fallback`.
    /// Capped at 5 s — a longer wait outlives the user's attention on a card
    /// that has already rendered everything it can compute offline.
    private static func retryDelay(from http: HTTPURLResponse, fallback: TimeInterval) -> TimeInterval {
        if let header = http.value(forHTTPHeaderField: "Retry-After"),
           let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)),
           seconds >= 0 {
            return min(seconds, 5)
        }
        return fallback
    }

    // MARK: - Parsing
    //
    // Every numbered rule below is a way this integration fails SILENTLY —
    // no crash, no error, just a card that is confidently wrong — so each one
    // is spelled out where it is implemented rather than only in the spec.

    /// Decode the SWPC product into a sorted series.
    ///
    /// Returns `nil` only when neither wire format parses; the caller then
    /// keeps the cache. An empty array is a successful parse of zero bins,
    /// which the caller also refuses to store, and which `Geomagnetic`
    /// resolves to `Freshness.none` rather than a crash.
    static func parseKpForecast(_ data: Data, fetchedAt: Date) -> KpSeries? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let rows = object as? [Any] else { return nil }

        // 4. DUAL-FORMAT PARSE. This product moved from array-of-arrays with a
        //    ["time_tag","Kp",…] header row to array-of-objects, and sibling
        //    files under /products/ still use the old style. Objects first,
        //    then the header-row form; both failing returns nil.
        let points: [KpPoint]
        if let objects = rows as? [[String: Any]] {
            points = objects.compactMap(point(fromObject:))
        } else if let arrays = rows as? [[Any]], let legacy = Self.points(fromArrays: arrays) {
            points = legacy
        } else {
            return nil
        }

        // 2. ALWAYS SORT BY time_tag, NEVER index by array position. SWPC's
        //    ordering is inconsistent across products (/products/* oldest
        //    first, alerts.json and json/rtsw/* newest first). Sorting removes
        //    the whole failure class structurally instead of testing for it.
        return KpSeries(fetchedAt: fetchedAt, points: points.sorted { $0.time < $1.time })
    }

    /// One row of the modern array-of-objects form:
    /// `{"time_tag":"2026-07-18T00:00:00","kp":1.67,"observed":"observed","noaa_scale":null}`
    private static func point(fromObject row: [String: Any]) -> KpPoint? {
        // 9. A row with a null or absent kp is skipped; the others survive.
        guard let tag = row["time_tag"] as? String,
              let time = parseSwpcTimeTag(tag),
              let kp = double(row["kp"]) else { return nil }
        // 1. The provenance field is named `observed`, not `provenance`.
        // 5. `noaa_scale` is ignored ENTIRELY — it is null in every observed
        //    row and its storm-time content is unverified. G is derived
        //    locally by `Geomagnetic.gScale`, from Kp, by the floor rule.
        return KpPoint(time: time, kp: kp, provenance: provenance(row["observed"]))
    }

    /// The legacy array-of-arrays form: a header row naming the columns, then
    /// one array per bin. Returns nil when the header does not carry the two
    /// columns we need, so the caller can fall through to "keep the cache"
    /// rather than silently produce zero bins.
    private static func points(fromArrays rows: [[Any]]) -> [KpPoint]? {
        guard let header = rows.first else { return [] }
        let names = header.map { String(describing: $0).trimmingCharacters(in: .whitespaces).lowercased() }
        guard let timeColumn = names.firstIndex(of: "time_tag"),
              let kpColumn = names.firstIndex(of: "kp") else { return nil }
        let provenanceColumn = names.firstIndex(of: "observed")

        return rows.dropFirst().compactMap { row -> KpPoint? in
            guard timeColumn < row.count, kpColumn < row.count,
                  let stamp = row[timeColumn] as? String,
                  let time = parseSwpcTimeTag(stamp),
                  let kp = double(row[kpColumn]) else { return nil }
            var observed: Any?
            if let column = provenanceColumn, column < row.count { observed = row[column] }
            return KpPoint(time: time, kp: kp, provenance: provenance(observed))
        }
    }

    /// SWPC's `time_tag`: `"2026-07-25T15:00:00"`, with NO zone suffix — and
    /// it IS UTC.
    ///
    /// 3. Parsed with an explicit `en_US_POSIX` + UTC formatter, NEVER
    ///    `ISO8601DateFormatter` defaults, which would read it in the device's
    ///    zone. Getting this wrong is silently wrong by up to 14 hours and
    ///    nothing on the card looks broken while it happens: the bins simply
    ///    describe the wrong evening. Android does the same with
    ///    `LocalDateTime.parse(...).toInstant(ZoneOffset.UTC)`.
    ///
    /// The normalisation below is part of the contract too, and Android
    /// mirrors it: the legacy rows of this same product write the separator as
    /// a space and carry milliseconds (`"2026-07-18 00:00:00.000"`), so the
    /// dual-format parse would otherwise decode zero bins from a form we
    /// deliberately still support.
    static func parseSwpcTimeTag(_ raw: String) -> Date? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if let separator = text.firstIndex(of: " ") {
            text.replaceSubrange(separator...separator, with: "T")
        }
        if let fraction = text.firstIndex(of: ".") {
            text = String(text[text.startIndex..<fraction])
        }
        return swpcFormatter.date(from: text)
    }

    private static let swpcFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // POSIX locale so a device set to a non-Gregorian calendar (or an
        // Arabic-numeral locale) still parses the wire format.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    /// 6. Kp as a Double whether SWPC sent a JSON number or a quoted string,
    ///    and never by string-matching: sibling products emit scientific
    ///    notation (`2.5999999e+000`), which only survives a real numeric
    ///    parse. `NSNull` is neither, so a null Kp falls out here as nil and
    ///    the row is skipped.
    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// Map SWPC's `observed` strings straight onto `KpProvenance`, which is
    /// backed by those exact values. An unrecognised or missing tag falls back
    /// to `.predicted` — the card renders that as "forecast", and claiming a
    /// number was *observed* when we no longer recognise the field would be a
    /// claim we cannot support.
    private static func provenance(_ value: Any?) -> KpProvenance {
        guard let raw = value as? String else { return .predicted }
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return KpProvenance(rawValue: trimmed) ?? .predicted
    }

    // MARK: - Persistence

    /// Disk representation. Deliberately its OWN type rather than encoding
    /// `KpSeries` directly, and every field optional with a default: a cache
    /// written by an older build — or one missing a field a later build adds
    /// — still decodes instead of being thrown away, which is the same
    /// forward/backward-compatibility rule `OfflinePack` and
    /// `SharedSnapshotStore` follow. It also mirrors the Android
    /// `@Serializable data class KpPoint(val timeMs: Long = 0L, …)` defaults
    /// field for field.
    ///
    /// Internal rather than private so the tests can pin the on-disk shape
    /// itself, the way `OfflinePackTests` pins `OfflinePackData`.
    struct CacheFile: Codable {
        var fetchedAt: Date?
        var points: [Point]?

        struct Point: Codable {
            var time: Date?
            var kp: Double?
            var provenance: String?
        }
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let url = cacheURL,
              let data = try? Data(contentsOf: url),
              let file = try? Self.cacheDecoder.decode(CacheFile.self, from: data),
              let fetchedAt = file.fetchedAt else { return }

        let points = (file.points ?? []).compactMap { row -> KpPoint? in
            guard let time = row.time, let kp = row.kp else { return nil }
            return KpPoint(time: time,
                           kp: kp,
                           provenance: KpProvenance(rawValue: row.provenance ?? "") ?? .predicted)
        }
        guard !points.isEmpty else { return }
        series = KpSeries(fetchedAt: fetchedAt, points: points.sorted { $0.time < $1.time })
    }

    /// Internal so the round-trip test can drive the real write path rather
    /// than a copy of it; nothing outside this file calls it.
    func writeCache(_ series: KpSeries) {
        guard let url = cacheURL else { return }
        let file = CacheFile(fetchedAt: series.fetchedAt,
                             points: series.points.map {
                                 CacheFile.Point(time: $0.time,
                                                 kp: $0.kp,
                                                 provenance: $0.provenance.rawValue)
                             })
        guard let data = try? Self.cacheEncoder.encode(file) else { return }
        // Atomic, so a kill mid-write leaves the previous good cache in place
        // rather than a truncated file the next launch has to discard.
        try? data.write(to: url, options: .atomic)
    }

    private static let cacheEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Internal alongside `CacheFile`, so a hand-written legacy blob can be
    /// decoded in a test with the exact decoder the app uses.
    static let cacheDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
