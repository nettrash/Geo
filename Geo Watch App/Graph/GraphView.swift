//
//  GraphView.swift
//  Geo
//
//  Created by Ivan Alekseev on 24/04/2025.
//

import SwiftUI

struct GraphView: View {
    
    @Binding var Data: [DataItem]
    @Binding var min: Double
    @Binding var max: Double
    var measurement: String = "km"

    var body: some View {
        ZStack {
            Group {
                VStack {
                    HStack {
                        Spacer()
                            .frame(width: 20)
                        Text(ordinateLabelMax())
                            .font(.system(size: 6))
                            .bold()
                        Spacer()
                    }
                    Spacer()
                        .frame(height: 90)
                }
                
                VStack {
                    Spacer()
                        .frame(height: 74)
                    HStack {
                        Spacer()
                            .frame(width: 6)
                        Text(ordinateLabelMin())
                            .font(.system(size: 6))
                            .bold()
                            .multilineTextAlignment(.leading)
                            .frame(width: 120)
                            .frame(width: 10)
                            .rotationEffect( .degrees(-90))
                        Spacer()
                    }
                }
                
                VStack {
                    Spacer()
                        .frame(height: 98)
                    HStack {
                        Spacer()
                            .frame(width: 14)
                        Text(ordinateLabelS())
                            .font(.system(size: 6))
                            .bold()
                            .multilineTextAlignment(.leading)
                        Spacer()
                    }
                }
                
                VStack {
                    Spacer()
                        .frame(height: 98)
                    HStack {
                        Spacer()
                        Text(ordinateLabelF())
                            .font(.system(size: 6))
                            .bold()
                            .multilineTextAlignment(.leading)
                        Spacer()
                            .frame(width: 20)
                    }
                }
            }

            Group {
                AxisShape(height: 90, shift: 15, position: .vertical)
                    .strokeBorder(.white, lineWidth: 0.5, antialiased: true)
                
                AxisShape(height: 90, shift: 15, position: .horizontal)
                    .strokeBorder(.white, lineWidth: 0.5, antialiased: true)
            }

            DataSetShape(height: 80, shiftX: 15, shiftY: 15, data: Data, min: min, max: max, markVertexes: true, vertexRadius: 1.5)
                .strokeBorder(.white, lineWidth: 1, antialiased: true)
        }
    }
    
    func ordinateLabelMin() -> String {
        return "\(Int(min)) \(measurement)"
    }
    
    func ordinateLabelMax() -> String {
        return "\(Int(max)) \(measurement)"
    }
    
    func ordinateLabelS() -> String {
        if Data.count == 0 {
            return ""
        }
        return Data[0].Legend
    }
    
    func ordinateLabelF() -> String {
        if Data.count == 0 {
            return ""
        }
        return Data[Data.count - 1].Legend
    }
}

#Preview {
    GraphView(Data: .constant([DataItem(Value: 100, Legend: "0"), DataItem(Value: 250, Legend: "1"), DataItem(Value: 500, Legend: "2"), DataItem(Value: 750, Legend: "3"), DataItem(Value: 100, Legend: "4"), DataItem(Value: 450, Legend: "5"), DataItem(Value: 150, Legend: "6"), DataItem(Value: 750, Legend: "7"), DataItem(Value: 200, Legend: "8"), DataItem(Value: 250, Legend: "9"), DataItem(Value: 500, Legend: "10")]), min: .constant(CGFloat.zero), max: .constant(CGFloat(1000.0)), measurement: "kPa")
}
