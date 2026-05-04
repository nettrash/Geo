//
//  InformationTokenTests.swift
//  GeoTests
//
//  Verifies that the on-disk format of `InformationToken` stays
//  backward-compatible: snapshots written by an older build (without
//  latitude/longitude) must still decode under the current schema.
//

import XCTest
@testable import Geo

final class InformationTokenTests: XCTestCase {

    func testDecodesLegacyJSONWithoutCoordinates() throws {
        // Snapshot in the format the iPhone widget wrote before we
        // introduced gpsLatitude / gpsLongitude. The decoder must
        // accept it and default the missing fields to zero.
        let legacy = """
        {
            "recordDate": 700000000,
            "gpsAltitude": 1234.5,
            "gpsSpeed": 0.5,
            "barPreassure": 89.7,
            "barAltitude": 1100.0
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(InformationToken.self, from: legacy)
        XCTAssertEqual(decoded.gpsAltitude, 1234.5)
        XCTAssertEqual(decoded.barAltitude, 1100.0)
        XCTAssertEqual(decoded.gpsLatitude, 0)
        XCTAssertEqual(decoded.gpsLongitude, 0)
    }

    func testRoundTrips() throws {
        let token = InformationToken(
            recordDate: Date(timeIntervalSince1970: 700_123_456),
            gpsAltitude: 200,
            gpsSpeed: 1.2,
            barPreassure: 99.5,
            barAltitude: 250,
            gpsLatitude: 47.6,
            gpsLongitude: -122.3
        )
        let data = try JSONEncoder().encode(token)
        let back = try JSONDecoder().decode(InformationToken.self, from: data)
        XCTAssertEqual(back.gpsAltitude, token.gpsAltitude, accuracy: 0.0001)
        XCTAssertEqual(back.gpsLatitude, token.gpsLatitude, accuracy: 0.0001)
        XCTAssertEqual(back.gpsLongitude, token.gpsLongitude, accuracy: 0.0001)
    }
}
