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
    var useGreenBorder: Bool = true
    var useYellowBorder: Bool = true
    var useRedBorder: Bool = true
    var greenValue: CGFloat = 2000
    var yellowValue: CGFloat = 2500
    var redValue: CGFloat = 7980
    var greenText: String = "green"
    var yellowText: String = "yellow"
    var redText: String = "red"

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
            
            if useGreenBorder {
                Group {
                    BorderShape(height: 230, shift: 30, min: min, max: max, position: greenValue)
                        .strokeBorder(.green, lineWidth: 1, antialiased: true)
                    
                    BorderText(message: greenText, shift: greenShift(), color: .green)
                }
            }

            if useYellowBorder {
                Group {
                    BorderShape(height: 230, shift: 30, min: min, max: max, position: yellowValue)
                        .strokeBorder(.yellow, lineWidth: 1, antialiased: true)
                    
                    BorderText(message: yellowText, shift: yellowShift(), color: .yellow)
                }
            }

            if useRedBorder {
                Group {
                    BorderShape(height: 230, shift: 30, min: min, max: max, position: redValue)
                        .strokeBorder(.red, lineWidth: 1, antialiased: true)
                    
                    BorderText(message: redText, shift: redShift(), color: .red)
                }
            }

            DataSetShape(height: 230, shiftX: 30, shiftY: 30, data: Data, min: min, max: max, markVertexes: true, vertexRadius: 3.0)
                .strokeBorder(.white, lineWidth: 1, antialiased: true)
        }
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


    func yellowShift() -> CGFloat {
        return (-8 + (230 / 2) - (230 / (max - min)) * (yellowValue - min))
    }
    
    func redShift() -> CGFloat {
        return (-8 + (230 / 2) - (230 / (max - min)) * (redValue - min))
    }
    
    func greenShift() -> CGFloat {
        return (-8 + (230 / 2) - (230 / (max - min)) * (greenValue - min))
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
    GraphView(Caption: "TEST PREVIEW", Data: [], min: 0, max: 1000, measurement: "kPa", useGreenBorder: true, useYellowBorder: true, useRedBorder: true, greenValue: 762, yellowValue: 100, redValue: 400)
}
