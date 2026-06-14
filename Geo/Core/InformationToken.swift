//
//  InformationToken.swift
//  Geo
//
//  Created by Ivan Alekseev on 23/01/2025.
//

import Foundation

struct InformationToken: Codable {

    var recordDate: Date

    var gpsAltitude: Double
    var gpsSpeed: Double
    var barPreassure: Double
    var barAltitude: Double

    // Last known GPS position. Persisted alongside the rest of the snapshot so
    // that background widget / watch refreshes can preserve position information
    // and the main app can backfill complete history items from data that was
    // captured while it wasn't running.
    var gpsLatitude: Double = 0
    var gpsLongitude: Double = 0

    init(recordDate: Date,
         gpsAltitude: Double,
         gpsSpeed: Double,
         barPreassure: Double,
         barAltitude: Double,
         gpsLatitude: Double = 0,
         gpsLongitude: Double = 0) {
        self.recordDate = recordDate
        self.gpsAltitude = gpsAltitude
        self.gpsSpeed = gpsSpeed
        self.barPreassure = barPreassure
        self.barAltitude = barAltitude
        self.gpsLatitude = gpsLatitude
        self.gpsLongitude = gpsLongitude
    }

    // MARK: - Codable (custom to keep backward compatibility with older
    // persisted tokens that did not include latitude/longitude fields).

    private enum CodingKeys: String, CodingKey {
        case recordDate
        case gpsAltitude
        case gpsSpeed
        case barPreassure
        case barAltitude
        case gpsLatitude
        case gpsLongitude
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `recordDate` is exchanged on the wire as Int64 epoch-milliseconds so
        // the JSON stays byte-compatible with the Android / Wear OS apps, which
        // serialize it as a `Long`. We try that form first. Older iOS snapshots
        // (written before this change) encoded a Swift `Date` with the default
        // strategy, i.e. a `Double` of seconds-since-2001 (reference date), so
        // fall back to that to keep existing persisted tokens loadable.
        //
        // The two encodings occupy disjoint magnitude ranges, which lets us
        // disambiguate an integer-valued legacy timestamp (e.g. 700000000 ≈
        // a 2023 date as seconds-since-2001) from real epoch-millis (≈1.7e12):
        // any value at/below this threshold is treated as the legacy form.
        let legacyMillisThreshold: Int64 = 100_000_000_000 // ~1973 in millis; far above any seconds-since-2001 value
        if let millis = try? c.decode(Int64.self, forKey: .recordDate), millis > legacyMillisThreshold {
            self.recordDate = Date(timeIntervalSince1970: Double(millis) / 1000.0)
        } else {
            let legacy = try c.decode(Double.self, forKey: .recordDate)
            self.recordDate = Date(timeIntervalSinceReferenceDate: legacy)
        }
        self.gpsAltitude = try c.decode(Double.self, forKey: .gpsAltitude)
        self.gpsSpeed = try c.decode(Double.self, forKey: .gpsSpeed)
        self.barPreassure = try c.decode(Double.self, forKey: .barPreassure)
        self.barAltitude = try c.decode(Double.self, forKey: .barAltitude)
        self.gpsLatitude = (try? c.decode(Double.self, forKey: .gpsLatitude)) ?? 0
        self.gpsLongitude = (try? c.decode(Double.self, forKey: .gpsLongitude)) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Encode `recordDate` as Int64 epoch-milliseconds to match the Android /
        // Wear OS wire format (a `Long`), keeping the JSON byte-compatible.
        let millis = Int64((recordDate.timeIntervalSince1970 * 1000.0).rounded())
        try c.encode(millis, forKey: .recordDate)
        try c.encode(gpsAltitude, forKey: .gpsAltitude)
        try c.encode(gpsSpeed, forKey: .gpsSpeed)
        try c.encode(barPreassure, forKey: .barPreassure)
        try c.encode(barAltitude, forKey: .barAltitude)
        try c.encode(gpsLatitude, forKey: .gpsLatitude)
        try c.encode(gpsLongitude, forKey: .gpsLongitude)
    }

}
