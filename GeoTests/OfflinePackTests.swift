//
//  OfflinePackTests.swift
//  GeoTests
//
//  Round-trip + seed-assembly tests for the offline expedition pack.
//
//  Packs are PEAKS ONLY. The DEM-grid half (a ~110 m core plus far-terrain
//  rings out to 200 km) existed to feed the terrain skyline; that skyline was
//  removed from the Nature tab, so the grid prefetch, the pinned-cell seeding
//  and their tests went with it. Peak altitudes are still DEM-resolved at
//  download time inside `PeakFinder.fetchOSMPeaks` (one bounded lookup per
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
