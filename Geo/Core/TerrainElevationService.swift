//
//  TerrainElevationService.swift
//  Geo
//
//  Lightweight wrapper around the public Open-Meteo elevation REST API.
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

    /// Cells from downloaded **offline expedition packs**, keyed exactly
    /// like `cache`. Consulted on every cache miss and *never* LRU-evicted,
    /// so a prefetched area's terrain skyline keeps resolving from cache
    /// with no signal. Rebuilt wholesale from the saved packs by
    /// `OfflinePackManager` at launch and whenever a pack is added/removed.
    /// Total memory is bounded because each pack caps its cell count at
    /// `SkylineCalculator.offlineMaxDEMCells` (≈ cap × number of saved packs).
    private var pinned: [String: Double] = [:]

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

    /// Open-Meteo's elevation API takes up to 100 coordinates per request, which
    /// is also the sweet spot for batching: big enough to amortise the
    /// round-trip, small enough that one slow request doesn't stall everything.
    private let batchSize = 100

    /// HTTP timeout per batch.
    private let timeout: TimeInterval = 8

    /// How many elevation batches to fetch concurrently. A cold skyline pass is
    /// ~36 batches; running a few lanes in parallel turns a ~7–15 s serial fetch
    /// into ~1–2 s while staying well within Open-Meteo's fair-use limits.
    private let maxConcurrentBatches = 6

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
            let k = Self.gridKey(p)
            if let cached = cache[k] {
                touchLRU(k)
                results[i] = cached
            } else if let pin = pinned[k] {
                // Offline-pack cell — durable, never LRU-evicted.
                results[i] = pin
            } else {
                pending.append((i, p))
            }
        }
        guard !pending.isEmpty else { return results }

        // Split the pending points into ≤batchSize chunks (each coordinate is
        // rounded to the privacy grid before it's sent), then fetch the chunks
        // CONCURRENTLY across a bounded number of lanes rather than one batch at
        // a time. A cold skyline is ~36 batches; serial they took ~7–15 s, but a
        // handful of lanes finish in ~1–2 s. The lane cap keeps us polite to the
        // public Open-Meteo endpoint. Each lane runs its share of chunks
        // sequentially and returns the resolved points; the cache + results are
        // updated back here on the actor as each lane completes.
        let chunks: [[(index: Int, coord: CLLocationCoordinate2D)]] =
            stride(from: 0, to: pending.count, by: batchSize).map {
                Array(pending[$0..<min($0 + batchSize, pending.count)])
            }
        let laneCount = min(maxConcurrentBatches, chunks.count)
        var anyInsert = false

        await withTaskGroup(of: [(index: Int, coord: CLLocationCoordinate2D, elev: Double)].self) { group in
            for lane in 0..<laneCount {
                group.addTask { [chunks] in
                    var out: [(index: Int, coord: CLLocationCoordinate2D, elev: Double)] = []
                    var c = lane
                    while c < chunks.count {
                        if Task.isCancelled { break }
                        let chunk = chunks[c]
                        let elevs = await self.fetchBatch(coords: chunk.map { Self.quantise($0.coord) })
                        for (req, elevation) in zip(chunk, elevs) {
                            if let elevation { out.append((req.index, req.coord, elevation)) }
                        }
                        c += laneCount
                    }
                    return out
                }
            }
            for await laneOut in group {
                for entry in laneOut {
                    let k = Self.gridKey(entry.coord)
                    if cache[k] == nil { anyInsert = true }
                    cache[k] = entry.elev
                    touchLRU(k)
                    results[entry.index] = entry.elev
                }
            }
        }

        // Coalesce the LRU eviction + disk write to a single pass at the end
        // rather than once per ~100-point batch: a cold skyline pass would
        // otherwise trigger many full-cache JSON encodes/writes in a row.
        if anyInsert {
            evictIfNeeded()
            saveCacheToDisk()
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

    /// Replace the set of *pinned* cells (grid-cell → elevation) from the
    /// downloaded offline packs. Pinned cells are consulted on every cache
    /// miss and never evicted. Rebuilt wholesale by `OfflinePackManager`,
    /// so passing the union of all packs' cells is the whole contract.
    func setPinned(_ cells: [String: Double]) {
        pinned = cells
    }

    // MARK: - HTTP

    private func fetchBatch(coords: [CLLocationCoordinate2D]) async -> [Double?] {
        guard !coords.isEmpty else { return [] }

        // Open-Meteo elevation API: GET with comma-separated lat/lon lists, up to
        // 100 points per request (matches `batchSize`). Reliable + free + no key,
        // and the app already uses Open-Meteo for weather/QNH. Replaced the public
        // Open-Elevation endpoint, which frequently 504s / times out and left the
        // AR terrain skyline (and its welded peak labels) empty. Coords are
        // already quantised to the privacy grid before this call.
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/elevation")
        comps?.queryItems = [
            URLQueryItem(name: "latitude", value: coords.map { String($0.latitude) }.joined(separator: ",")),
            URLQueryItem(name: "longitude", value: coords.map { String($0.longitude) }.joined(separator: ","))
        ]
        guard let url = comps?.url else {
            return Array(repeating: nil, count: coords.count)
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await sendWithRetry(req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return Array(repeating: nil, count: coords.count)
            }
            let decoded = try JSONDecoder().decode(OpenMeteoElevationResponse.self, from: data)
            // Elevations come back in request order; pad / truncate to match.
            //
            // Reject implausible elevations -> nil so callers fall back to the
            // geometric (sea-level) estimate rather than render a peak at the
            // wrong height:
            //   • <= -430 m is below the lowest dry land on Earth (the Dead Sea
            //     shore, ~-430 m), so it can only be a bad value.
            //   • exactly 0.0 is the ocean / outside-DEM value, not a genuine
            //     sea-level reading we want forming a silhouette.
            var out = decoded.elevation.map { e -> Double? in
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

    /// Issue `req`, retrying ONCE on a throttling / transient server response
    /// (HTTP 429 or 5xx). Honours a `Retry-After` header when present (seconds,
    /// capped), else falls back to a short jittered backoff. The final response
    /// — success or not — is returned to the caller, keeping the graceful nil
    /// fallback intact. Politeness comes from the bounded lane count
    /// (`maxConcurrentBatches`) rather than a per-request time gate, so batches
    /// can run concurrently. Actor-isolated; `Task.sleep` suspends, never blocks.
    private func sendWithRetry(_ req: URLRequest) async throws -> (Data, URLResponse) {
        var (data, response) = try await session.data(for: req)

        if let http = response as? HTTPURLResponse, Self.isTransient(http.statusCode) {
            // Vary the fallback backoff per request (a monotonic counter, not
            // `random`) so concurrent retries don't fire in lockstep:
            // 0.5 s base + up to ~0.75 s jitter.
            requestSlot &+= 1
            let jitter = 0.5 + Double(requestSlot % 4) * 0.25
            let wait = Self.retryDelay(from: http, fallback: jitter)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            (data, response) = try await session.data(for: req)
        }
        return (data, response)
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

    /// Canonical cache/pinned key for a coordinate: the ~110 m quantised
    /// "lat,lon" string. Exposed so `OfflinePackManager` builds pack-cell
    /// keys that line up byte-for-byte with the live lookups.
    static func gridKey(_ p: CLLocationCoordinate2D) -> String {
        let q = quantise(p)
        return "\(q.latitude),\(q.longitude)"
    }
}

// MARK: - Wire format

/// Open-Meteo elevation response: `{ "elevation": [e0, e1, …] }`, one entry per
/// requested coordinate, in order.
private struct OpenMeteoElevationResponse: Decodable {
    let elevation: [Double]
}
