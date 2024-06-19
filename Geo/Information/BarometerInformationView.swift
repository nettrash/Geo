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
        VStack {
            ZStack {
                Color.gray
                    .opacity(0.5)
                    .frame(height: 60)
                
                VStack {
                    Spacer()
                        .frame(height: 2)
                    
                    HStack {
                        Text("Barometer")
                            .font(.headline)
                        Spacer()
                    }
                    .padding()
                }
            }
            
            HStack(alignment: .top) {
                Text("Atmospheric pressure")
                    .font(.subheadline)
                    .padding()
                Spacer()
                VStack {
                    Text("\(String(format: "%.4f", barometer?.pressure ?? 0)) kPa")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text("\(String(format: "%.4f", (barometer?.pressure ?? 0) * 7.50062)) mm Hg")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text("\(String(format: "%.4f", (barometer?.pressure ?? 0) / 101.325)) atm")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                    .padding()
            }
            
            HStack(alignment: .top) {
                Text("Calculated altitude")
                    .font(.subheadline)
                    .padding()
                Spacer()
                VStack {
                    Text("\(String(format: "%.0f", barometer?.height ?? 0)) m")
                }
                .padding()
            }
            
            HStack(alignment: .top) {
                Text("% Everest")
                    .font(.subheadline)
                    .padding()
                Spacer()
                VStack {
                    Text("\(String(format: "%.4f", (barometer?.everest ?? 0) * 100.0)) %")
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

#Preview {
    BarometerInformationView(barometer: nil)
}
