//
//  TerrainElevationService.swift
//  Geo
//
//  Lightweight wrapper around the public Open-Elevation REST API.
//  Provides batched lookups (≤100 points per request), an in-memory
//  cache keyed on a ~110 m grid, and graceful failure: callers get
//  `nil` for any point we couldn't resolve so they can fall back to
//  geometric (sea-level) estimates.
//

import Foundation
import CoreLocation

/// Async, actor-isolated to make the cache safe across concurrent
/// skyline computations.
actor TerrainElevationService {

    static let shared = TerrainElevationService()

    /// Bucket lat/lon to ~110 m at the equator (3 decimals). Two
    /// queries close to each other share a cache entry, which matters
    /// because each skyline pass samples thousands of points.
    ///
    /// Persisted to disk (see `cacheURL`) so the AR skyline appears
    /// instantly on cold start / offline revisits. Elevation is static,
    /// so entries never go stale — the cache only grows, bounded by an
    /// LRU cap.
    private var cache: [String: Double] = [:]

    /// Least-recently-used ordering for `cache`, oldest first. Kept in
    /// sync with `cache` on every read/write so we can evict the coldest
    /// entries once we exceed `cacheCap`.
    private var lruOrder: [String] = []

    /// The persisted cache is loaded lazily on the first query — an actor's
    /// `init` is nonisolated and cannot touch isolated state under Swift 6.
    private var didLoad = false

    /// LRU cap. Each entry is a ~110 m grid cell at ~24 bytes on disk,
    /// so 8000 entries (~a 100×100 km coverage envelope) stays trivially
    /// small while surviving plenty of cold starts.
    private let cacheCap = 8000

    /// On-disk location of the persisted cache. `nil` only if the system
    /// can't hand us a Caches directory, in which case persistence is
    /// silently disabled and the cache behaves as in-memory only.
    private let cacheURL: URL? = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        return dir?.appendingPathComponent("TerrainElevationCache.json")
    }()

    /// Open-Elevation supports up to ~1024 points per POST in
    /// principle but in practice 100 is the sweet spot — large enough
    /// to amortise the round-trip, small enough that one slow request
    /// doesn't tie up the whole skyline computation.
    private let batchSize = 100

    /// HTTP timeout per batch.
    private let timeout: TimeInterval = 8

    /// Minimum spacing between outgoing requests so we don't hammer the
    /// public Open-Elevation endpoint (lighter than the Overpass limit
    /// in `PeakFinder` since batches already coalesce many points).
    private let minRequestInterval: TimeInterval = 0.2

    /// Timestamp of the last request issued, used to enforce
    /// `minRequestInterval`. Actor-isolated, so reads/writes are serial.
    private var lastRequestDate: Date?

    /// Monotonic counter of issued requests, used to vary the retry
    /// jitter per batch without `random`.
    private var requestSlot = 0

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Returns elevations for `points`, in the same order. `nil` means
    /// the point couldn't be resolved (cache miss + network failure).
    func elevations(at points: [CLLocationCoordinate2D]) async -> [Double?] {
        // Lazy first-touch load of the persisted cache (see `didLoad`).
        if !didLoad {
            loadCacheFromDisk()
            didLoad = true
        }
        var results = [Double?](repeating: nil, count: points.count)
        var pending: [(index: Int, coord: CLLocationCoordinate2D)] = []

        for (i, p) in points.enumerated() {
            let k = Self.key(p)
            if let cached = cache[k] {
                touchLRU(k)
                results[i] = cached
            } else {
                pending.append((i, p))
            }
        }
        guard !pending.isEmpty else { return results }

        // Privacy: round each request location to the cache grid before
        // sending it to a third-party API.
        for chunkStart in stride(from: 0, to: pending.count, by: batchSize) {
            // Cooperative cancellation — abort if the caller cancelled.
            if Task.isCancelled { return results }

            let end = min(chunkStart + batchSize, pending.count)
            let chunk = Array(pending[chunkStart..<end])

            let elevations = await fetchBatch(coords: chunk.map { Self.quantise($0.coord) })

            // Stitch results back in original order; populate cache.
            var didInsert = false
            for (req, elevation) in zip(chunk, elevations) {
                if let elev = elevation {
                    let k = Self.key(req.coord)
                    if cache[k] == nil { didInsert = true }
                    cache[k] = elev
                    touchLRU(k)
                    results[req.index] = elev
                }
            }
            // Write-through after each batch populates the cache, evicting
            // the coldest entries first if we crossed the LRU cap.
            if didInsert {
                evictIfNeeded()
                saveCacheToDisk()
            }
        }

        return results
    }

    /// Drop everything from the cache. Useful for tests; skyline data
    /// is keyed on observer location, so a cache reset is rarely
    /// needed in production.
    func clearCache() {
        cache.removeAll()
        lruOrder.removeAll()
        if let url = cacheURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - HTTP

    private func fetchBatch(coords: [CLLocationCoordinate2D]) async -> [Double?] {
        guard !coords.isEmpty else { return [] }

        // Defensive guard rather than force-unwrap. The literal is
        // valid today; the safety blanket protects against typos a
        // future patch might introduce.
        guard let url = URL(string: "https://api.open-elevation.com/api/v1/lookup") else {
            return Array(repeating: nil, count: coords.count)
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let body = OpenElevationRequest(
            locations: coords.map { OpenElevationRequest.Location(latitude: $0.latitude,
                                                                  longitude: $0.longitude) }
        )
        do {
            req.httpBody = try JSONEncoder().encode(body)
        } catch {
            AppLog.ar.error("Elevation request encode failed: \(String(describing: error))")
            return Array(repeating: nil, count: coords.count)
        }

        do {
            let (data, response) = try await sendWithRetry(req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return Array(repeating: nil, count: coords.count)
            }
            let decoded = try JSONDecoder().decode(OpenElevationResponse.self, from: data)
            // Open-Elevation returns results in the same order as the
            // request, but be defensive and pad / truncate to match.
            //
            // Reject implausible elevations -> nil so callers fall back
            // to the geometric (sea-level) estimate rather than render a
            // peak at the wrong height:
            //   • <= -430 m is below the lowest dry land on Earth (the
            //     Dead Sea shore, ~-430 m), so it can only be a bad value.
            //   • exactly 0.0 is what Open-Elevation returns for points
            //     it can't resolve (ocean / outside DEM coverage), not a
            //     genuine sea-level reading.
            var out = decoded.results.map { result -> Double? in
                let e = result.elevation
                if e <= -430 || e == 0.0 { return nil }
                return e
            }
            if out.count < coords.count {
                out.append(contentsOf: Array(repeating: nil, count: coords.count - out.count))
            }
            return Array(out.prefix(coords.count))
        } catch {
            AppLog.ar.error("Elevation request failed: \(String(describing: error))")
            return Array(repeating: nil, count: coords.count)
        }
    }

    /// Issue `req`, enforcing `minRequestInterval` between successive
    /// requests and retrying ONCE on a throttling / transient server
    /// response (HTTP 429 or 5xx). Honours a `Retry-After` header when
    /// present (seconds), else falls back to a short fixed backoff. The
    /// final response — success or not — is returned to the caller, which
    /// keeps the existing graceful nil fallback intact. Actor-isolated;
    /// the `Task.sleep` calls suspend without blocking any thread.
    private func sendWithRetry(_ req: URLRequest) async throws -> (Data, URLResponse) {
        let slot = await throttle()
        var (data, response) = try await session.data(for: req)

        if let http = response as? HTTPURLResponse, Self.isTransient(http.statusCode) {
            // Fallback backoff varies per request slot (a monotonic
            // counter) rather than via `random`, so back-to-back batches
            // don't all retry in lockstep: 0.5 s base + up to ~0.75 s jitter.
            let jitter = 0.5 + Double(slot % 4) * 0.25
            let wait = Self.retryDelay(from: http, fallback: jitter)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            _ = await throttle()
            (data, response) = try await session.data(for: req)
        }
        return (data, response)
    }

    /// Sleep just long enough that this request lands at least
    /// `minRequestInterval` after the previous one, then stamp `now` and
    /// return a monotonic slot index (used to vary retry jitter).
    @discardableResult
    private func throttle() async -> Int {
        if let last = lastRequestDate {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < minRequestInterval {
                try? await Task.sleep(nanoseconds: UInt64((minRequestInterval - elapsed) * 1_000_000_000))
            }
        }
        lastRequestDate = Date()
        requestSlot &+= 1
        return requestSlot
    }

    /// 429 (Too Many Requests) and any 5xx are worth one retry.
    private static func isTransient(_ status: Int) -> Bool {
        status == 429 || (500..<600).contains(status)
    }

    /// Seconds to wait before the single retry: the `Retry-After` header
    /// (delta-seconds form) if the server sent one, otherwise `fallback`.
    private static func retryDelay(from http: HTTPURLResponse, fallback: TimeInterval) -> TimeInterval {
        if let header = http.value(forHTTPHeaderField: "Retry-After"),
           let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)),
           seconds >= 0 {
            return min(seconds, 5)
        }
        return fallback
    }

    // MARK: - LRU

    /// Mark `key` as most-recently-used. O(n) on the order array, but the
    /// array is capped at `cacheCap` and skyline passes touch the same
    /// few keys repeatedly, so this stays cheap.
    private func touchLRU(_ key: String) {
        if let i = lruOrder.firstIndex(of: key) {
            lruOrder.remove(at: i)
        }
        lruOrder.append(key)
    }

    /// Drop the least-recently-used entries until we're back at `cacheCap`.
    private func evictIfNeeded() {
        guard cache.count > cacheCap else { return }
        let overflow = cache.count - cacheCap
        for key in lruOrder.prefix(overflow) {
            cache.removeValue(forKey: key)
        }
        lruOrder.removeFirst(min(overflow, lruOrder.count))
    }

    // MARK: - Persistence

    /// Disk representation: the value map plus the LRU ordering, so
    /// recency survives a restart and we don't evict warm entries first.
    private struct CacheFile: Codable {
        let values: [String: Double]
        let order: [String]
    }

    private func loadCacheFromDisk() {
        guard let url = cacheURL,
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(CacheFile.self, from: data) else {
            return
        }
        cache = file.values
        // Keep only keys that still exist in `cache`, then ensure every
        // cached key is represented so eviction always has somewhere to
        // start.
        var seen = Set<String>()
        lruOrder = file.order.filter { cache[$0] != nil && seen.insert($0).inserted }
        for key in cache.keys where !seen.contains(key) {
            lruOrder.append(key)
        }
        evictIfNeeded()
    }

    private func saveCacheToDisk() {
        guard let url = cacheURL else { return }
        let file = CacheFile(values: cache, order: lruOrder)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Helpers

    /// Single source of truth for the ~110 m (3-decimal) coordinate
    /// grid. `PeakFinder` calls this for its Overpass `qLat`/`qLon` so
    /// both the elevation cache and the peak query round identically,
    /// mirroring the Android port where `PeakFinder` calls
    /// `TerrainElevationService.quantise`.
    static func quantise(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }

    private static func quantise(_ p: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: quantise(p.latitude),
            longitude: quantise(p.longitude)
        )
    }

    private static func key(_ p: CLLocationCoordinate2D) -> String {
        let q = quantise(p)
        return "\(q.latitude),\(q.longitude)"
    }
}

// MARK: - Wire format

private struct OpenElevationRequest: Encodable {
    let locations: [Location]
    struct Location: Encodable {
        let latitude: Double
        let longitude: Double
    }
}

private struct OpenElevationResponse: Decodable {
    let results: [Result]
    struct Result: Decodable {
        let latitude: Double
        let longitude: Double
        let elevation: Double
    }
}
