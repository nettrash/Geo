//
//  AxisView.swift
//  Geo
//
//  Created by nettrash on 26/09/2024.
//

import SwiftUI

struct AxisShape: InsettableShape {

    var height: CGFloat = 0
    var shift: CGFloat = 0
    var isVertical: Bool = true

    func inset(by amount: CGFloat) -> Self {
        let line = self
        return line
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        if (isVertical) {
            path.move(to: CGPoint(x: rect.minX + shift, y: rect.midY - height / 2))
            path.addLine(to: CGPoint(x: rect.minX + shift, y: rect.midY + height / 2))
            path.move(to: CGPoint(x: rect.minX + shift, y: rect.midY - height / 2))
            path.addLine(to: CGPoint(x: rect.minX + shift + 5, y: rect.midY - height / 2 + 10))
            path.move(to: CGPoint(x: rect.minX + shift, y: rect.midY - height / 2))
            path.addLine(to: CGPoint(x: rect.minX + shift - 5, y: rect.midY - height / 2 + 10))
        } else {
            path.move(to: CGPoint(x: rect.minX + shift, y: rect.midY + height / 2))
            path.addLine(to: CGPoint(x: rect.maxX - shift, y: rect.midY + height / 2))
            path.move(to: CGPoint(x: rect.maxX - shift, y: rect.midY + height / 2))
            path.addLine(to: CGPoint(x: rect.maxX - shift - 10, y: rect.midY + height / 2 - 5))
            path.move(to: CGPoint(x: rect.maxX - shift, y: rect.midY + height / 2))
            path.addLine(to: CGPoint(x: rect.maxX - shift - 10, y: rect.midY + height / 2 + 5))
        }

        return path
    }
}
