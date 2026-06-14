//
//  NearbyPeakTests.swift
//  GeoTests
//
//  Verifies the stable-id behaviour that the AR overlay's merge logic
//  relies on: two `NearbyPeak`s built from the same coordinate must
//  share the same `id`, otherwise the dictionary-keyed merge in
//  `PeakFinder.searchPeaks` would happily insert duplicates.
//

import XCTest
import CoreLocation
@testable import Geo

final class NearbyPeakTests: XCTestCase {

    func testStableIDBetweenInstancesWithSameCoordinate() {
        let coord = CLLocationCoordinate2D(latitude: 47.6062, longitude: -122.3321)
        let a = NearbyPeak(name: "X", coordinate: coord,
                           altitude: 100, distance: 200, bearing: 12)
        let b = NearbyPeak(name: "Y (different name)", coordinate: coord,
                           altitude: 9999, distance: 50_000, bearing: 359)
        XCTAssertEqual(a.id, b.id)
    }

    func testDifferentCoordinatesYieldDifferentIDs() {
        let a = NearbyPeak(
            name: "A",
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            altitude: 0, distance: 0, bearing: 0
        )
        let b = NearbyPeak(
            name: "B",
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0.0001),
            altitude: 0, distance: 0, bearing: 0
        )
        XCTAssertNotEqual(a.id, b.id)
    }

    func testMergeByIDInDictionaryDeduplicates() throws {
        // Simulate the merge step in PeakFinder: two snapshots of the
        // same peak (different distances because the user moved) should
        // collapse into a single dictionary entry.
        let coord = CLLocationCoordinate2D(latitude: 1, longitude: 1)
        let oldEntry = NearbyPeak(name: "Peak", coordinate: coord,
                                  altitude: 1000, distance: 4000, bearing: 90)
        let freshEntry = NearbyPeak(name: "Peak", coordinate: coord,
                                    altitude: 1000, distance: 800, bearing: 92)
        var byID: [UUID: NearbyPeak] = [:]
        byID[oldEntry.id] = oldEntry
        byID[freshEntry.id] = freshEntry  // overwrites
        XCTAssertEqual(byID.count, 1)
        let merged = try XCTUnwrap(byID[oldEntry.id])
        XCTAssertEqual(merged.distance, 800, accuracy: 0.001)
    }
}
