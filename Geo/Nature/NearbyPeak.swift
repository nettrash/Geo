//
//  NearbyPeak.swift
//  Geo
//
//  Created by nettrash on 24/03/2026.
//

import Foundation
import CoreLocation

/// Represents a peak/mountain point of interest to display in AR
struct NearbyPeak: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let coordinate: CLLocationCoordinate2D
    let altitude: Double // meters
    let distance: Double // meters from user
    let bearing: Double  // degrees from north (0-360)
    
    static func == (lhs: NearbyPeak, rhs: NearbyPeak) -> Bool {
        lhs.id == rhs.id
    }
}
