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
    var min: CGFloat = 0
    var max: CGFloat = 10000
    var measurement: String = "km"
    
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
            
            VStack {
                HStack {
                    Spacer()
                        .frame(width: 26)
                    Text("\(Int(max)) \(measurement)")
                        .font(.system(size: 8))
                        .bold()
                    Spacer()
                }
                Spacer()
                    .frame(height: 250)
            }

            VStack {
                Spacer()
                    .frame(height: 245)
                HStack {
                    Spacer()
                        .frame(width: 26)
                    Text("\(Int(min))")
                        .font(.system(size: 8))
                        .bold()
                    Spacer()
                }
            }

            VStack {
                Spacer()
                    .frame(height: 0)
                HStack {
                    Spacer()
                        .frame(width: 18)
                    Text("\(Int((max - min)/2))")
                        .font(.system(size: 6))
                        .multilineTextAlignment(.leading)
                        .frame(width: 120)
                        .frame(width: 10)
                        .rotationEffect( .degrees(-90))
                    Spacer()
                }
            }

            VStack {
                HStack {
                    Spacer()
                        .frame(width: 18)
                    Text("\(Int(((max - min) * 3)/4))")
                        .font(.system(size: 6))
                        .multilineTextAlignment(.leading)
                        .frame(width: 120)
                        .frame(width: 10)
                        .rotationEffect( .degrees(-90))
                    Spacer()
                }
                Spacer()
                    .frame(height: 115)
            }

            VStack {
                Spacer()
                    .frame(height: 115)
                HStack {
                    Spacer()
                        .frame(width: 18)
                    Text("\(Int((max - min)/4))")
                        .font(.system(size: 6))
                        .multilineTextAlignment(.leading)
                        .frame(width: 120)
                        .frame(width: 10)
                        .rotationEffect( .degrees(-90))
                    Spacer()
                }
            }

            VStack {
                Spacer()
                    .frame(height: 250)
                HStack {
                    Spacer()
                    Text("now")
                        .font(.system(size: 8))
                        .bold()
                    Spacer()
                        .frame(width: 26)
                }
            }

            AxisShape(height: 230, shift: 30, position: .vertical)
                .strokeBorder(.white, lineWidth: 0.5, antialiased: true)

            AxisShape(height: 230, shift: 30, position: .horizontal)
                .strokeBorder(.white, lineWidth: 0.5, antialiased: true)

            AxisShape(height: 230, shift: 30, position: .median)
                .strokeBorder(.white, lineWidth: 0.25, antialiased: true)

            AxisShape(height: 230, shift: 30, position: .topMedian)
                .strokeBorder(.white, lineWidth: 0.25, antialiased: true)

            AxisShape(height: 230, shift: 30, position: .bottomMedian)
                .strokeBorder(.white, lineWidth: 0.25, antialiased: true)

            DataSetShape(height: 230, shiftX: 30, shiftY: 30, data: Data, min: min, max: max, markVertexes: true, vertexRadius: 3.0)
                .strokeBorder(.white, lineWidth: 1, antialiased: true)
        }
    }
}

#Preview {
    GraphView(Caption: "TEST PREVIEW", Data: [], min: 0, max: 1000, measurement: "kPa")
}
