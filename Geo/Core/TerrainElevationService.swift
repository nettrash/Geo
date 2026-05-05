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
    private var cache: [String: Double] = [:]

    /// Open-Elevation supports up to ~1024 points per POST in
    /// principle but in practice 100 is the sweet spot — large enough
    /// to amortise the round-trip, small enough that one slow request
    /// doesn't tie up the whole skyline computation.
    private let batchSize = 100

    /// HTTP timeout per batch.
    private let timeout: TimeInterval = 8

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Returns elevations for `points`, in the same order. `nil` means
    /// the point couldn't be resolved (cache miss + network failure).
    func elevations(at points: [CLLocationCoordinate2D]) async -> [Double?] {
        var results = [Double?](repeating: nil, count: points.count)
        var pending: [(index: Int, coord: CLLocationCoordinate2D)] = []

        for (i, p) in points.enumerated() {
            if let cached = cache[Self.key(p)] {
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
            for (req, elevation) in zip(chunk, elevations) {
                if let elev = elevation {
                    cache[Self.key(req.coord)] = elev
                    results[req.index] = elev
                }
            }
        }

        return results
    }

    /// Drop everything from the cache. Useful for tests; skyline data
    /// is keyed on observer location, so a cache reset is rarely
    /// needed in production.
    func clearCache() {
        cache.removeAll()
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
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return Array(repeating: nil, count: coords.count)
            }
            let decoded = try JSONDecoder().decode(OpenElevationResponse.self, from: data)
            // Open-Elevation returns results in the same order as the
            // request, but be defensive and pad / truncate to match.
            var out = decoded.results.map { Double?($0.elevation) }
            if out.count < coords.count {
                out.append(contentsOf: Array(repeating: nil, count: coords.count - out.count))
            }
            return Array(out.prefix(coords.count))
        } catch {
            AppLog.ar.error("Elevation request failed: \(String(describing: error))")
            return Array(repeating: nil, count: coords.count)
        }
    }

    // MARK: - Helpers

    private static func quantise(_ p: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: (p.latitude * 1000).rounded() / 1000,
            longitude: (p.longitude * 1000).rounded() / 1000
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
