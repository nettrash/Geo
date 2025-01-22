//
//  HistoryDetailsView.swift
//  Geo
//
//  Created by Ivan Alekseev on 03/01/2025.
//

import SwiftUI

struct HistoryDetailsView: View {
    @State var item: HistoryItem? = nil
    
    private let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter
        }()

    var body: some View {
        
        if item != nil {
            VStack {
                VStack {
                    Text("History point details")
                        .font(.headline)
                    
                    Text(dateFormatter.string(from: item?.recordDate ?? Date()))
                        .font(.system(size: 10))
                }
                .padding()
                
                Text("Barometer information")
                    .underline()
                    .padding()
                
                HStack(alignment: .top) {
                    Text("Pressure")
                        .padding()
                    Spacer()
                    VStack {
                        Text("\(String(format: "%.4f", item?.barometerPressure ?? 0)) kPa")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text("\(String(format: "%.4f", (item?.barometerPressure ?? 0) * 7.50062)) mm Hg")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text("\(String(format: "%.4f", (item?.barometerPressure ?? 0) / 101.325)) atm")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding()
                }
                HStack(alignment: .top) {
                    Text("Altitude")
                        .padding()
                    Spacer()
                    VStack {
                        Text("\(String(format: "%.0f", item?.barometerAltitude ?? 0)) m")
                    }
                    .padding()
                }
                
                Text("Satellite information")
                    .underline()
                    .padding()
                
                HStack(alignment: .top) {
                    Text("Coordinates")
                        .font(.subheadline)
                        .padding()
                    Spacer()
                    VStack {
                        Text("\(String(format: "%.6f", item?.gpsLatitude ?? 0)) lt")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text("\(String(format: "%.6f", item?.gpsLongitude ?? 0)) lg")
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
                        Text("\(String(format: "%.0f", item?.gpsAltitude ?? 0)) m")
                    }
                    .padding()
                }
                
                HStack(alignment: .top) {
                    Text("Velocity")
                        .font(.subheadline)
                        .padding()
                    Spacer()
                    VStack {
                        Text("\(String(format: "%.1f", item?.gpsVelocity ?? 0)) m/s")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text("\(String(format: "%.1f", (item?.gpsVelocity ?? 0) * 3600.0 / 1000.0)) km/h")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding()
                }
                
                
            }
            Spacer()
        } else {
            Text("Loading...")
        }
    }
}

#Preview {
    HistoryDetailsView(item: nil)
}
