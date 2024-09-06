//
//  SatelliteInformationView.swift
//  Geo
//
//  Created by nettrash on 18/06/2024.
//

import SwiftUI

struct SatelliteInformationView: View {
    @State var location: Location?;

    var body: some View {
        ZStack {
            /*Image("Satellite")
                .resizable()
                .frame(width: 200, height: 200)
                .aspectRatio(contentMode: .fit)
                .opacity(0.12)*/
            
            Text("S A T E L L I T E")
                .opacity(0.2)
                .font(.title)
                .rotationEffect(.degrees(-25))
                .padding()

            VStack {
                /*ZStack {
                 Color.gray
                 .opacity(0.5)
                 .frame(height: 60)
                 
                 VStack {
                 Spacer()
                 .frame(height: 2)
                 
                 HStack {
                 Text("Satellite")
                 .font(.headline)
                 Spacer()
                 }
                 .padding()
                 }
                 }*/
                
                HStack(alignment: .top) {
                    Text("Coordinates")
                        .font(.subheadline)
                        .padding()
                    Spacer()
                    VStack {
                        Text("\(String(format: "%.6f", location?.location?.coordinate.latitude ?? 0)) lt")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text("\(String(format: "%.6f", location?.location?.coordinate.longitude ?? 0)) lg")
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
                        Text("\(String(format: "%.0f", location?.location?.altitude ?? 0)) m")
                    }
                    .padding()
                }
                
                HStack(alignment: .top) {
                    Text("Velocity")
                        .font(.subheadline)
                        .padding()
                    Spacer()
                    VStack {
                        Text("\(String(format: "%.1f", location?.location?.speed ?? 0)) m/s")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text("\(String(format: "%.1f", (location?.location?.speed ?? 0) * 3600.0 / 1000.0)) km/h")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding()
                }
                
                Spacer()
                    .frame(height: 10)
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
    SatelliteInformationView(location: nil)
}
