//
//  OfflinePackManager.swift
//  Geo
//
//  Owns the offline-expedition-pack state: the saved packs, the live
//  download progress, and the seeding of the prefetched peaks back into
//  `PeakFinder` (via `combinedPeaks`), so the AR view can still name the
//  mountains around you on a summit with no signal.
//
//  Packs are PEAKS ONLY. They used to also prefetch an area DEM grid (a
//  ~110 m core plus far-terrain rings out to 200 km) to feed the terrain
//  skyline; that skyline was removed — the modelled ridge rarely matched
//  the real one on camera — and the grid prefetch went with it. Peak
//  altitudes are still DEM-resolved at download time inside
//  `PeakFinder.fetchOSMPeaks`, which is one bounded lookup per peak.
//
//  Download reuses the app's existing throttled, retry-backed public-API
//  path (`PeakFinder.fetchOSMPeaks`), so the bounding-box prefetch is
//  automatically polite to Overpass. Owned by `GeoAppDelegate`.
//

import Foundation
import CoreLocation
import Combine

@MainActor
final class OfflinePackManager: ObservableObject {

    /// Saved packs, newest first.
    @Published private(set) var packs: [OfflinePack] = []

    /// True while a prefetch is running (drives the progress UI and
    /// disables a second concurrent download).
    @Published private(set) var isDownloading = false

    /// Short human-readable phase ("Finding peaks…", "Updating…").
    @Published private(set) var statusText = ""

    /// The pack currently being re-downloaded by `updatePack`, or `nil`. Lets the
    /// management list show a per-row spinner on exactly the pack being refreshed.
    @Published private(set) var updatingPackID: UUID?

    /// Union of every pack's peaks, deduped — handed to `PeakFinder` so
    /// the area's peaks show offline. Distance/bearing are placeholders;
    /// PeakFinder recomputes them against the live location on merge.
    @Published private(set) var combinedPeaks: [NearbyPeak] = []

    /// Source of the user's current position for "download current area".
    /// Set by `GeoAppDelegate` after `Location` is constructed.
    weak var location: Location?

    /// Hard cap on stored peaks per pack so a huge radius in a dense range
    /// can't bloat the file (the live view only shows the nearest ~200).
    private let maxPackPeaks = 4000

    private let store = OfflinePackStore()

    init() {
        // No synchronous disk I/O in init: the index load + JSON decode + cache
        // seeding all run off the main actor inside the launch Task (see
        // `reseedConsumers`), which publishes `packs` back on the main actor.
        Task { await reseedConsumers() }
    }

    /// Whether a "download current area" can be offered right now.
    var hasCurrentLocation: Bool { location?.location != nil }

    // MARK: - Download

    /// Prefetch and persist a pack centred on `center` out to `radiusKm`.
    /// No-ops if a download is already running. Progress is published as
    /// it runs; the whole thing is cancellation-safe via `Task`.
    func createPack(name: String, center: CLLocationCoordinate2D, radiusKm: Double) async {
        guard !isDownloading else { return }
        isDownloading = true
        statusText = "Finding peaks…"
        defer {
            isDownloading = false
            statusText = ""
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let packName = trimmed.isEmpty ? Self.defaultName(for: center) : trimmed

        // 1. Peaks across the whole radius (one throttled Overpass query).
        let osmPeaks = await PeakFinder.fetchOSMPeaks(center: center,
                                                      radiusMeters: radiusKm * 1000)
        // Keep the CLOSEST peaks when capping — Overpass returns nodes in
        // arrival order, not by distance, so a naive prefix could drop nearby
        // peaks while keeping far ones. Mirrors the live PeakFinder path.
        let peaks = Array(osmPeaks.sorted { $0.distance < $1.distance }.prefix(maxPackPeaks))

        if Task.isCancelled { return }

        // Note: `fetchOSMPeaks` already resolves the altitude of every peak whose
        // OSM node carries no `ele` tag, via one batched `TerrainElevationService`
        // lookup — that's a bounded number of DEM points (one per peak) and it
        // MUST stay, because a peak with no altitude gets dropped. What used to
        // live here on top of that was an *area DEM grid* prefetch (a ~110 m core
        // plus ~550 m / ~2.2 km far-terrain rings out to 200 km — tens of
        // thousands of Open-Elevation points) that existed solely to feed the
        // terrain skyline. The skyline is gone, so the grid prefetch is too: packs
        // are now just peaks, which makes them small and quick.

        // 2. Persist + register.
        let id = UUID()
        let data = OfflinePackData(
            peaks: peaks.map {
                OfflinePackData.Peak(name: $0.name,
                                     lat: $0.coordinate.latitude,
                                     lon: $0.coordinate.longitude,
                                     altitude: $0.altitude)
            }
        )
        // Don't register a pack whose data file didn't persist (disk full /
        // permission error) — that would leave a phantom entry in the list that
        // can never be re-seeded. The `defer` above still resets download state.
        guard store.saveData(id, data) else { return }

        let meta = OfflinePack(id: id, name: packName,
                               centerLat: center.latitude, centerLon: center.longitude,
                               radiusKm: radiusKm, createdAt: Date(),
                               peakCount: peaks.count)
        packs.insert(meta, at: 0)
        store.saveIndex(packs)
        await reseedConsumers()
    }

    /// Rename a saved pack. The name lives only in the index (not the DEM/peak
    /// payload), so this just rewrites the index — no cache reseed needed. An
    /// all-whitespace name is ignored (keeps the current name).
    func rename(_ pack: OfflinePack, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let i = packs.firstIndex(where: { $0.id == pack.id }) else { return }
        packs[i].name = trimmed
        store.saveIndex(packs)
    }

    /// Re-fetch a saved pack's peaks for its ORIGINAL centre + radius and replace
    /// its stored data in place (same id / name / created date). Use it to pick
    /// up new OpenStreetMap peaks, or to complete a download that was partial.
    ///
    /// A failed or empty fetch (offline, Overpass down) is IGNORED — an empty
    /// result almost always means the request didn't get through, not that a
    /// once-populated area is suddenly peakless, so an update attempt can never
    /// wipe a good pack.
    func updatePack(_ pack: OfflinePack) async {
        guard !isDownloading else { return }
        isDownloading = true
        updatingPackID = pack.id
        statusText = "Updating…"
        defer {
            isDownloading = false
            updatingPackID = nil
            statusText = ""
        }

        let osmPeaks = await PeakFinder.fetchOSMPeaks(center: pack.center,
                                                      radiusMeters: pack.radiusKm * 1000)
        let peaks = Array(osmPeaks.sorted { $0.distance < $1.distance }.prefix(maxPackPeaks))
        if Task.isCancelled { return }
        guard !peaks.isEmpty else { return }   // never overwrite a good pack with nothing

        let data = OfflinePackData(
            peaks: peaks.map {
                OfflinePackData.Peak(name: $0.name,
                                     lat: $0.coordinate.latitude,
                                     lon: $0.coordinate.longitude,
                                     altitude: $0.altitude)
            }
        )
        guard store.saveData(pack.id, data) else { return }
        if let i = packs.firstIndex(where: { $0.id == pack.id }) {
            packs[i].peakCount = peaks.count
            store.saveIndex(packs)
        }
        await reseedConsumers()
    }

    /// Delete a saved pack and re-seed the live caches without it.
    func delete(_ pack: OfflinePack) {
        store.deleteData(pack.id)
        packs.removeAll { $0.id == pack.id }
        store.saveIndex(packs)
        Task { await reseedConsumers() }
    }

    // MARK: - Seeding the live caches

    /// Rebuild `combinedPeaks` from every saved pack. Called at launch and after
    /// any pack change.
    private func reseedConsumers() async {
        // All disk reads + JSON decoding happen OFF the main actor (the store is
        // a non-isolated struct); only the published-state assignments run back
        // on the main actor.
        let store = self.store
        let loaded = await Task.detached { OfflinePackManager.loadAll(store: store) }.value
        packs = loaded.metas
        combinedPeaks = loaded.peaks
    }

    /// Read the index + every pack's payload from disk and assemble the deduped
    /// peak union. `nonisolated` so it runs off the main actor when invoked from
    /// a detached task.
    nonisolated static func loadAll(store: OfflinePackStore)
        -> (metas: [OfflinePack], peaks: [NearbyPeak]) {
        let metas = store.loadIndex().sorted { $0.createdAt > $1.createdAt }
        let datas = metas.compactMap { store.loadData($0.id) }
        return (metas, assembleSeed(from: datas))
    }

    /// Pure assembly of the live-cache seed from loaded pack payloads: dedupe
    /// peaks by their coordinate-derived id. Pure + `nonisolated` so it's
    /// unit-testable without disk.
    nonisolated static func assembleSeed(from datas: [OfflinePackData]) -> [NearbyPeak] {
        var peaks: [NearbyPeak] = []
        var seen = Set<UUID>()
        for data in datas {
            for p in data.peaks {
                let peak = NearbyPeak(
                    name: p.name,
                    coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon),
                    altitude: p.altitude,
                    distance: 0,
                    bearing: 0
                )
                if seen.insert(peak.id).inserted { peaks.append(peak) }
            }
        }
        return peaks
    }

    // MARK: - Helpers

    /// A reasonable default pack name from the centre coordinate.
    static func defaultName(for center: CLLocationCoordinate2D) -> String {
        String(format: "Area %.3f, %.3f", center.latitude, center.longitude)
    }
}
