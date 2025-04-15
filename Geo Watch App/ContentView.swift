//
//  ContentView.swift
//  Geo Watch App
//
//  Created by Ivan Alekseev on 24/01/2025.
//

import SwiftUI

struct ContentView: View {
    @State var barometerInformation: BarometerInformation? = nil
    
    var body: some View {
        
        VStack {
            if let info = barometerInformation {
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
                                Text("\(String(format: "%.4f", info.pressure)) kPa")
                                    .font(.system(size: 12))
                                Text("\(String(format: "%.4f", (info.pressure) * 7.50062)) mm Hg")
                                    .font(.system(size: 12))
                                Text("\(String(format: "%.4f", (info.pressure) / 101.325)) atm")
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
                                Text("\(String(format: "%.0f", info.height)) m")
                                    .font(.system(size: 12))
                            }
                        }
                    }
                }
            } else {
                Image(systemName: "globe")
                    .imageScale(.large)
                    .foregroundStyle(.tint)
                Text("Loading...")
            }
        }
        .padding()
        
    }
}

#Preview {
    ContentView(barometerInformation: BarometerInformation())
}
