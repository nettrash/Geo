//
//  PeakFinder.swift
//  Geo
//
//  Created by nettrash on 24/03/2026.
//

import Foundation
import CoreLocation

/// Searches for nearby peaks using the OpenStreetMap Overpass API
/// (community-curated `natural=peak` nodes) and merges with known
/// mountains from the app's bundled `MountainData`.
///
/// Apple Maps used to be a third source via `MKLocalSearch` with the
/// natural-language query "mountain peak", but it was dropped: there
/// is no `MKPointOfInterestCategory` for peaks, so the query fell back
/// to fuzzy name matching and routinely returned cafes, gyms, streets
/// and resorts whose names happened to contain "Peak" or "Mountain".
/// Worse, `MKMapItem.location.altitude` is essentially always zero for
/// POIs, so those fake peaks ended up rendered at the user's own
/// altitude — sitting right on the AR horizon, visually
/// indistinguishable from real ones.
@MainActor
class PeakFinder: ObservableObject {
    
    @Published var peaks: [NearbyPeak] = []

    private let searchRadius: CLLocationDistance = 5000 // 5 km
    private var lastSearchLocation: CLLocation?
    private let minimumSearchDistance: CLLocationDistance = 500 // re-search after moving 500m

    /// Maximum number of peaks we keep in the merged set. Older / further
    /// entries are evicted first when this is exceeded.
    private let maxRetainedPeaks: Int = 200

    /// Time after which a peak that has not been re-confirmed by a search
    /// gets dropped, even if the user hasn't moved. Stops stale results
    /// from accumulating if the user sits in one place for hours.
    private let peakTTL: TimeInterval = 60 * 60
    
    /// Search for peaks near the given location. Network source (OSM)
    /// is awaited first, then merged with the local bundled list.
    func searchPeaks(near location: CLLocation, mountainsData: MountainData?) async {
        // Don't re-search if we haven't moved much. We still age out
        // stale peaks though: prune the existing set by TTL + drop-radius
        // against the current location so a stationary user's stale peaks
        // don't accumulate (the whole point of `peakTTL`), instead of a
        // bare `return` that skips eviction entirely.
        if let last = lastSearchLocation,
           last.distance(from: location) < minimumSearchDistance,
           !peaks.isEmpty {
            peaks = pruneAndRecompute(peaks, from: location)
            return
        }

        lastSearchLocation = location

        // OSM is now the only network-backed source; bundled
        // `MountainData` is local. Apple Maps was removed — see the
        // class-level comment for why.
        //
        // `searchOpenStreetMap` is `nonisolated`: the fetch, JSON
        // decode and per-peak geometry/elevation recompute run off the
        // main actor so they can't drop AR frames during the ~5 s live
        // refresh. Only the @Published `peaks` assignment below hops
        // back onto the main actor. `searchRadius` is passed in (rather
        // than read through `self`) to keep the call free of any
        // main-actor isolation.
        let osmResults = await searchOpenStreetMap(near: location, searchRadius: searchRadius)
        let knownPeaks = findKnownMountains(near: location, mountainsData: mountainsData)

        // 1. Start with the OSM-curated peaks.
        var foundPeaks: [NearbyPeak] = osmResults

        // 2. Merge known mountains from bundled data, de-duplicating
        //    against anything OSM already returned at the same spot.
        for knownPeak in knownPeaks {
            if !isDuplicate(knownPeak, in: foundPeaks) {
                foundPeaks.append(knownPeak)
            }
        }

        // Merge with the previous result set so a transient empty / partial
        // response from Overpass doesn't wipe peaks that are still valid.
        var byID: [UUID: NearbyPeak] = [:]
        for p in peaks { byID[p.id] = p }
        for p in foundPeaks { byID[p.id] = p } // fresh data wins on duplicates

        peaks = pruneAndRecompute(Array(byID.values), from: location)
    }

    /// Prune a peak set against the current user location and recompute
    /// its geometry: drop entries we've moved well past (drop-radius
    /// hysteresis) or that haven't been re-confirmed within `peakTTL`,
    /// recompute distance/bearing for the survivors, and cap the total.
    /// Shared by the move path and the stationary no-move path so stale
    /// peaks age out in both cases.
    private func pruneAndRecompute(_ input: [NearbyPeak], from location: CLLocation) -> [NearbyPeak] {
        let dropRadius = searchRadius * 2 // hysteresis to avoid flicker at the edge
        let now = Date()
        let ttl = peakTTL

        // Recompute distance/bearing for *every* surviving peak against
        // the current user location so visual fades stay accurate.
        var recomputed: [NearbyPeak] = []
        recomputed.reserveCapacity(input.count)
        for var peak in input {
            let pl = CLLocation(latitude: peak.coordinate.latitude,
                                longitude: peak.coordinate.longitude)
            let d = location.distance(from: pl)
            // Drop entries we've moved well past, or that haven't been
            // re-confirmed by a search within the TTL window.
            guard d <= dropRadius else { continue }
            guard now.timeIntervalSince(peak.lastSeenAt) <= ttl else { continue }

            peak.distance = d
            peak.bearing = Geometry.bearing(from: location.coordinate, to: peak.coordinate)
            recomputed.append(peak)
        }

        // Cap the total — keep the closest ones first.
        recomputed.sort { $0.distance < $1.distance }
        if recomputed.count > maxRetainedPeaks {
            recomputed = Array(recomputed.prefix(maxRetainedPeaks))
        }

        return recomputed
    }
    
    /// Check if a peak is a duplicate of any existing peak (within 200m)
    private func isDuplicate(_ peak: NearbyPeak, in existing: [NearbyPeak]) -> Bool {
        existing.contains { other in
            let otherLoc = CLLocation(latitude: other.coordinate.latitude,
                                      longitude: other.coordinate.longitude)
            let peakLoc = CLLocation(latitude: peak.coordinate.latitude,
                                     longitude: peak.coordinate.longitude)
            return otherLoc.distance(from: peakLoc) < 200
        }
    }
    
    /// Search OpenStreetMap via Overpass API for peaks (natural=peak)
    /// Free, no API key required, excellent worldwide peak coverage.
    /// Privacy: lat/lon are rounded to ~3 decimals (~110 m at the equator)
    /// before being sent so the precise location of the device isn't
    /// disclosed to a third-party API; the search radius (5 km) is far
    /// larger than that quantisation error.
    ///
    /// Peaks whose OSM record carries an `ele` tag use that value
    /// directly. The rest get their altitude resolved via
    /// `TerrainElevationService` (the same DEM source the skyline
    /// uses), in a single batched call. Peaks for which neither source
    /// can supply an altitude are dropped — rendering them at a
    /// placeholder value would just put another fake-looking marker on
    /// the AR horizon, which was the whole reason Apple Maps got
    /// removed.
    ///
    /// `nonisolated` so the network fetch, JSON decode and per-peak
    /// geometry/elevation recompute all run off the main actor (mirrors
    /// the Android port doing this work on `Dispatchers.IO`). It touches
    /// no main-actor state — `searchRadius` is passed in, `Geometry` is
    /// a stateless enum of statics, and `TerrainElevationService` is an
    /// actor — and returns plain `Sendable` value types, so the result
    /// crosses back to the caller's actor safely under Swift 6.
    nonisolated private func searchOpenStreetMap(near location: CLLocation,
                                                 searchRadius: CLLocationDistance) async -> [NearbyPeak] {
        // Same ~110 m (3-decimal) grid the elevation cache uses — one
        // shared quantiser keeps the Overpass query and the DEM lookups
        // rounding identically (mirrors the Android port, where
        // PeakFinder calls TerrainElevationService.quantise).
        let qLat = TerrainElevationService.quantise(location.coordinate.latitude)
        let qLon = TerrainElevationService.quantise(location.coordinate.longitude)
        let radiusMeters = Int(searchRadius)

        // Overpass QL query: find all nodes tagged as natural=peak within radius
        let query = """
        [out:json][timeout:10];
        node["natural"="peak"](around:\(radiusMeters),\(qLat),\(qLon));
        out body;
        """

        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://overpass-api.de/api/interpreter?data=\(encodedQuery)") else {
            return []
        }

        // Identify ourselves to the Overpass operators (their usage
        // policy asks for a meaningful, app-identifying User-Agent) and
        // cap the client-side transport wait at 10 s — matching the
        // in-query `[out:json][timeout:10]` server budget — instead of
        // inheriting URLSession's 60 s default.
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("me.nettrash.Geo/1.0 (+https://nettrash.me)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await Self.sendWithRetry(req)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return []
            }

            let result = try JSONDecoder().decode(OverpassResponse.self, from: data)

            // Pass 1: filter by radius, parse name / coords / bearing,
            // and capture the `ele` tag when present.
            struct PartialPeak {
                let name: String
                let coordinate: CLLocationCoordinate2D
                let distance: Double
                let bearing: Double
                var altitude: Double?
            }
            var partials: [PartialPeak] = result.elements.compactMap { element in
                guard let name = element.tags?.name, !name.isEmpty else { return nil }

                let peakCoord = CLLocationCoordinate2D(latitude: element.lat, longitude: element.lon)
                let peakLocation = CLLocation(latitude: element.lat, longitude: element.lon)
                let distance = location.distance(from: peakLocation)
                guard distance <= searchRadius else { return nil }

                let bearing = Geometry.bearing(from: location.coordinate, to: peakCoord)
                let altitude: Double? = element.tags?.ele.flatMap { Double($0) }
                return PartialPeak(name: name,
                                   coordinate: peakCoord,
                                   distance: distance,
                                   bearing: bearing,
                                   altitude: altitude)
            }

            // Pass 2: resolve missing altitudes from the terrain DEM.
            // One batched lookup for every peak that lacks an `ele`
            // tag; `TerrainElevationService` deduplicates against its
            // ~110 m cache grid so neighbouring peaks share work.
            var needsElevation: [(index: Int, coord: CLLocationCoordinate2D)] = []
            for (i, p) in partials.enumerated() where p.altitude == nil {
                needsElevation.append((i, p.coordinate))
            }
            if !needsElevation.isEmpty {
                let coords = needsElevation.map { $0.coord }
                let elevations = await TerrainElevationService.shared.elevations(at: coords)
                for (k, entry) in needsElevation.enumerated() {
                    if let e = elevations[k] {
                        partials[entry.index].altitude = e
                    }
                }
            }

            // Drop peaks whose altitude we couldn't resolve from either
            // OSM tags or the DEM service. We deliberately do *not*
            // fall back to "user altitude + 100m" any more — that
            // placeholder was the second half of the Apple-Maps fake-
            // peak problem, putting markers at arbitrary heights on
            // the AR horizon.
            return partials.compactMap { p in
                guard let alt = p.altitude else { return nil }
                return NearbyPeak(
                    name: p.name,
                    coordinate: p.coordinate,
                    altitude: alt,
                    distance: p.distance,
                    bearing: p.bearing
                )
            }
        } catch {
            AppLog.ar.error("OpenStreetMap peak search error: \(String(describing: error))")
            return []
        }
    }

    /// Minimum spacing between Overpass requests. Their usage policy asks
    /// clients to go easy; ~1 s keeps us a polite citizen on the shared
    /// public endpoint.
    nonisolated private static let minOverpassInterval: TimeInterval = 1.0

    /// Issue `req`, enforcing `minOverpassInterval` between successive
    /// Overpass requests and retrying ONCE on a throttling / transient
    /// server response (HTTP 429 or 5xx). Honours a `Retry-After` header
    /// when present (seconds), else a short fixed backoff. The final
    /// response — success or not — is returned, preserving the existing
    /// graceful empty-result fallback. `nonisolated` and Sendable-safe so
    /// it stays callable from the off-main-actor `searchOpenStreetMap`;
    /// the `Task.sleep` calls suspend without blocking a thread.
    nonisolated private static func sendWithRetry(_ req: URLRequest) async throws -> (Data, URLResponse) {
        let slot = await OverpassThrottle.shared.waitForSlot(minInterval: minOverpassInterval)
        var (data, response) = try await URLSession.shared.data(for: req)

        if let http = response as? HTTPURLResponse, http.statusCode == 429 || (500..<600).contains(http.statusCode) {
            // Fallback backoff varies per request slot (a monotonic
            // counter) rather than via `random`, so concurrent searches
            // don't all retry in lockstep: 0.5 s base + up to ~1 s jitter.
            let jitter = 0.5 + Double(slot % 4) * 0.25
            let wait = Self.retryDelay(from: http, fallback: jitter)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            _ = await OverpassThrottle.shared.waitForSlot(minInterval: minOverpassInterval)
            (data, response) = try await URLSession.shared.data(for: req)
        }
        return (data, response)
    }

    /// Seconds to wait before the single retry: the `Retry-After` header
    /// (delta-seconds form) if the server sent one, otherwise `fallback`.
    nonisolated private static func retryDelay(from http: HTTPURLResponse, fallback: TimeInterval) -> TimeInterval {
        if let header = http.value(forHTTPHeaderField: "Retry-After"),
           let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)),
           seconds >= 0 {
            return min(seconds, 5)
        }
        return fallback
    }

    /// Find known mountains from app data that are within range
    private func findKnownMountains(near location: CLLocation, mountainsData: MountainData?) -> [NearbyPeak] {
        guard let data = mountainsData else { return [] }
        
        var results: [NearbyPeak] = []
        
        let allLists = [data.highest, data.sevenPeaks, data.snowLeopardOfRussia].compactMap { $0 }
        
        for list in allLists {
            guard let mountains = list.mountains else { continue }
            for mountain in mountains {
                guard let lat = mountain.coordinates?.latitude,
                      let lon = mountain.coordinates?.longitude,
                      let name = mountain.name else { continue }
                
                let mountainLocation = CLLocation(latitude: lat, longitude: lon)
                let distance = location.distance(from: mountainLocation)
                
                guard distance <= searchRadius else { continue }
                
                let mountainBearing = Geometry.bearing(from: location.coordinate,
                                                       to: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                
                results.append(NearbyPeak(
                    name: name,
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    altitude: Double(mountain.height ?? 0),
                    distance: distance,
                    bearing: mountainBearing
                ))
            }
        }
        
        return results
    }


}

/// Process-wide rate limiter for the shared public Overpass endpoint.
/// `PeakFinder.searchOpenStreetMap` is `nonisolated` and main-actor-free,
/// so the `lastRequestDate` it needs to throttle against can't live on the
/// (main-actor) `PeakFinder` instance — this tiny actor owns it instead,
/// serialising concurrent live-refresh searches behind one gate.
private actor OverpassThrottle {
    static let shared = OverpassThrottle()

    private var lastRequestDate: Date?
    private var slotCount = 0

    /// Sleep just long enough that this request lands at least
    /// `minInterval` after the previous one, then stamp `now` and return
    /// a monotonic slot index (used to vary retry jitter without
    /// `random`). The `Task.sleep` suspends without blocking a thread.
    @discardableResult
    func waitForSlot(minInterval: TimeInterval) async -> Int {
        if let last = lastRequestDate {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < minInterval {
                try? await Task.sleep(nanoseconds: UInt64((minInterval - elapsed) * 1_000_000_000))
            }
        }
        lastRequestDate = Date()
        slotCount &+= 1
        return slotCount
    }
}

// MARK: - OpenStreetMap Overpass API Response Models

private struct OverpassResponse: Decodable {
    let elements: [OverpassElement]
}

private struct OverpassElement: Decodable {
    let lat: Double
    let lon: Double
    let tags: OverpassTags?
}

private struct OverpassTags: Decodable {
    let name: String?
    let ele: String?  // elevation in meters (stored as string in OSM)
}
