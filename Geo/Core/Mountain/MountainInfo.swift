//
//  MountainInfo.swift
//  Geo
//
//  Created by Ivan Alekseev on 02/01/2025.
//

import Foundation

class MountainInfo: Codable, Identifiable {
    
    var id: String { "\(name ?? "")-\(position ?? 0)" }
    
    var position: Int? = nil
    var image: String? = nil
    var partOfTheWorld: String? = nil
    var name: String? = nil
    var height: Int? = nil
    var location: String? = nil
    var country: String? = nil
    var coordinates: MountainCoordinates? = nil
    var relativeHeight: Int? = nil
    var parent: String? = nil
    var firstAscent: String? = nil
    var ascents: Int? = nil
    var attemptsToAscend: Int? = nil

}
