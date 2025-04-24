//
//  DataItem.swift
//  Geo
//
//  Created by Ivan Alekseev on 24/04/2025.
//

final class DataItem: Sendable {
    
    let Value: Double
    let Legend: String
    
    init(Value: Double, Legend: String) {
        self.Value = Value
        self.Legend = Legend
    }
}
