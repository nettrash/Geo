//
//  OfflinePackManager.swift
//  Geo
//
//  Owns the offline-expedition-pack state: the saved packs, the live
//  download progress, and the seeding of the prefetched data back into
//  the two live caches so the AR view works with no signal:
//
//   • PeakFinder merges `combinedPeaks` (so named peaks / markers /
//     ridge labels appear area-wide offline), and
//   • TerrainElevationService pins the packs' DEM cells (so the terrain
//     skyline resolves from cache instead of going empty offline).
//
//  Download reuses the app's existing throttled, retry-backed public-API
//  paths (`PeakFinder.fetchOSMPeaks` / `TerrainElevationService`), so the
//  bounding-box prefetch is automatically polite to Overpass and
//  Open-Elevation. Owned by `GeoAppDelegate`.
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

    /// 0…1 across the DEM prefetch (the long phase).
    @Published private(set) var progress: Double = 0

    /// Short human-readable phase ("Finding peaks…", "Caching terrain…").
    @Published private(set) var statusText = ""

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
        progress = 0
        statusText = "Finding peaks…"
        defer {
            isDownloading = false
            statusText = ""
            progress = 0
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

        // 2. DEM: the centre's full skyline panorama (180×20 polar grid),
        //    fetched in chunks so we can show progress; each chunk goes
        //    through the elevation service's own 200 ms throttle + retry.
        statusText = "Caching terrain…"
        // Build the 3 600-point polar grid off the main actor — it's pure trig
        // and would otherwise run on the main thread during the download.
        let coords = await Task.detached { SkylineCalculator.skylineGridCoordinates(observer: center) }.value
        var cells: [String: Double] = [:]
        let chunkSize = 300
        var processed = 0
        var index = 0
        while index < coords.count {
            if Task.isCancelled { return }
            let end = min(index + chunkSize, coords.count)
            let slice = Array(coords[index..<end])
            let elevs = await TerrainElevationService.shared.elevations(at: slice)
            for (coord, elev) in zip(slice, elevs) {
                if let elev { cells[TerrainElevationService.gridKey(coord)] = elev }
            }
            processed += slice.count
            progress = Double(processed) / Double(coords.count)
            index = end
        }

        if Task.isCancelled { return }

        // 3. Persist + register.
        let id = UUID()
        let data = OfflinePackData(
            peaks: peaks.map {
                OfflinePackData.Peak(name: $0.name,
                                     lat: $0.coordinate.latitude,
                                     lon: $0.coordinate.longitude,
                                     altitude: $0.altitude)
            },
            cells: cells
        )
        // Don't register a pack whose data file didn't persist (disk full /
        // permission error) — that would leave a phantom entry in the list that
        // can never be re-seeded. The `defer` above still resets download state.
        guard store.saveData(id, data) else { return }

        let meta = OfflinePack(id: id, name: packName,
                               centerLat: center.latitude, centerLon: center.longitude,
                               radiusKm: radiusKm, createdAt: Date(),
                               peakCount: peaks.count, cellCount: cells.count)
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

    /// Delete a saved pack and re-seed the live caches without it.
    func delete(_ pack: OfflinePack) {
        store.deleteData(pack.id)
        packs.removeAll { $0.id == pack.id }
        store.saveIndex(packs)
        Task { await reseedConsumers() }
    }

    // MARK: - Seeding the live caches

    /// Rebuild `combinedPeaks` and the elevation service's pinned cells
    /// from every saved pack. Called at launch and after any pack change.
    private func reseedConsumers() async {
        // All disk reads + JSON decoding happen OFF the main actor (the store is
        // a non-isolated struct); only the published-state assignments and the
        // actor-isolated `setPinned` run back on the main actor.
        let store = self.store
        let loaded = await Task.detached { OfflinePackManager.loadAll(store: store) }.value
        await TerrainElevationService.shared.setPinned(loaded.cells)
        packs = loaded.metas
        combinedPeaks = loaded.peaks
    }

    /// Read the index + every pack's payload from disk and assemble the union
    /// of pinned cells + deduped peaks. `nonisolated` so it runs off the main
    /// actor when invoked from a detached task.
    nonisolated static func loadAll(store: OfflinePackStore)
        -> (metas: [OfflinePack], cells: [String: Double], peaks: [NearbyPeak]) {
        let metas = store.loadIndex().sorted { $0.createdAt > $1.createdAt }
        let datas = metas.compactMap { store.loadData($0.id) }
        let seed = assembleSeed(from: datas)
        return (metas, seed.cells, seed.peaks)
    }

    /// Pure assembly of the live-cache seed from loaded pack payloads: union the
    /// DEM cells (later packs win on key collision) and dedupe peaks by their
    /// coordinate-derived id. Pure + `nonisolated` so it's unit-testable
    /// without disk or the shared elevation-service singleton.
    nonisolated static func assembleSeed(from datas: [OfflinePackData])
        -> (cells: [String: Double], peaks: [NearbyPeak]) {
        var cells: [String: Double] = [:]
        var peaks: [NearbyPeak] = []
        var seen = Set<UUID>()
        for data in datas {
            for (k, v) in data.cells { cells[k] = v }
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
        return (cells, peaks)
    }

    // MARK: - Helpers

    /// A reasonable default pack name from the centre coordinate.
    static func defaultName(for center: CLLocationCoordinate2D) -> String {
        String(format: "Area %.3f, %.3f", center.latitude, center.longitude)
    }
}
