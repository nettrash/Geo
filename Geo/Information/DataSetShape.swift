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
    var min: CGFloat = 0
    var max: CGFloat = 10000
    var markVertexes: Bool = false
    var vertexRadius: CGFloat = 2.5

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
        let stepSizeX = (rect.maxX - 2 * shiftX) / CGFloat(data.count)
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
            }
            if markVertexes {
                path.addEllipse(in: CGRect(x: currentPoint.x-vertexRadius, y: currentPoint.y-vertexRadius, width: 2*vertexRadius, height: 2*vertexRadius))
                path.addEllipse(in: CGRect(x: currentPoint.x-vertexRadius/2, y: currentPoint.y-vertexRadius/2, width: vertexRadius, height: vertexRadius))
                path.addEllipse(in: CGRect(x: currentPoint.x-vertexRadius/4, y: currentPoint.y-vertexRadius/4, width: vertexRadius/2, height: vertexRadius/2))
                path.move(to: currentPoint)
            }
            stepN+=1
        }

        return path
    }
    
    func borders() -> (min: Double, max: Double) {
        var minimum = self.min;
        var maximum = self.max;
        for dataItem in data {
            if dataItem.Value > maximum {
                maximum = dataItem.Value
            }
            if dataItem.Value < minimum {
                minimum = dataItem.Value
            }
        }
        return (min: minimum, max: maximum)
    }
}
