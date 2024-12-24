//
//  DataSetShape.swift
//  Geo
//
//  Created by nettrash on 01/11/2024.
//

import SwiftUI

struct DataSetShape: InsettableShape {

    var height: CGFloat = 0
    var shiftX: CGFloat = 0
    var shiftY: CGFloat = 0
    var data: [DataItem] = []

    func inset(by amount: CGFloat) -> Self {
        let line = self
        return line
    }

    func path(in rect: CGRect) -> Path {
        if data.count < 1 {
            return Path()
        }
        let borders = borders()
        
        var path = Path()

        let stepSizeY = height / (borders.max - borders.min)
        let stepSizeX = height / CGFloat(data.count)
        var stepN = 0
        
        var prevPoint: CGPoint = CGPoint()
        var currentPoint: CGPoint = CGPoint()
        
        for dataItem in data {
            if stepN == 0 {
                prevPoint = CGPoint(x: rect.minX + shiftX + stepSizeX * CGFloat(stepN), y: rect.midY + (height / 2) - stepSizeY * (dataItem.Value - borders.min))
                currentPoint = prevPoint
                path.move(to: currentPoint)
            } else {
                prevPoint = currentPoint
                currentPoint = CGPoint(x: rect.minX + shiftX + stepSizeX * CGFloat(stepN), y: rect.midY + (height / 2) - stepSizeY * (dataItem.Value - borders.min))
                path.addLine(to: currentPoint)
                path.addEllipse(in: CGRect(x: currentPoint.x, y: currentPoint.y, width: 2.0, height: 2.0))
            }
            stepN+=1
        }

        return path
    }
    
    func borders() -> (min: Double, max: Double) {
        var min = data[0].Value;
        var max = data[0].Value;
        for dataItem in data {
            if dataItem.Value > max {
                max = dataItem.Value
            }
            if dataItem.Value < min {
                min = dataItem.Value
            }
        }
        return (min: min, max: max)
    }
}
