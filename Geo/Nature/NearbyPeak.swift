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
    let id: UUID
    let name: String
    let coordinate: CLLocationCoordinate2D
    let altitude: Double // meters
    let distance: Double // meters from user
    let bearing: Double  // degrees from north (0-360)
    
    init(name: String, coordinate: CLLocationCoordinate2D,
         altitude: Double, distance: Double, bearing: Double) {
        // Stable UUID derived from the peak's coordinate so the same peak keeps
        // its identity across refreshes, preventing marker flash and occlusion resets.
        let latBits = coordinate.latitude.bitPattern
        let lonBits = coordinate.longitude.bitPattern
        self.id = UUID(uuid: (
            UInt8((latBits >> 56) & 0xFF), UInt8((latBits >> 48) & 0xFF),
            UInt8((latBits >> 40) & 0xFF), UInt8((latBits >> 32) & 0xFF),
            UInt8((latBits >> 24) & 0xFF), UInt8((latBits >> 16) & 0xFF),
            UInt8((latBits >>  8) & 0xFF), UInt8(latBits & 0xFF),
            UInt8((lonBits >> 56) & 0xFF), UInt8((lonBits >> 48) & 0xFF),
            UInt8((lonBits >> 40) & 0xFF), UInt8((lonBits >> 32) & 0xFF),
            UInt8((lonBits >> 24) & 0xFF), UInt8((lonBits >> 16) & 0xFF),
            UInt8((lonBits >>  8) & 0xFF), UInt8(lonBits & 0xFF)
        ))
        self.name = name
        self.coordinate = coordinate
        self.altitude = altitude
        self.distance = distance
        self.bearing = bearing
    }
    
    static func == (lhs: NearbyPeak, rhs: NearbyPeak) -> Bool {
        lhs.id == rhs.id
    }
}
