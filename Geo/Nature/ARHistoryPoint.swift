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
    let id = UUID()
    let date: Date
    let coordinate: CLLocationCoordinate2D
    let gpsAltitude: Double
    let barometerAltitude: Double
    let pressure: Double
    let speed: Double
    let distance: Double  // meters from user
    let bearing: Double   // degrees from north (0-360)
    
    static func == (lhs: ARHistoryPoint, rhs: ARHistoryPoint) -> Bool {
        lhs.id == rhs.id
    }
}
