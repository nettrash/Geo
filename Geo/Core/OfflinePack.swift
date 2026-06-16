//
//  OfflinePack.swift
//  Geo
//
//  "Offline expedition pack" — a pre-cached area so the AR peaks +
//  terrain skyline keep working on a summit with no signal. Each pack
//  bundles the area's OSM peaks and the skyline DEM (digital elevation
//  model) sampled from the pack centre, both pulled through the same
//  throttled public-API paths the live app uses.
//
//  Storage is plain JSON files (Application Support), NOT Core Data:
//  the DEM blob is large and purely local, so there's no reason to sync
//  it through CloudKit. A lightweight `index.json` holds the metadata
//  the management UI lists; each pack's peaks + cells live in its own
//  `<id>.json` so the list doesn't have to load megabytes of terrain.
//
//  Map tiles are intentionally out of scope — MapKit/Google Maps
//  licensing forbids caching their tiles, so this is "offline data &
//  AR", not "offline map".
//

import Foundation
import CoreLocation

/// Lightweight metadata for one downloaded pack — what the management
/// list shows. The bulky peaks + DEM cells live in `OfflinePackData`.
struct OfflinePack: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    let centerLat: Double
    let centerLon: Double
    /// Radius (km) of the peak search box this pack was built with.
    let radiusKm: Double
    let createdAt: Date
    /// Named peaks cached for the area.
    var peakCount: Int
    /// ~110 m DEM grid cells cached for the centre's skyline panorama.
    var cellCount: Int

    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon)
    }
}

/// The heavy payload for one pack: its OSM peaks and the quantised
/// grid-cell → elevation map. Stored in `<id>.json`, loaded only when a
/// pack is created/deleted or seeded into the live caches at launch.
struct OfflinePackData: Codable {
    struct Peak: Codable {
        let name: String
        let lat: Double
        let lon: Double
        let altitude: Double
    }
    let peaks: [Peak]
    /// Key is `TerrainElevationService.gridKey` ("lat,lon" quantised to
    /// ~110 m), value is elevation in metres. Seeded into the elevation
    /// service as *pinned* cells so they survive LRU eviction offline.
    let cells: [String: Double]
}

/// File-backed persistence for offline packs. Pure I/O; the
/// `OfflinePackManager` owns the in-memory state and seeding.
struct OfflinePackStore {

    private let dir: URL?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
        let d = base?.appendingPathComponent("OfflinePacks", isDirectory: true)
        if let d {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        dir = d
    }

    private var indexURL: URL? { dir?.appendingPathComponent("index.json") }
    private func dataURL(_ id: UUID) -> URL? {
        dir?.appendingPathComponent("\(id.uuidString).json")
    }

    func loadIndex() -> [OfflinePack] {
        guard let url = indexURL,
              let data = try? Data(contentsOf: url),
              let packs = try? JSONDecoder.iso.decode([OfflinePack].self, from: data) else {
            return []
        }
        return packs
    }

    func saveIndex(_ packs: [OfflinePack]) {
        guard let url = indexURL else { return }
        do {
            let data = try JSONEncoder.iso.encode(packs)
            try data.write(to: url, options: .atomic)
        } catch {
            // Surface write failures (disk full / permissions) instead of
            // silently dropping them — matches the Android store's logging.
            AppLog.app.error("Offline pack index save failed: \(String(describing: error))")
        }
    }

    func loadData(_ id: UUID) -> OfflinePackData? {
        guard let url = dataURL(id),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.iso.decode(OfflinePackData.self, from: data)
    }

    /// Returns whether the pack's data file actually persisted, so the
    /// caller can avoid recording a metadata entry whose payload is missing
    /// (which would show as a phantom pack that can never be re-seeded).
    @discardableResult
    func saveData(_ id: UUID, _ data: OfflinePackData) -> Bool {
        guard let url = dataURL(id) else { return false }
        do {
            let encoded = try JSONEncoder.iso.encode(data)
            try encoded.write(to: url, options: .atomic)
            return true
        } catch {
            AppLog.app.error("Offline pack data save failed: \(String(describing: error))")
            return false
        }
    }

    func deleteData(_ id: UUID) {
        guard let url = dataURL(id) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
