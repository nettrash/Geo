//
//  PairDataItem.swift
//  Geo
//
//  Created by Ivan Alekseev on 21/04/2025.
//
import Foundation

final class PairDataItem: Sendable {
    
    let Value0: CGFloat
    let Value1: CGFloat
    let Legend: String
    
    init(Value0: CGFloat, Value1: CGFloat, Legend: String) {
        self.Value0 = Value0
        self.Value1 = Value1
        self.Legend = Legend
    }
}
