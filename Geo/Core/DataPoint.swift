//
//  DataPoint.swift
//  Geo
//
//  Created by Ivan Alekseev on 22/04/2025.
//

import Foundation

final class DataPoint: Sendable {
    
    let Value: [CGFloat]
    let Legend: String
    
    init(Value: [CGFloat], Legend: String) {
        self.Value = Value
        self.Legend = Legend
    }
}
