//
//  BarometerInformationView.swift
//  Geo
//
//  Created by nettrash on 18/06/2024.
//

import SwiftUI

struct BarometerInformationView: View {
    @State var barometer: Barometer?;
    
    var body: some View {
        ZStack {            
            Text("B A R O M E T E R")
                .opacity(0.2)
                .font(.title)
                .rotationEffect(.degrees(-25))
                .padding()

            VStack {
                
                HStack(alignment: .top) {
                    Text("Pressure")
                        .font(.subheadline)
                        .padding()
                    Spacer()
                    VStack {
                        Text(verbatim: "\(String(format: "%.4f", barometer?.pressure ?? 0.0)) kPa")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(verbatim: "\(String(format: "%.4f", (barometer?.pressure ?? 0.0) * 7.50062)) mm Hg")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(verbatim: "\(String(format: "%.4f", (barometer?.pressure ?? 0.0) / 101.325)) atm")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding()
                }
                
                HStack(alignment: .top) {
                    Text("Altitude")
                        .font(.subheadline)
                        .padding()
                    Spacer()
                    VStack {
                        Text(verbatim: "\(String(format: "%.0f", barometer?.height ?? 0.0)) m")
                    }
                    .padding()
                }
                
                HStack(alignment: .top) {
                    Text("% Everest")
                        .font(.subheadline)
                        .padding()
                    Spacer()
                    VStack {
                        Text(verbatim: "\(String(format: "%.4f", (barometer?.everest ?? 0.0) * 100.0)) %")
                    }
                    .padding()
                }
                
                Spacer()
                    .frame(height: 5)
            }
            .background(
                Color.gray.opacity(0.3)
            )
            .fontDesign(.monospaced)
            .cornerRadius(15)
            .padding()
        }
    }
}

#Preview {
    BarometerInformationView(barometer: nil)
}
