//
//  AxisShape.swift
//  Geo
//
//  Created by Ivan Alekseev on 24/04/2025.
//

import SwiftUI

enum AxisPosition {
    case horizontal
    case vertical
}

struct AxisShape: InsettableShape {

    var height: CGFloat = 0
    var shift: CGFloat = 0
    var position: AxisPosition = .horizontal

    func inset(by amount: CGFloat) -> Self {
        let line = self
        return line
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        switch position {
        case .horizontal:
            path.move(to: CGPoint(x: rect.minX + shift, y: rect.midY + height / 2))
            path.addLine(to: CGPoint(x: rect.maxX - shift, y: rect.midY + height / 2))
            path.move(to: CGPoint(x: rect.maxX - shift, y: rect.midY + height / 2))
            path.addLine(to: CGPoint(x: rect.maxX - shift - 6, y: rect.midY + height / 2 - 3))
            path.move(to: CGPoint(x: rect.maxX - shift, y: rect.midY + height / 2))
            path.addLine(to: CGPoint(x: rect.maxX - shift - 6, y: rect.midY + height / 2 + 3))
        case .vertical:
            path.move(to: CGPoint(x: rect.minX + shift, y: rect.midY - height / 2))
            path.addLine(to: CGPoint(x: rect.minX + shift, y: rect.midY + height / 2))
            path.move(to: CGPoint(x: rect.minX + shift, y: rect.midY - height / 2))
            path.addLine(to: CGPoint(x: rect.minX + shift + 3, y: rect.midY - height / 2 + 6))
            path.move(to: CGPoint(x: rect.minX + shift, y: rect.midY - height / 2))
            path.addLine(to: CGPoint(x: rect.minX + shift - 3, y: rect.midY - height / 2 + 6))
        }

        return path
    }
}
