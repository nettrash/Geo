//
//  ContentView.swift
//  Geo Watch App
//
//  Created by Ivan Alekseev on 24/01/2025.
//

import SwiftUI
import Foundation
import CoreMotion

struct ContentView: View {
    let barometer = CMAltimeter()
    @State var barometerInformationPressure: Double = 0
    @State var barometerInformationDelta: Double = 0
    @State var barometerInformationHeight: Double = 0
    @State var barometerInformationEverest: Double = 0

    var body: some View {
        
        VStack {
            ZStack {
                Image("Background.png")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(0.3)
                
                VStack {
                    HStack {
                        Text("Barometer")
                            .multilineTextAlignment(.leading)
                            .frame(width: 120)
                            .frame(width: 10)
                            .font(.system(size: 12))
                            .rotationEffect(.degrees(-90))
                        
                        Spacer()
                        
                        VStack(alignment: .trailing) {
                            Text("\(String(format: "%.4f", self.barometerInformationPressure)) kPa")
                                .font(.system(size: 12))
                            Text("\(String(format: "%.4f", (self.barometerInformationPressure) * 7.50062)) mm Hg")
                                .font(.system(size: 12))
                            Text("\(String(format: "%.4f", (self.barometerInformationPressure) / 101.325)) atm")
                                .font(.system(size: 12))
                        }
                    }
                    Spacer()
                    HStack {
                        Text("Altitude")
                            .multilineTextAlignment(.leading)
                            .frame(width: 120)
                            .frame(width: 10)
                            .font(.system(size: 12))
                            .rotationEffect(.degrees(-90))
                        
                        Spacer()
                        
                        VStack(alignment: .trailing) {
                            Text("\(String(format: "%.0f", self.barometerInformationHeight)) m")
                                .font(.system(size: 12))
                        }
                    }
                }
            }
        }
        .padding()
        .onAppear {
            barometer.startRelativeAltitudeUpdates(to: .main) { data, error in
                if data != nil {
                    self.barometerInformationPressure = data!.pressure.doubleValue
                    self.barometerInformationDelta = data!.relativeAltitude.doubleValue
                    
                    //Ph = P0 * exp(-0.00012 * h)
                    //exp(-0.00012 * h) = Ph / P0
                    //-0.00012 * h = ln( Ph / P0 )
                    //ln( P0 / Ph ) = 0.00012 * h
                    // h = ln ( P0 / Ph ) / 0.00012
                    // P0 = 101.325
                    
                    let P0: Double = 101.325
                    let Ph: Double = data!.pressure.doubleValue
                    let h: Double = log(P0 / Ph) / 0.00012
                    
                    self.barometerInformationHeight = h
                    self.barometerInformationEverest = h / 8848
                }
            }
        }
        
    }
}

#Preview {
    ContentView()
}
