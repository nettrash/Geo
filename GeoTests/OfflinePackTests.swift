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
            cells: ["46.852,-121.76": 4392, "46.853,-121.759": 4100]
        )
        let encoded = try JSONEncoder().encode(data)
        let decoded = try JSONDecoder().decode(OfflinePackData.self, from: encoded)

        XCTAssertEqual(decoded.peaks.count, 1)
        XCTAssertEqual(decoded.peaks.first?.name, "Rainier")
        XCTAssertEqual(decoded.cells["46.852,-121.76"], 4392)
        XCTAssertEqual(decoded.cells.count, 2)
    }

    func testIndexRoundTripsWithISO8601Date() throws {
        let meta = OfflinePack(id: UUID(), name: "Rainier area",
                               centerLat: 46.85, centerLon: -121.76, radiusKm: 25,
                               createdAt: Date(timeIntervalSince1970: 700_000_000),
                               peakCount: 3, cellCount: 3600)
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
            cells: ["45.0,7.0": 3000, "45.1,7.1": 2500]
        )
        let packB = OfflinePackData(
            peaks: [shared, OfflinePackData.Peak(name: "OnlyB", lat: 46.0, lon: 8.0, altitude: 4000)],
            cells: ["46.0,8.0": 4000, "45.0,7.0": 3100]   // collides with packA
        )

        let seed = OfflinePackManager.assembleSeed(from: [packA, packB])

        // Peaks: the shared coordinate appears once → 3 unique peaks.
        XCTAssertEqual(seed.peaks.count, 3)
        XCTAssertEqual(seed.peaks.filter { $0.name == "Shared" }.count, 1)

        // Cells: 3 distinct keys; the colliding key takes the later pack's value.
        XCTAssertEqual(seed.cells.count, 3)
        XCTAssertEqual(seed.cells["45.0,7.0"], 3100)
        XCTAssertEqual(seed.cells["46.0,8.0"], 4000)
    }

    func testAssembleSeedEmptyIsEmpty() {
        let seed = OfflinePackManager.assembleSeed(from: [])
        XCTAssertTrue(seed.peaks.isEmpty)
        XCTAssertTrue(seed.cells.isEmpty)
    }
}
