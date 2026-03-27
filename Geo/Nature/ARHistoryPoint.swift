//
//  ARHistoryPoint.swift
//  Geo
//
//  Created by nettrash on 24/03/2026.
//

import Foundation
import CoreLocation

/// Represents a history point to display in the AR camera view
struct ARHistoryPoint: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let coordinate: CLLocationCoordinate2D
    let gpsAltitude: Double
    let barometerAltitude: Double
    let pressure: Double
    let speed: Double
    let distance: Double  // meters from user
    let bearing: Double   // degrees from north (0-360)
    
    init(date: Date, coordinate: CLLocationCoordinate2D,
         gpsAltitude: Double, barometerAltitude: Double, pressure: Double,
         speed: Double, distance: Double, bearing: Double) {
        // Derive a stable UUID from the record date so the same history item
        // always maps to the same ID across refreshes, preventing SwiftUI from
        // destroying and recreating marker views on every 5-second reload.
        let micros = UInt64(bitPattern: Int64(date.timeIntervalSince1970 * 1_000_000))
        self.id = UUID(uuid: (
            UInt8((micros >> 56) & 0xFF), UInt8((micros >> 48) & 0xFF),
            UInt8((micros >> 40) & 0xFF), UInt8((micros >> 32) & 0xFF),
            UInt8((micros >> 24) & 0xFF), UInt8((micros >> 16) & 0xFF),
            UInt8((micros >>  8) & 0xFF), UInt8(micros & 0xFF),
            0, 0, 0, 0, 0, 0, 0, 0
        ))
        self.date = date
        self.coordinate = coordinate
        self.gpsAltitude = gpsAltitude
        self.barometerAltitude = barometerAltitude
        self.pressure = pressure
        self.speed = speed
        self.distance = distance
        self.bearing = bearing
    }
    
    static func == (lhs: ARHistoryPoint, rhs: ARHistoryPoint) -> Bool {
        lhs.id == rhs.id
    }
}
