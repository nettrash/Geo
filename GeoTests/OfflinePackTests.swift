//
//  OfflinePackTests.swift
//  GeoTests
//
//  Round-trip + seed-assembly tests for the offline expedition pack, and
//  download / update against a stubbed Overpass (`OverpassStub`, no network).
//
//  Packs are PEAKS ONLY. The DEM-grid half (a ~110 m core plus far-terrain
//  rings out to 200 km) existed to feed the terrain skyline; that skyline was
//  removed from the Nature tab, so the grid prefetch, the pinned-cell seeding
//  and their tests went with it. Peak altitudes are still DEM-resolved at
//  download time inside `PeakFinder.fetchPeakOutcome` (one bounded lookup per
//  peak), which is unaffected.
//

import XCTest
import CoreLocation
@testable import Geo

final class OfflinePackTests: XCTestCase {

    // MARK: - On-disk format round-trips

    func testPackDataRoundTrips() throws {
        let data = OfflinePackData(
            peaks: [OfflinePackData.Peak(name: "Rainier", lat: 46.8523, lon: -121.7603, altitude: 4392)]
        )
        let encoded = try JSONEncoder().encode(data)
        let decoded = try JSONDecoder().decode(OfflinePackData.self, from: encoded)

        XCTAssertEqual(decoded.peaks.count, 1)
        XCTAssertEqual(decoded.peaks.first?.name, "Rainier")
        XCTAssertEqual(decoded.peaks.first?.altitude, 4392)
    }

    /// A pack file written by an OLDER build still carries the skyline DEM blobs
    /// (`cells` / `mediumCells` / `coarseCells`). Those keys are no longer part
    /// of the model — `Codable` must ignore them rather than fail — so an
    /// existing pack on a user's device keeps working as a peak-only pack
    /// without any migration.
    func testLegacyPackWithDEMBlobsStillDecodes() throws {
        let legacy = #"""
        {"peaks":[{"name":"Mont Blanc","lat":45.8326,"lon":6.8652,"altitude":4808}],
         "cells":{"45.0,7.0":3000},
         "mediumCells":{"45.0,7.0":2900},
         "coarseCells":{"44.98,7.02":2800}}
        """#
        let decoded = try JSONDecoder().decode(OfflinePackData.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.peaks.count, 1)
        XCTAssertEqual(decoded.peaks.first?.name, "Mont Blanc")

        // And it still seeds PeakFinder.
        let seed = OfflinePackManager.assembleSeed(from: [decoded])
        XCTAssertEqual(seed.count, 1)
        XCTAssertEqual(seed.first?.name, "Mont Blanc")
    }

    /// Likewise for the index: an entry written with the old `cellCount` /
    /// `ringCellCount` counters decodes into the slimmed metadata.
    func testLegacyIndexEntryWithCellCountsStillDecodes() throws {
        let legacy = #"""
        [{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","name":"Rainier area",
          "centerLat":46.85,"centerLon":-121.76,"radiusKm":25,
          "createdAt":"1992-03-07T20:26:40Z","peakCount":3,
          "cellCount":3600,"ringCellCount":12000}]
        """#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([OfflinePack].self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.name, "Rainier area")
        XCTAssertEqual(decoded.first?.peakCount, 3)
    }

    func testIndexRoundTripsWithISO8601Date() throws {
        let meta = OfflinePack(id: UUID(), name: "Rainier area",
                               centerLat: 46.85, centerLon: -121.76, radiusKm: 25,
                               createdAt: Date(timeIntervalSince1970: 700_000_000),
                               peakCount: 3)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode([OfflinePack].self, from: try encoder.encode([meta]))
        XCTAssertEqual(decoded, [meta])
    }

    // MARK: - Seed assembly (the reseed dedupe)

    /// Two packs that share a peak coordinate collapse to a single peak — the id
    /// is derived from the coordinate, so the union across packs is deduped.
    func testAssembleSeedDedupesPeaks() {
        let shared = OfflinePackData.Peak(name: "Shared", lat: 45.0, lon: 7.0, altitude: 3000)
        let packA = OfflinePackData(
            peaks: [shared, OfflinePackData.Peak(name: "OnlyA", lat: 45.1, lon: 7.1, altitude: 2500)]
        )
        let packB = OfflinePackData(
            peaks: [shared, OfflinePackData.Peak(name: "OnlyB", lat: 46.0, lon: 8.0, altitude: 4000)]
        )

        let seed = OfflinePackManager.assembleSeed(from: [packA, packB])

        XCTAssertEqual(seed.count, 3)                                        // shared appears once
        XCTAssertEqual(seed.filter { $0.name == "Shared" }.count, 1)
        XCTAssertTrue(seed.contains { $0.name == "OnlyA" })
        XCTAssertTrue(seed.contains { $0.name == "OnlyB" })
    }

    func testAssembleSeedEmptyIsEmpty() {
        XCTAssertTrue(OfflinePackManager.assembleSeed(from: []).isEmpty)
    }
}

// MARK: - Downloading a pack against a stubbed Overpass

/// `createPack` / `updatePack` with every Overpass request answered by
/// `OverpassStub` (no real network). A FAILED download is not an empty area:
/// the old wrapper collapsed a failure into `[]`, so a download with no peak
/// server reachable saved a 0-peak pack that read as "no peaks in this area".
final class OfflinePackDownloadTests: XCTestCase {

    /// Every pack these tests save carries this prefix, so `tearDown` can
    /// remove exactly those from the store and nothing else.
    private static let namePrefix = "GeoTests pack "
    private let center = CLLocationCoordinate2D(latitude: 45.9, longitude: 7.6)

    override func setUp() {
        super.setUp()
        Self.removeTestPacks()
        OverpassStub.install()
    }

    override func tearDown() {
        OverpassStub.uninstall()
        Self.removeTestPacks()
        super.tearDown()
    }

    private static func removeTestPacks() {
        let store = OfflinePackStore()
        let index = store.loadIndex()
        let ours = index.filter { $0.name.hasPrefix(namePrefix) }
        guard !ours.isEmpty else { return }
        ours.forEach { store.deleteData($0.id) }
        store.saveIndex(index.filter { !$0.name.hasPrefix(namePrefix) })
    }

    private func savedPack(named name: String) -> OfflinePack? {
        OfflinePackStore().loadIndex().first { $0.name == name }
    }

    @MainActor
    func testFailedDownloadSavesNoPackAndSaysWhy() async {
        let manager = OfflinePackManager()
        let name = Self.namePrefix + UUID().uuidString
        await manager.createPack(name: name, center: center, radiusKm: 5)

        XCTAssertNil(savedPack(named: name), "a failed download must not register a 0-peak pack")
        XCTAssertFalse(manager.packs.contains { $0.name == name })
        XCTAssertEqual(manager.downloadError,
                       "Couldn't download peaks — no peak server answered. Try again later.")
    }

    @MainActor
    func testConfirmedEmptyAreaIsSavedAndTheNextDownloadClearsTheError() async throws {
        let manager = OfflinePackManager()
        await manager.createPack(name: Self.namePrefix + "failed", center: center, radiusKm: 5)
        XCTAssertNotNil(manager.downloadError)

        let empty = OverpassStub.answer([])
        OverpassStub.reply { _, _ in .body(empty) }
        let name = Self.namePrefix + UUID().uuidString
        await manager.createPack(name: name, center: center, radiusKm: 5)

        let pack = try XCTUnwrap(savedPack(named: name), "a server that answered \"no peaks\" is a real answer")
        XCTAssertEqual(pack.peakCount, 0)
        XCTAssertTrue(manager.packs.contains { $0.id == pack.id })
        XCTAssertNil(manager.downloadError, "starting the next download clears the error")
    }

    @MainActor
    func testFailedUpdateKeepsThePackAndSaysWhy() async throws {
        let manager = OfflinePackManager()
        let answer = OverpassStub.answer([StubPeak(name: "Stub Alpha", lat: 45.92, lon: 7.60, ele: 3100),
                                          StubPeak(name: "Stub Beta", lat: 45.90, lon: 7.63, ele: 2900)])
        OverpassStub.reply { _, _ in .body(answer) }
        let name = Self.namePrefix + UUID().uuidString
        await manager.createPack(name: name, center: center, radiusKm: 5)
        let pack = try XCTUnwrap(manager.packs.first { $0.name == name })
        XCTAssertEqual(pack.peakCount, 2)

        OverpassStub.reply { _, _ in .failure(.notConnectedToInternet) }
        await manager.updatePack(pack)

        XCTAssertEqual(savedPack(named: name)?.peakCount, 2, "a failed update keeps the pack it was refreshing")
        XCTAssertEqual(OfflinePackStore().loadData(pack.id)?.peaks.count, 2)
        XCTAssertEqual(manager.downloadError,
                       "Couldn't update peaks — no peak server answered. Try again later.")
    }
}
