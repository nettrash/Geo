//
//  BorderText.swift
//  Geo
//
//  Created by Ivan Alekseev on 24/04/2025.
//

import SwiftUI

struct BorderText: View {
    @State var message: String = "text"
    @State var shift: CGFloat = 5
    @State var color: Color = .red
    
    var body: some View {
        HStack {
            Spacer()
            Text(message)
                .font(.system(size: 8))
                .foregroundStyle(color)
                .offset(y: shift)
            Spacer()
                .frame(width: 26)
        }
    }
}
