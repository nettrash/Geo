//
//  DataItem.swift
//  Geo
//
//  Created by nettrash on 01/11/2024.
//
import Foundation

final class DataItem: Sendable {
    
    let Value: CGFloat
    let Legend: String
    
    init(Value: CGFloat, Legend: String) {
        self.Value = Value
        self.Legend = Legend
    }
}
