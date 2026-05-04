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
        self.recordDate = try c.decode(Date.self, forKey: .recordDate)
        self.gpsAltitude = try c.decode(Double.self, forKey: .gpsAltitude)
        self.gpsSpeed = try c.decode(Double.self, forKey: .gpsSpeed)
        self.barPreassure = try c.decode(Double.self, forKey: .barPreassure)
        self.barAltitude = try c.decode(Double.self, forKey: .barAltitude)
        self.gpsLatitude = (try? c.decode(Double.self, forKey: .gpsLatitude)) ?? 0
        self.gpsLongitude = (try? c.decode(Double.self, forKey: .gpsLongitude)) ?? 0
    }

}
