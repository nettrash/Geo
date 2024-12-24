//
//  GraphView.swift
//  Geo
//
//  Created by nettrash on 26/09/2024.
//

import SwiftUI

struct GraphView: View {
    
    @State var Caption: String
    @State var Data: [DataItem]
    
    var body: some View {
        ZStack {
            Text(Caption)
                .opacity(0.2)
                .font(.title)
                .rotationEffect(.degrees(-25))
                .padding()
            
            VStack {
                HStack {
                    Spacer()
                }
                Spacer()
                    .frame(height: 270)
            }
            .background(
                Color.gray.opacity(0.3)
            )
            .fontDesign(.monospaced)
            .cornerRadius(15)
            .padding()
            
            AxisShape(height: 240, shift: 30, isVertical: true)
                .strokeBorder(.white, lineWidth: 2, antialiased: true)

            AxisShape(height: 240, shift: 30, isVertical: false)
                .strokeBorder(.white, lineWidth: 2, antialiased: true)
            
            DataSetShape(height: 240, shiftX: 30, shiftY: 30, data: Data)
                .strokeBorder(.white, lineWidth: 2, antialiased: true)
        }
    }
}


#Preview {
    GraphView(Caption: "TEST PREVIEW", Data: [])
}
