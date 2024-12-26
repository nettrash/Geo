//
//  AxisView.swift
//  Geo
//
//  Created by nettrash on 26/09/2024.
//

import SwiftUI

enum AxisPosition {
    case horizontal
    case vertical
    case median
    case topMedian
    case bottomMedian
}

struct AxisShape: InsettableShape {

    var height: CGFloat = 0
    var shift: CGFloat = 0
    var position: AxisPosition = .median

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
            path.addLine(to: CGPoint(x: rect.maxX - shift - 10, y: rect.midY + height / 2 - 5))
            path.move(to: CGPoint(x: rect.maxX - shift, y: rect.midY + height / 2))
            path.addLine(to: CGPoint(x: rect.maxX - shift - 10, y: rect.midY + height / 2 + 5))
        case .vertical:
            path.move(to: CGPoint(x: rect.minX + shift, y: rect.midY - height / 2))
            path.addLine(to: CGPoint(x: rect.minX + shift, y: rect.midY + height / 2))
            path.move(to: CGPoint(x: rect.minX + shift, y: rect.midY - height / 2))
            path.addLine(to: CGPoint(x: rect.minX + shift + 5, y: rect.midY - height / 2 + 10))
            path.move(to: CGPoint(x: rect.minX + shift, y: rect.midY - height / 2))
            path.addLine(to: CGPoint(x: rect.minX + shift - 5, y: rect.midY - height / 2 + 10))
        case .median:
            path.move(to: CGPoint(x: rect.minX + (4 * shift / 5), y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX - shift, y: rect.midY))
        case .topMedian:
            path.move(to: CGPoint(x: rect.minX + (4 * shift / 5), y: rect.midY - height / 4))
            path.addLine(to: CGPoint(x: rect.maxX - shift, y: rect.midY - height / 4))
        case .bottomMedian:
            path.move(to: CGPoint(x: rect.minX + (4 * shift / 5), y: rect.midY +  height / 4))
            path.addLine(to: CGPoint(x: rect.maxX - shift, y: rect.midY +  height / 4))
        }

        return path
    }
}
