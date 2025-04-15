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
    
}
