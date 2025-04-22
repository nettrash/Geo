//
//  GraphPointsView.swift
//  Geo
//
//  Created by Ivan Alekseev on 22/04/2025.
//


import SwiftUI

struct GraphPointsView: View {
    
    @State var Caption: String
    @Binding var Data: [DataPoint]
    @State var Lines: [GraphLine] = []
    @Binding var min: CGFloat
    @Binding var max: CGFloat
    @State var Colors: [Color] = []
    @State var Legend: [String] = []
    @State var measurement: String = "km"

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
            
            Group {
                VStack {
                    HStack {
                        Spacer()
                            .frame(width: 26)
                        Text(ordinateLabel4())
                            .font(.system(size: 8))
                            .bold()
                        Spacer()
                    }
                    Spacer()
                        .frame(height: 250)
                }
                
                VStack {
                    Spacer()
                        .frame(height: 215)
                    HStack {
                        Spacer()
                            .frame(width: 18)
                        Text(ordinateLabel0())
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
                        .frame(height: 250)
                    HStack {
                        Spacer()
                            .frame(width: 30)
                        Text(ordinateLabelS())
                            .font(.system(size: 6))
                            .bold()
                            .multilineTextAlignment(.leading)
                        Spacer()
                    }
                }
                
                VStack {
                    Spacer()
                        .frame(height: 0)
                    HStack {
                        Spacer()
                            .frame(width: 18)
                        Text(ordinateLabel1())
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
                        Text(ordinateLabel2())
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
                        Text(ordinateLabel3())
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
                        Text(ordinateLabelF())
                            .font(.system(size: 6))
                            .bold()
                            .multilineTextAlignment(.leading)
                        Spacer()
                            .frame(width: 26)
                    }
                }

                VStack {
                    Spacer()
                        .frame(height: 4)
                    HStack {
                        Spacer()
                        LegendView(Legend: self.Legend, Colors: self.Colors)
                            .frame(width: 50)
                        Spacer()
                            .frame(width: 26)
                    }
                    Spacer()
                        .frame(height: 250)
                }
            }

            Group {
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
            }
            
            ForEach(Lines) { line in
                if (line.value > min && line.value < max) {
                    Group {
                        BorderShape(height: 230, shift: 30, min: min, max: max, position: line.value)
                            .strokeBorder(line.color, lineWidth: 1, antialiased: true)
                        
                        BorderText(message: line.text, shift: lineShift(line: line), color: line.color)
                    }
                }
            }

            if Data.count > 0 {
                ForEach(0..<Data[0].Value.count, id: \.self) { idx in
                    DataSetShape(height: 230, shiftX: 30, shiftY: 30, data: Data.map({ pair in
                        DataItem(Value: pair.Value[idx], Legend: pair.Legend)
                    }), min: min, max: max, markVertexes: true, vertexRadius: 1.5)
                    .strokeBorder(getColor(idx), lineWidth: 1, antialiased: true)
                }
            }
        }
    }
    
    func getColor(_ index: Int) -> Color {
        if index >= 0 && index < self.Colors.count {
            self.Colors[index]
        } else {
            .white
        }
    }
    
    func getColor(_ legend: String) -> Color {
        getColor(self.Legend.firstIndex(of: legend) ?? -1)
    }
    
    func ordinateLabel0() -> String {
        return "\(Int(min)) \(measurement)"
    }

    func ordinateLabel1() -> String {
        return "\(Int(min + (max - min)/2))"
    }
    
    func ordinateLabel2() -> String {
        return "\(Int(min + ((max - min) * 3)/4))"
    }
    
    func ordinateLabel3() -> String {
        return "\(Int(min + (max - min)/4))"
    }

    func ordinateLabel4() -> String {
        return "\(Int(max)) \(measurement)"
    }

    func lineShift(line: GraphLine) -> CGFloat {
        return (-8 + (230 / 2) - (230 / (max - min)) * (line.value - min))
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
    GraphPointsView(Caption: "TEST PAIR PREVIEW", Data: .constant([]), Lines: [GraphLine(value: 762, text: "normal", color: Color.green), GraphLine(value: 100, text: "yellow", color: Color.yellow), GraphLine(value: 400, text: "red", color: Color.red)], min: .constant(CGFloat.zero), max: .constant(CGFloat(1000.0)), measurement: "kPa")
}
