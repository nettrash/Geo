//
//  OfflinePackTests.swift
//  GeoTests
//
//  Round-trip + seed-assembly tests for the offline expedition pack.
//

import XCTest
import CoreLocation
@testable import Geo

final class OfflinePackTests: XCTestCase {

    // MARK: - On-disk format round-trips

    func testPackDataRoundTrips() throws {
        let data = OfflinePackData(
            peaks: [OfflinePackData.Peak(name: "Rainier", lat: 46.8523, lon: -121.7603, altitude: 4392)],
            cells: ["46.852,-121.76": 4392, "46.853,-121.759": 4100],
            mediumCells: ["46.85,-121.76": 4200],
            coarseCells: ["46.86,-121.76": 3900]
        )
        let encoded = try JSONEncoder().encode(data)
        let decoded = try JSONDecoder().decode(OfflinePackData.self, from: encoded)

        XCTAssertEqual(decoded.peaks.count, 1)
        XCTAssertEqual(decoded.peaks.first?.name, "Rainier")
        XCTAssertEqual(decoded.cells["46.852,-121.76"], 4392)
        XCTAssertEqual(decoded.cells.count, 2)
        XCTAssertEqual(decoded.mediumCells?["46.85,-121.76"], 4200)
        XCTAssertEqual(decoded.coarseCells?["46.86,-121.76"], 3900)
    }

    /// A pack file saved before the far-terrain rings existed decodes fine —
    /// the ring layers are simply absent, and seeding treats them as empty.
    func testPreRingPackDataStillDecodes() throws {
        let legacy = #"{"peaks":[],"cells":{"45.0,7.0":3000}}"#
        let decoded = try JSONDecoder().decode(OfflinePackData.self,
                                               from: Data(legacy.utf8))
        XCTAssertEqual(decoded.cells.count, 1)
        XCTAssertNil(decoded.mediumCells)
        XCTAssertNil(decoded.coarseCells)
        let seed = OfflinePackManager.assembleSeed(from: [decoded])
        XCTAssertTrue(seed.mediumCells.isEmpty)
        XCTAssertTrue(seed.coarseCells.isEmpty)
    }

    func testIndexRoundTripsWithISO8601Date() throws {
        let meta = OfflinePack(id: UUID(), name: "Rainier area",
                               centerLat: 46.85, centerLon: -121.76, radiusKm: 25,
                               createdAt: Date(timeIntervalSince1970: 700_000_000),
                               peakCount: 3, cellCount: 3600, ringCellCount: 12_000)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode([OfflinePack].self, from: try encoder.encode([meta]))
        XCTAssertEqual(decoded, [meta])
    }

    // MARK: - Seed assembly (the reseed dedupe + cell union)

    /// Two packs that share a peak coordinate collapse to a single peak (the id
    /// is derived from the coordinate), and DEM cells union across packs with a
    /// later pack winning on a key collision.
    func testAssembleSeedDedupesPeaksAndUnionsCells() {
        let shared = OfflinePackData.Peak(name: "Shared", lat: 45.0, lon: 7.0, altitude: 3000)
        let packA = OfflinePackData(
            peaks: [shared, OfflinePackData.Peak(name: "OnlyA", lat: 45.1, lon: 7.1, altitude: 2500)],
            cells: ["45.0,7.0": 3000, "45.1,7.1": 2500],
            mediumCells: ["45.0,7.0": 2900],
            coarseCells: nil
        )
        let packB = OfflinePackData(
            peaks: [shared, OfflinePackData.Peak(name: "OnlyB", lat: 46.0, lon: 8.0, altitude: 4000)],
            cells: ["46.0,8.0": 4000, "45.0,7.0": 3100],   // collides with packA
            mediumCells: ["45.0,7.0": 3050],               // collides with packA's ring
            coarseCells: ["44.98,7.02": 2800]
        )

        let seed = OfflinePackManager.assembleSeed(from: [packA, packB])

        // Peaks: the shared coordinate appears once → 3 unique peaks.
        XCTAssertEqual(seed.peaks.count, 3)
        XCTAssertEqual(seed.peaks.filter { $0.name == "Shared" }.count, 1)

        // Cells: 3 distinct keys; the colliding key takes the later pack's value.
        XCTAssertEqual(seed.cells.count, 3)
        XCTAssertEqual(seed.cells["45.0,7.0"], 3100)
        XCTAssertEqual(seed.cells["46.0,8.0"], 4000)

        // Ring layers union the same way, later pack winning; a nil layer
        // contributes nothing.
        XCTAssertEqual(seed.mediumCells["45.0,7.0"], 3050)
        XCTAssertEqual(seed.coarseCells.count, 1)
    }

    func testAssembleSeedEmptyIsEmpty() {
        let seed = OfflinePackManager.assembleSeed(from: [])
        XCTAssertTrue(seed.peaks.isEmpty)
        XCTAssertTrue(seed.cells.isEmpty)
        XCTAssertTrue(seed.mediumCells.isEmpty)
        XCTAssertTrue(seed.coarseCells.isEmpty)
    }

    // MARK: - Far-terrain ring layers

    func testRingGridsSnapToTheirOwnLattices() {
        let center = CLLocationCoordinate2D(latitude: 47.1234, longitude: 8.5678)
        let medium = SkylineCalculator.offlineMediumPrefetchCoordinates(center: center)
        let coarse = SkylineCalculator.offlineCoarsePrefetchCoordinates(center: center)
        XCTAssertFalse(medium.isEmpty)
        XCTAssertFalse(coarse.isEmpty)
        XCTAssertLessThanOrEqual(medium.count, SkylineCalculator.offlineMaxRingCells)
        XCTAssertLessThanOrEqual(coarse.count, SkylineCalculator.offlineMaxRingCells)
        // Every node keys to a distinct cell of its own layer — the exact
        // property the live fallback lookup depends on (no phase drift,
        // no duplicate keys, no gaps).
        XCTAssertEqual(Set(medium.map(TerrainElevationService.gridKeyMedium)).count, medium.count)
        XCTAssertEqual(Set(coarse.map(TerrainElevationService.gridKeyCoarse)).count, coarse.count)
    }

    func testCoarseRingReachesTheSkylineRange() {
        // The coarse ring must reach (nearly) the 200 km skyline range —
        // that's the whole point of the layer: distant mountain ranges
        // staying in the offline silhouette.
        let center = CLLocationCoordinate2D(latitude: 47.0, longitude: 8.0)
        let coarse = SkylineCalculator.offlineCoarsePrefetchCoordinates(center: center)
        let maxLatSpanMeters = coarse.map { abs($0.latitude - 47.0) * 111_320 }.max() ?? 0
        XCTAssertGreaterThan(maxLatSpanMeters, 150_000)
    }

    func testPinnedRingFallbackResolvesWithoutNetwork() async {
        let service = TerrainElevationService()
        await service.clearCache()
        // Pin ONLY a coarse cell; query a nearby point that misses the fine
        // and medium layers. It must resolve through the coarse fallback —
        // and because everything resolves from pinned data, no network
        // request is ever attempted (the whole offline promise).
        let p = CLLocationCoordinate2D(latitude: 45.003, longitude: 7.006)
        let coarseKey = TerrainElevationService.gridKeyCoarse(p)
        await service.setPinned(fine: [:], medium: [:], coarse: [coarseKey: 1234])
        let result = await service.elevations(at: [p])
        XCTAssertEqual(result, [1234])
    }
}
