//
//  BorderShape.swift
//  Geo
//
//  Created by Ivan Alekseev on 24/04/2025.
//

import SwiftUI

struct BorderShape: InsettableShape {

    var height: CGFloat = 0
    var shift: CGFloat = 0
    var min: CGFloat = 0
    var max: CGFloat = 100
    var position: CGFloat = 37

    func inset(by amount: CGFloat) -> Self {
        let line = self
        return line
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        
        let stepSizeY = height / (max - min)
        
        path.move(to: CGPoint(x: rect.minX + (4 * shift / 5), y: rect.midY + (height / 2) - stepSizeY * (position - min)))
        path.addLine(to: CGPoint(x: rect.maxX - shift, y: rect.midY + (height / 2) - stepSizeY * (position - min)))

        return path
    }
}
