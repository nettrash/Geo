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

        // Skip missing samples (NaN sentinel): leave a gap and force the next
        // finite sample to start a fresh subpath rather than drawing a line
        // straight across the hole. This is what lets a series with no data
        // (e.g. GPS altitude when there's no fix) break cleanly while the
        // other series keeps its line. The x position is keyed off the slot
        // index, so both series in a paired graph stay column-aligned across
        // gaps. `borders()` already ignores NaN (comparisons against it are
        // false), so the scale is unaffected.
        var needMove = true
        for (stepN, dataItem) in data.enumerated() {
            guard dataItem.Value.isFinite else {
                needMove = true
                continue
            }
            let point = CGPoint(x: rect.minX + shiftX + stepSizeX * CGFloat(stepN),
                                y: rect.midY + (height / 2) - stepSizeY * (dataItem.Value - borders.min))
            if needMove {
                path.move(to: point)
                needMove = false
            } else {
                path.addLine(to: point)
            }
            if markVertexes {
                path.addEllipse(in: CGRect(x: point.x-vertexRadius, y: point.y-vertexRadius, width: 2*vertexRadius, height: 2*vertexRadius))
                path.addEllipse(in: CGRect(x: point.x-vertexRadius/2, y: point.y-vertexRadius/2, width: vertexRadius, height: vertexRadius))
                path.addEllipse(in: CGRect(x: point.x-vertexRadius/4, y: point.y-vertexRadius/4, width: vertexRadius/2, height: vertexRadius/2))
                path.move(to: point)
            }
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
