//
//  PeakFinder.swift
//  Geo
//
//  Created by nettrash on 24/03/2026.
//

import Foundation
import CoreLocation

// MARK: - Peak search outcomes

/// Outcome of a live `natural=peak` fetch, which distinguishes "the server
/// answered and there are no peaks here" (`.success([])`) from "we never got an
/// answer" (`.failure`). Collapsing those two is what turned a loaded Overpass
/// mirror into a silently empty Nature tab that then refused to retry: the
/// failure was stored as if it were a result.
enum PeakFetchOutcome: Sendable {
    case success([NearbyPeak])
    case failure(String)

    /// The reason a search failed, for logging and for `lastSearchError`.
    var failureSummary: String? {
        if case .failure(let reason) = self { return reason }
        return nil
    }
}

/// Result of trying ONE Overpass mirror. Private to the failover loop: a
/// rejected attempt is a reason to try the next mirror, never an answer.
private enum OverpassAttempt: Sendable {
    case peaks([NearbyPeak])
    case rejected(String)
}

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

    /// `true` when the peaks on screen are only what we happen to have, not a
    /// confirmed-current answer: restored from disk after a relaunch, or kept
    /// alive through a failed search. The Nature view labels the count
    /// "possibly outdated" instead of letting an old horizon look like a live
    /// one (and instead of showing `0`, which looked identical to a failure).
    /// Never set while a downloaded offline pack covers here (the pack IS the
    /// offline answer), cleared by a success, and left alone by the reuse and
    /// in-flight paths, which confirm nothing.
    @Published var peaksAreStale = false

    /// One-line summary of the last failed search (e.g.
    /// `"overpass-api.de: HTTP 502; overpass.private.coffee: timed out"`), kept
    /// for the console. Cleared by the next success.
    @Published var lastSearchError: String?

    private let searchRadius: CLLocationDistance = 5000 // 5 km
    private var lastSearchLocation: CLLocation?
    private let minimumSearchDistance: CLLocationDistance = 500 // re-search after moving 500m

    /// How far a peak may be from the observer and still be kept for the AR
    /// overlay. Deliberately MUCH larger than `searchRadius`: the live Overpass
    /// query only reaches 5 km (to stay polite on the shared endpoint), but a
    /// downloaded offline pack holds peaks out to 100 km — and in a camera
    /// peak-identifier the summits you point at are the distant ones on the
    /// horizon. Capping at `searchRadius × 2` threw ~90 % of a big pack away.
    /// The AR projection already culls peaks that fall below the horizon / off
    /// screen, so this is a coverage bound, not a visibility one. Mirrors
    /// Android `PeakFinder.maxPeakRenderDistanceM`.
    private let maxPeakRenderDistance: CLLocationDistance = 80_000 // 80 km

    /// Maximum number of peaks we keep in the merged set. Older / further
    /// entries are evicted first when this is exceeded. Larger than before so a
    /// dense range doesn't evict the distant flagship summits (which are the
    /// whole point of pointing the camera at the horizon) in favour of nearer
    /// foothills. Only in-view peaks are actually drawn, so the on-screen count
    /// stays small regardless.
    private let maxRetainedPeaks: Int = 300

    /// Time after which a peak that has not been re-confirmed by a search
    /// gets dropped, even if the user hasn't moved. Stops stale results
    /// from accumulating if the user sits in one place for hours.
    ///
    /// Applied ONLY right after a confirmed answer (the success-path merge):
    /// a peak is "not re-confirmed" only when a search could have confirmed
    /// it. During an outage nothing can be, and cutting by age there emptied
    /// the horizon an hour into it — carried-over peaks and the restored
    /// snapshot included.
    private let peakTTL: TimeInterval = 60 * 60

    /// A previous result may be reused for at most this long. Distance alone is
    /// not a validity rule: standing still used to pin `lastSearchLocation`
    /// forever — and iOS pauses the location stream after 15 s of no movement
    /// (`GeoAppDelegate.locationManagerDidPauseLocationUpdates`), so the fix it
    /// was compared against stopped updating too — which made the "no movement"
    /// fast path hit forever and a failed search never retry. Age makes a
    /// stationary user ask again.
    private let maxCacheAge: TimeInterval = 15 * 60

    /// After a failed search, wait this long before asking Overpass again. The
    /// Nature view asks every 5 s; without a backoff a loaded shared mirror
    /// gets hammered for the entire outage.
    private let retryBackoff: TimeInterval = 60

    /// How long a result loaded from disk may still be shown. Peaks are static
    /// geography, so a clearly-marked week-old set beats an empty horizon while
    /// Overpass is unhealthy.
    private let persistedMaxAge: TimeInterval = 7 * 24 * 60 * 60

    /// Only reuse the persisted set when it was cached within this distance of
    /// the current position: peaks 60 km away in another valley are not
    /// "nearby peaks".
    private let persistedReuseDistance: CLLocationDistance = 50_000

    private var lastSuccessAt: Date?
    private var lastFailureAt: Date?

    /// The clock every freshness decision reads: the reuse / backoff check, the
    /// `lastSeenAt` stamps, the TTL cut and the snapshot age. A seam so tests
    /// can sit through an hour-long outage without waiting for one; the app
    /// never replaces it. (The per-search fetch deadline is wall-clock time
    /// inside the `nonisolated` fetch and does not read this.)
    var now: () -> Date = { Date() }

    /// Guards against overlapping searches: the view asks every 5 s while a
    /// failover search can take tens of seconds, and concurrent searches would
    /// multiply the load on a shared public endpoint.
    private var isSearching = false

    /// The persisted snapshot is read once, lazily, on the first search — only
    /// then do we know a location to judge "is this snapshot even for here?".
    private var didLoadPersisted = false

    /// Where the last successful result is persisted. Same Caches directory the
    /// terrain cache uses: derived data, not user data, safe to lose. Exposed
    /// for tests.
    nonisolated static let cacheURL: URL? = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        return dir?.appendingPathComponent("NearbyPeaksCache.json")
    }()

    /// Search for peaks near the given location. The local sources — bundled
    /// known mountains and the downloaded offline-pack peaks — are merged and
    /// published BEFORE the network is awaited, so they are on screen at once
    /// and stay there whatever the network does; the OSM answer is merged in
    /// when it arrives.
    func searchPeaks(near location: CLLocation, mountainsData: MountainData?,
                     offlinePeaks: [NearbyPeak] = [],
                     observerAltitude: Double? = nil) async {
        // Observer altitude for the horizon-visibility cut. Prefer the caller's
        // (barometer-preferred) value — GPS altitude can be tens of metres off,
        // or garbage-low, which would wrongly hide visible peaks. Falls back to
        // the fix's altitude.
        let obsAlt = observerAltitude ?? location.altitude
        loadPersistedIfNeeded(near: location, observerAltitude: obsAlt, offlinePeaks: offlinePeaks)

        // Don't re-search if we haven't moved much AND the previous result is
        // still young enough to trust, or while a search is already in flight.
        // Both fast paths still refresh the existing set against the current
        // location (drop radius, horizon, cap) instead of a bare `return` — but
        // they confirm nothing, so they neither expire peaks by `peakTTL` nor
        // touch `peaksAreStale` / `lastSearchError`. A stationary user's stale
        // peaks still age out, at the next confirmed answer: the cache age
        // makes one happen at least every 15 min.
        if isSearching {
            // A failover search can outlive the 5 s refresh tick. Fold the
            // duplicate request into the one in flight instead of stacking a
            // second search onto an already-loaded shared endpoint.
            peaks = pruneAndRecompute(peaks, from: location, observerAltitude: obsAlt)
            return
        }

        // Reuse the previous result while it is still trustworthy: no movement
        // AND an answer young enough to keep. Deliberately no `!peaks.isEmpty`
        // here — during an outage the set can legitimately be empty, and "we
        // asked a few seconds ago and it refused" is exactly when NOT to ask
        // again.
        if let last = lastSearchLocation,
           last.distance(from: location) < minimumSearchDistance,
           canReuseLastResult(at: now()) {
            peaks = pruneAndRecompute(peaks, from: location, observerAltitude: obsAlt)
            return
        }

        // A search is about to hit the network; the `defer` matters because the
        // failure path below returns early. The location is stamped BEFORE the
        // request, so a tick that lands inside the retry backoff takes the
        // reuse path above instead of firing another request at a loaded mirror.
        isSearching = true
        lastSearchLocation = location
        defer { isSearching = false }

        // Local sources first, published before the `await`. Bundled known
        // mountains (out to the render distance) and the downloaded
        // offline-pack peaks need no network, so they go on screen now instead
        // of after a failover that can take ~25 s — and a failed search keeps
        // them, where it used to return without them (which is how a
        // downloaded pack showed 0 peaks with no signal). Offline peaks are
        // stamped fresh; the same 200 m rule as the merge below keeps a local
        // copy of a peak already on screen from doubling it. It is checked
        // through a `DuplicateIndex`, not a scan of everything merged so far:
        // this merge runs on the main actor on every network search — each
        // retry of an outage included — over every pack's peaks (up to 4000
        // a pack), and the scan made it quadratic in them.
        let previousPeaks = peaks
        let knownPeaks = findKnownMountains(near: location, mountainsData: mountainsData)
        var workingPeaks = previousPeaks
        var workingIndex = DuplicateIndex(workingPeaks)
        for knownPeak in knownPeaks
        where !isDuplicate(knownPeak, in: workingIndex.neighbourhood(of: knownPeak)) {
            workingPeaks.append(knownPeak)
            workingIndex.add(knownPeak)
        }
        let mergedAt = now()
        for var offline in offlinePeaks
        where !isDuplicate(offline, in: workingIndex.neighbourhood(of: offline)) {
            offline.lastSeenAt = mergedAt
            workingPeaks.append(offline)
            workingIndex.add(offline)
        }
        peaks = pruneAndRecompute(workingPeaks, from: location, observerAltitude: obsAlt)

        // OSM is now the only network-backed source; bundled
        // `MountainData` and `offlinePeaks` are local. Apple Maps was
        // removed — see the class-level comment for why.
        //
        // `fetchPeakOutcome` is `nonisolated static`: the fetch, JSON decode
        // and per-peak geometry/elevation recompute run off the main actor
        // so they can't drop AR frames during the ~5 s live refresh. The
        // merges on either side of the `await` run on the main actor, as do
        // the @Published `peaks` assignments.
        let outcome = await Self.fetchPeakOutcome(center: location.coordinate,
                                                  radiusMeters: searchRadius)
        guard case .success(let osmResults) = outcome else {
            // A failed search is NOT a result. Keep showing the working set —
            // what we already had (live peaks, or the snapshot restored from
            // disk) plus the local sources merged above — with its geometry
            // refreshed against the current fix, and mark it stale unless a
            // downloaded pack covers here. Nothing is aged out by `peakTTL`:
            // an outage re-confirms nothing, so it may expire nothing either.
            //
            // Previously this fell through to the merge below with an empty OSM
            // set: `peakTTL` then dropped everything the failed search could
            // not re-confirm — downloaded offline-pack peaks included — so
            // waiting made it strictly worse. It also stamped
            // `lastSearchLocation`, which put the *failure* on the cache path
            // and stopped any retry until the user walked 500 m. Both are why
            // an Overpass outage used to look like "there are no peaks here".
            //
            // Stamped when the failure ARRIVED, after the `await`: the retry
            // backoff runs from the end of a failover that can take ~30 s, not
            // from its start.
            lastFailureAt = now()
            lastSearchError = outcome.failureSummary
            AppLog.ar.error("Nearby peaks: search failed (\(outcome.failureSummary ?? "unknown"))")
            peaks = pruneAndRecompute(peaks, from: location, observerAltitude: obsAlt)
            peaksAreStale = !peaks.isEmpty && !offlinePackCovers(location, offlinePeaks: offlinePeaks)
            return
        }

        // Only a confirmed answer counts as fresh. (The search *location* was
        // stamped before the request, to pace retries; the *result* only ages
        // from a success, so a failure never becomes the thing we serve.)
        let answeredAt = now()
        lastSuccessAt = answeredAt
        lastFailureAt = nil
        lastSearchError = nil
        peaksAreStale = false

        // 1. Start with the OSM-curated peaks, stamped with the answer's
        //    arrival on the same clock the TTL cut below reads. Steps 2 and 3
        //    check each local peak against everything accepted before it
        //    through a `DuplicateIndex`, as the merge before the `await` does
        //    and for the same reason: this merge, too, runs on the main actor
        //    over every pack's peaks, after every answer.
        var foundPeaks: [NearbyPeak] = osmResults.map { var p = $0; p.lastSeenAt = answeredAt; return p }
        var foundIndex = DuplicateIndex(foundPeaks)

        // 2. Merge known mountains from bundled data, de-duplicating
        //    against anything OSM already returned at the same spot.
        for knownPeak in knownPeaks
        where !isDuplicate(knownPeak, in: foundIndex.neighbourhood(of: knownPeak)) {
            foundPeaks.append(knownPeak)
            foundIndex.add(knownPeak)
        }

        // 3. Merge peaks from downloaded offline packs so they complement the
        //    live 5 km query (with NO signal they come from the merge before
        //    the `await`). Stamp them fresh so the TTL cut in
        //    `pruneAndRecompute` doesn't drop them the instant they merge;
        //    the drop-radius hysteresis still removes any too far to see.
        for var offline in offlinePeaks
        where !isDuplicate(offline, in: foundIndex.neighbourhood(of: offline)) {
            offline.lastSeenAt = answeredAt
            foundPeaks.append(offline)
            foundIndex.add(offline)
        }

        // Merge with the previous result set so a transient empty / partial
        // response from Overpass doesn't wipe peaks that are still valid. The
        // previous set is the one from BEFORE the local merge above: steps 2
        // and 3 re-add the local sources, deduped against the OSM answer.
        //
        // A previous peak is carried over only while no fresh peak lies within
        // 200 m of it. One that has a fresh peak there is replaced by that
        // peak, whatever its id: by its own fresh copy, or by the OSM node for
        // a bundled summit an EARLIER search left on screen — a failed search,
        // or one made before the summit's node came inside the 5 km query.
        // Carried over by id instead, as in v1.3, that summit stood next to
        // the node until `peakTTL` dropped it, up to an hour. The fresh peaks
        // then go in by id; the nodes of one answer are never deduped against
        // each other.
        var byID: [UUID: NearbyPeak] = [:]
        for p in previousPeaks where !isDuplicate(p, in: foundIndex.neighbourhood(of: p)) {
            byID[p.id] = p
        }
        for p in foundPeaks { byID[p.id] = p }

        // The one place `peakTTL` applies: right after a confirmed answer.
        let merged = pruneAndRecompute(Array(byID.values), from: location, observerAltitude: obsAlt,
                                       confirmedAt: answeredAt)
        peaks = merged
        persist(merged, center: location.coordinate)
    }

    /// Prune a peak set against the current user location and recompute
    /// its geometry: drop entries we've moved well past (drop-radius
    /// hysteresis) or that sit below the horizon from here, recompute
    /// distance/bearing for the survivors, and cap the total. Every path
    /// that publishes `peaks` goes through here.
    ///
    /// `confirmedAt` is passed by the success-path merge ONLY, right after a
    /// confirmed answer, and also drops entries that answer did not
    /// re-confirm within `peakTTL`. The reuse, in-flight, pre-network,
    /// failure and restore paths confirm nothing, so they expire nothing.
    private func pruneAndRecompute(_ input: [NearbyPeak], from location: CLLocation,
                                   observerAltitude: Double,
                                   confirmedAt: Date? = nil) -> [NearbyPeak] {
        let dropRadius = maxPeakRenderDistance // keep distant offline-pack peaks visible
        let ttl = peakTTL

        // Recompute distance/bearing for *every* surviving peak against
        // the current user location so visual fades stay accurate.
        var recomputed: [NearbyPeak] = []
        recomputed.reserveCapacity(input.count)
        for var peak in input {
            let pl = CLLocation(latitude: peak.coordinate.latitude,
                                longitude: peak.coordinate.longitude)
            let d = location.distance(from: pl)
            // Drop entries we've moved well past, or — right after a confirmed
            // answer — that it did not re-confirm within the TTL window.
            guard d <= dropRadius else { continue }
            if let confirmedAt, confirmedAt.timeIntervalSince(peak.lastSeenAt) > ttl { continue }
            // Drop peaks hidden below the Earth's bulge from here — only keep the
            // ones actually above the visible horizon (what you can really see).
            guard Geometry.isAboveHorizon(observerAltitude: observerAltitude,
                                          targetAltitude: peak.altitude, distance: d) else { continue }

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

    // MARK: - Result freshness & persistence
    //
    // Three pieces make "the network failed" stop looking like "there are no
    // peaks here": a pure reuse decision the no-move path consults, a snapshot
    // written on success only, and that snapshot restored (marked stale, unless
    // a downloaded pack covers here) on the next launch.

    /// Pure reuse decision, extracted so the cache rules are unit-testable
    /// without a network or a location. A result is reusable while it is young;
    /// once it is stale it is still reused only while the retry backoff from a
    /// failed attempt is running, so a loaded mirror is not hammered on every
    /// refresh tick and the peaks on screen are never dropped for nothing.
    nonisolated static func canReuseResult(now: Date, lastSuccessAt: Date?, lastFailureAt: Date?,
                                           maxCacheAge: TimeInterval,
                                           retryBackoff: TimeInterval) -> Bool {
        // A confirmed result is reusable while it is young.
        if let lastSuccessAt, now.timeIntervalSince(lastSuccessAt) <= maxCacheAge { return true }
        // Otherwise — stale, or never succeeded at all — keep showing what we
        // have only while the retry backoff from a failed attempt is running.
        guard let lastFailureAt else { return false }
        return now.timeIntervalSince(lastFailureAt) < retryBackoff
    }

    private func canReuseLastResult(at now: Date) -> Bool {
        Self.canReuseResult(now: now,
                            lastSuccessAt: lastSuccessAt,
                            lastFailureAt: lastFailureAt,
                            maxCacheAge: maxCacheAge,
                            retryBackoff: retryBackoff)
    }

    /// `true` when a downloaded offline pack covers `location`: one of the pack
    /// peaks passed in lies within the render distance. A pack is the explicit
    /// offline answer, so what is shown under one is never labelled "possibly
    /// outdated" — in the no-signal case packs exist for, that label would be
    /// wrong, and v1.3 never showed it there.
    private func offlinePackCovers(_ location: CLLocation, offlinePeaks: [NearbyPeak]) -> Bool {
        offlinePeaks.contains { peak in
            location.distance(from: CLLocation(latitude: peak.coordinate.latitude,
                                               longitude: peak.coordinate.longitude)) <= maxPeakRenderDistance
        }
    }

    /// On-disk form of the last successful search. `distance` / `bearing` are
    /// derived against the live fix, so only identity and altitude are stored —
    /// and the centre only to 2 decimals (~1 km).
    private struct PeakSnapshot: Codable {
        struct Entry: Codable {
            let name: String
            let latitude: Double
            let longitude: Double
            let altitude: Double
        }
        let centerLatitude: Double
        let centerLongitude: Double
        let savedAt: Date
        let entries: [Entry]
    }

    /// Restore the persisted snapshot on the first search, if it is recent
    /// enough and near enough to be about *here*. `lastSeenAt` is re-stamped on
    /// load — those peaks were not "failing to be re-confirmed", they were on
    /// disk — and `peaksAreStale` is what tells the user they may be out of date
    /// (unless a downloaded pack covers here, see `offlinePackCovers`).
    private func loadPersistedIfNeeded(near location: CLLocation, observerAltitude: Double,
                                       offlinePeaks: [NearbyPeak]) {
        guard !didLoadPersisted else { return }
        didLoadPersisted = true
        guard let url = Self.cacheURL,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(PeakSnapshot.self, from: data),
              now().timeIntervalSince(snapshot.savedAt) <= persistedMaxAge else { return }
        let cachedCenter = CLLocation(latitude: snapshot.centerLatitude,
                                      longitude: snapshot.centerLongitude)
        guard cachedCenter.distance(from: location) <= persistedReuseDistance else { return }
        let restoredAt = now()
        let restored = snapshot.entries.map {
            NearbyPeak(name: $0.name,
                       coordinate: CLLocationCoordinate2D(latitude: $0.latitude,
                                                          longitude: $0.longitude),
                       altitude: $0.altitude, distance: 0, bearing: 0, lastSeenAt: restoredAt)
        }
        // Derive distance / bearing against the live fix BEFORE publishing: the
        // overlay fades and scales markers by `distance`, so the 0 placeholders
        // drew every restored peak at full size until the next 5 s tick.
        peaks = pruneAndRecompute(restored, from: location, observerAltitude: observerAltitude)
        peaksAreStale = !peaks.isEmpty && !offlinePackCovers(location, offlinePeaks: offlinePeaks)
        let restoredCount = peaks.count
        let ageMinutes = Int(restoredAt.timeIntervalSince(snapshot.savedAt) / 60)
        // `Logger` interpolations are autoclosures, so read the state into
        // locals rather than capture `self` inside the log statement.
        AppLog.ar.notice("Restored \(restoredCount) nearby peaks from disk (\(ageMinutes) min old)")
    }

    /// Write the last good result. Called on success only, so a failed search
    /// can never overwrite a usable snapshot with an empty one.
    private func persist(_ peaks: [NearbyPeak], center: CLLocationCoordinate2D) {
        guard let url = Self.cacheURL else { return }
        let snapshot = PeakSnapshot(
            // The centre's only use is the 50 km "is this snapshot for here?"
            // check, so ~1 km (2 decimals) is plenty — and the cache file does
            // not keep the user's precise position.
            centerLatitude: (center.latitude * 100).rounded() / 100,
            centerLongitude: (center.longitude * 100).rounded() / 100,
            savedAt: now(),
            entries: peaks.map {
                PeakSnapshot.Entry(name: $0.name,
                                   latitude: $0.coordinate.latitude,
                                   longitude: $0.coordinate.longitude,
                                   altitude: $0.altitude)
            })
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
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

    /// `isDuplicate` for a set that grows one peak at a time, without a scan of
    /// the whole set per peak. Peaks are kept in latitude bands of 0.002°
    /// (~222 m). A great-circle distance is never shorter than its north–south
    /// part, so two peaks less than 200 m apart are at most ~0.0018° of
    /// latitude apart, and only a peak's own band and the two beside it can
    /// hold its duplicate. Those get the exact `isDuplicate` test, so the
    /// answer is the same as the whole-set scan's. Mirrors Android
    /// `PeakFinder.DuplicateIndex`.
    private struct DuplicateIndex {
        private static let bandDegrees = 0.002
        private var bands: [Int: [NearbyPeak]] = [:]

        init(_ peaks: [NearbyPeak]) {
            for peak in peaks { add(peak) }
        }

        mutating func add(_ peak: NearbyPeak) {
            bands[Self.band(of: peak), default: []].append(peak)
        }

        /// Every indexed peak that can lie within 200 m of `peak`.
        func neighbourhood(of peak: NearbyPeak) -> [NearbyPeak] {
            let band = Self.band(of: peak)
            return (band - 1 ... band + 1).flatMap { bands[$0] ?? [] }
        }

        private static func band(of peak: NearbyPeak) -> Int {
            let latitude = peak.coordinate.latitude
            // Never trap the `Int` conversion on a latitude no real peak has.
            guard (-90...90).contains(latitude) else { return 0 }
            return Int((latitude / bandDegrees).rounded(.down))
        }
    }
    
    /// Public Overpass mirrors, in preference order.
    ///
    /// `overpass-api.de` is the canonical instance and the one the app used to
    /// have hardcoded — it is also the first to answer `502 "This Overpass API
    /// server is currently at capacity"`, `429`, or nothing at all when a busy
    /// shared IP exhausts its quota. The mirrors below routinely serve the
    /// identical query, so one unhealthy instance no longer means an empty
    /// Nature tab. Exposed for tests; keep in step with Android
    /// `PeakFinder.overpassEndpoints`.
    ///
    /// Only instances with GLOBAL data may be listed. A regional instance
    /// answers HTTP 200 with zero peaks everywhere outside its region, and
    /// that empty answer is indistinguishable from "there are no peaks here" —
    /// it is cached as a confirmed result (`overpass.osm.ch` holds Switzerland
    /// only: Mont Blanc came back with 0 peaks instead of 83, Fuji 0 instead
    /// of 11).
    nonisolated static let overpassEndpoints: [String] = [
        "https://overpass-api.de/api/interpreter",            // FOSSGIS e.V., the main instance
        "https://overpass.private.coffee/api/interpreter",    // Private.coffee (formerly overpass.kumi.systems)
        "https://overpass.openstreetmap.fr/api/interpreter"   // OpenStreetMap France
    ]

    /// Per-mirror transport wait. Shorter than the old single-host 10 s because
    /// the budget is now shared across mirrors; `fetchDeadline` bounds the lot.
    nonisolated private static let endpointTimeout: TimeInterval = 8

    /// Stop trying mirrors once this much time has passed, so a total outage
    /// costs one bounded search, not a full timeout (and retry) on every
    /// mirror in turn.
    nonisolated private static let fetchDeadline: TimeInterval = 30

    nonisolated private static let userAgent = "me.nettrash.Geo/1.0 (+https://nettrash.me)"

    /// Rotate the starting mirror so a fleet of phones (or the second half of a
    /// retry) does not keep leading with the same overloaded instance.
    nonisolated static func rotatedEndpoints(startingAt start: Int) -> [String] {
        let count = overpassEndpoints.count
        guard count > 0 else { return [] }
        let offset = ((start % count) + count) % count
        return Array(overpassEndpoints[offset...] + overpassEndpoints[..<offset])
    }

    /// Fetch OpenStreetMap `natural=peak` nodes within `radiusMeters` of
    /// `center`, failing over across `overpassEndpoints`.
    ///
    /// Free, no API key, excellent worldwide coverage. Privacy: lat/lon are
    /// rounded to ~3 decimals (~110 m) before being sent; the radius dwarfs
    /// that quantisation error.
    ///
    /// Returns `.success([])` when the query genuinely found nothing and
    /// `.failure(reason)` when no mirror answered — and a mirror whose answer
    /// carries an Overpass `runtime error` remark has not answered. The caller
    /// must treat those differently — replace the peaks vs. keep them — which
    /// is exactly the distinction the old `return []` on every non-200
    /// destroyed.
    nonisolated static func fetchPeakOutcome(center: CLLocationCoordinate2D,
                                             radiusMeters: Double) async -> PeakFetchOutcome {
        // Same ~110 m (3-decimal) grid the elevation cache uses, so the
        // Overpass query and the DEM lookups round identically.
        let qLat = TerrainElevationService.quantise(center.latitude)
        let qLon = TerrainElevationService.quantise(center.longitude)

        let query = """
        [out:json][timeout:10];
        node["natural"="peak"](around:\(Int(radiusMeters)),\(qLat),\(qLon));
        out body;
        """
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return .failure("query could not be percent-encoded")
        }

        var reasons: [String] = []
        let deadline = Date().addingTimeInterval(fetchDeadline)
        let start = await OverpassThrottle.shared.nextEndpointIndex(count: overpassEndpoints.count)
        for endpoint in rotatedEndpoints(startingAt: start) {
            let host = URL(string: endpoint)?.host ?? endpoint
            if Date() >= deadline {
                reasons.append("\(host): skipped (search deadline)")
                break
            }
            switch await attemptPeakFetch(endpoint: endpoint, encodedQuery: encodedQuery,
                                          center: center, radiusMeters: radiusMeters) {
            case .peaks(let peaks):
                return .success(peaks)
            case .rejected(let reason):
                reasons.append("\(host): \(reason)")
            }
        }
        let summary = reasons.isEmpty ? "no Overpass endpoint reachable"
                                      : reasons.joined(separator: "; ")
        AppLog.ar.error("Overpass peak search failed on all \(overpassEndpoints.count) endpoints — \(summary)")
        return .failure(summary)
    }

    /// Try ONE mirror. Everything that used to be a silent `return []` is now a
    /// logged `.rejected(reason)`, so the failover loop can move on and the
    /// failure summary names the instance that actually let us down.
    ///
    /// Peaks whose OSM record carries an `ele` tag use it directly; the rest get
    /// their altitude resolved via `TerrainElevationService` (the same DEM the
    /// skyline uses) in one batched call. Peaks neither source can supply an
    /// altitude for are dropped — a placeholder height would just put a
    /// fake-looking marker on the AR horizon.
    nonisolated private static func attemptPeakFetch(endpoint: String,
                                                     encodedQuery: String,
                                                     center: CLLocationCoordinate2D,
                                                     radiusMeters: Double) async -> OverpassAttempt {
        let centerLoc = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let host = URL(string: endpoint)?.host ?? endpoint
        guard let url = URL(string: "\(endpoint)?data=\(encodedQuery)") else {
            return .rejected("invalid request URL")
        }

        // Identify ourselves per the Overpass usage policy: a descriptive
        // User-Agent is what keeps us out of their bot block (unidentified
        // clients get `406 Not Acceptable`).
        var req = URLRequest(url: url, timeoutInterval: endpointTimeout)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await sendWithRetry(req)

            guard let http = response as? HTTPURLResponse else {
                return .rejected("no HTTP response")
            }
            guard http.statusCode == 200 else {
                AppLog.ar.warning("Overpass \(host) returned HTTP \(http.statusCode)")
                return .rejected("HTTP \(http.statusCode)")
            }

            let result = try JSONDecoder().decode(OverpassResponse.self, from: data)

            // An overloaded instance answers HTTP 200 with `elements: []` and a
            // remark such as "runtime error: Query ran out of memory …" or
            // "… Query timed out …". That is the server failing, not an empty
            // area: taken as `.peaks([])` it was a confirmed "no peaks here" —
            // cached for 15 min, the stale label cleared, the snapshot
            // overwritten, an empty offline pack saved. Reject it so the next
            // mirror is tried. Any other remark is still an answer.
            if let remark = result.remark,
               remark.range(of: "runtime error", options: .caseInsensitive) != nil {
                let reason = String(remark.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
                AppLog.ar.warning("Overpass \(host) answered a runtime error: \(reason)")
                return .rejected(reason)
            }

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
                let distance = centerLoc.distance(from: peakLocation)
                guard distance <= radiusMeters else { return nil }

                let bearing = Geometry.bearing(from: center, to: peakCoord)
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
            // OSM tags or the DEM service (no fake placeholder heights).
            return .peaks(partials.compactMap { p in
                guard let alt = p.altitude else { return nil }
                return NearbyPeak(
                    name: p.name,
                    coordinate: p.coordinate,
                    altitude: alt,
                    distance: p.distance,
                    bearing: p.bearing
                )
            })
        } catch {
            AppLog.ar.warning("Overpass \(host) failed: \(String(describing: error))")
            return .rejected(String(describing: error))
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
    /// response — success or not — is returned for `attemptPeakFetch` to
    /// accept or reject. `nonisolated` and Sendable-safe so it stays
    /// callable from the off-main-actor `attemptPeakFetch`; the
    /// `Task.sleep` calls suspend without blocking a thread.
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

    /// Find known mountains from app data that are within range.
    ///
    /// Bounded by `maxPeakRenderDistance`, not `searchRadius`: this is the one
    /// source that needs no network at all, and at 5 km it was hidden exactly
    /// where the summit is in front of you — you are rarely within 5 km of a
    /// mountain you can see, and never within 5 km of the whole ridge of them.
    /// The bundled list is 136 entries spread over the whole planet, so the
    /// widened bound adds at most 26 (the densest spot on Earth, Gasherbrum I)
    /// and normally none — it cannot meaningfully grow what `searchPeaks`
    /// dedupes.
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
                
                guard distance <= maxPeakRenderDistance else { continue }
                
                let mountainBearing = Geometry.bearing(from: location.coordinate,
                                                       to: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                
                results.append(NearbyPeak(
                    name: name,
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    altitude: Double(mountain.height ?? 0),
                    distance: distance,
                    bearing: mountainBearing,
                    lastSeenAt: now()
                ))
            }
        }
        
        return results
    }


}

/// Process-wide rate limiter for the shared public Overpass endpoint.
/// `PeakFinder.fetchPeakOutcome` is `nonisolated` and main-actor-free,
/// so the `lastRequestDate` it needs to throttle against can't live on the
/// (main-actor) `PeakFinder` instance — this tiny actor owns it instead,
/// serialising concurrent live-refresh searches behind one gate.
private actor OverpassThrottle {
    static let shared = OverpassThrottle()

    private var lastRequestDate: Date?
    private var slotCount = 0
    /// Rotating index into `PeakFinder.overpassEndpoints`, owned here because
    /// the fetch is `nonisolated static` and cannot hold mutable state itself.
    private var endpointCursor = 0

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

    /// Next mirror index to start from, advancing the cursor. Round-robin means
    /// a repeatedly-failing first choice is not retried first forever.
    func nextEndpointIndex(count: Int) -> Int {
        guard count > 0 else { return 0 }
        defer { endpointCursor = (endpointCursor + 1) % count }
        return endpointCursor
    }
}

// MARK: - OpenStreetMap Overpass API Response Models

private struct OverpassResponse: Decodable {
    let elements: [OverpassElement]
    /// Set when the query did not complete on the server — e.g. `"runtime
    /// error: Query timed out in "query" at line 2 after 10 seconds."` — which
    /// still arrives as HTTP 200 with an empty `elements`.
    let remark: String?
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
