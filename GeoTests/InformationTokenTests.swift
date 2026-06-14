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

/// Pins the on-wire JSON encoding of `InformationToken.recordDate` so it stays
/// byte-compatible with the Android / Wear OS apps, which serialize the field
/// as a `Long` epoch-milliseconds value (A21). iOS used to rely on the default
/// `Date` strategy (a `Double` of seconds-since-2001), which did NOT match.
final class InformationTokenWireFormatTests: XCTestCase {

    // MARK: - Golden round-trip: recordDate serialises to integer epoch-millis.

    func testRecordDateEncodesAsIntegerEpochMillis() throws {
        // 1_700_000_000 s since 1970-01-01 UTC == 2023-11-14T22:13:20Z.
        // The byte-compatible wire form is the Long 1700000000000 (millis).
        let token = InformationToken(
            recordDate: Date(timeIntervalSince1970: 1_700_000_000),
            gpsAltitude: 200,
            gpsSpeed: 1.2,
            barPreassure: 99.5,
            barAltitude: 250,
            gpsLatitude: 47.6,
            gpsLongitude: -122.3
        )

        let data = try JSONEncoder().encode(token)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        // recordDate must be the integer millis value, not a Double.
        let recordDate = try XCTUnwrap(json["recordDate"] as? NSNumber)
        XCTAssertEqual(recordDate.int64Value, 1_700_000_000_000)

        // Guard against a fractional / seconds-since-2001 encoding sneaking
        // back: the raw JSON text must contain the bare integer.
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"recordDate\":1700000000000"),
                      "recordDate must serialise as an integer epoch-millis value; got: \(text)")

        // The intentionally-misspelled key must survive untouched.
        XCTAssertNotNil(json["barPreassure"])
        XCTAssertNil(json["barPressure"])
    }

    // MARK: - Backward compatibility: a legacy seconds-since-2001 payload decodes.

    func testDecodesLegacySecondsSinceReferenceDatePayload() throws {
        // Snapshot written by an older iOS build that encoded `recordDate`
        // with the default `Date` strategy: a Double of seconds-since-2001.
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
        XCTAssertEqual(decoded.recordDate,
                       Date(timeIntervalSinceReferenceDate: 700_000_000))
    }

    func testDecodesNewIntegerMillisPayload() throws {
        // A payload produced by Android / Wear (or by the new iOS encoder).
        let android = """
        {
            "recordDate": 1700000000000,
            "gpsAltitude": 10.0,
            "gpsSpeed": 0.0,
            "barPreassure": 101.3,
            "barAltitude": 12.0,
            "gpsLatitude": 1.0,
            "gpsLongitude": 2.0
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(InformationToken.self, from: android)
        XCTAssertEqual(decoded.recordDate.timeIntervalSince1970,
                       1_700_000_000,
                       accuracy: 0.001)
        XCTAssertEqual(decoded.gpsLatitude, 1.0)
        XCTAssertEqual(decoded.gpsLongitude, 2.0)
    }
}
