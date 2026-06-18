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
    
    @State var appDelegate: GeoWatchAppDelegate
    
    @State var barometerInformationPressure: Double = 0
    @State var barometerInformationDelta: Double = 0
    @State var barometerInformationHeight: Double = 0
    @State var barometerInformationEverest: Double = 0
    @State var historyData: [DataItem] = []
    @State var historyDataMin: Double = 0
    @State var historyDataMax: Double = 10000

    @State private var lastInfoUpdateDate: Date = Date()
    private let historyCount: Int = 20

    private let trackingDateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return formatter
        }()

    var body: some View {
        
        VStack {
            ZStack {
                Image("Background.png")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(0.3)
                
                GraphView(Data: $historyData, min: $historyDataMin, max: $historyDataMax, measurement: "m")
                    .opacity(0.5)

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
                            Text(verbatim: "\(String(format: "%.4f", self.barometerInformationPressure)) kPa")
                                .font(.system(size: 12))
                            Text(verbatim: "\(String(format: "%.4f", (self.barometerInformationPressure) * 7.50062)) mm Hg")
                                .font(.system(size: 12))
                            Text(verbatim: "\(String(format: "%.4f", (self.barometerInformationPressure) / 101.325)) atm")
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
                            Text(verbatim: "\(String(format: "%.0f", self.barometerInformationHeight)) m")
                                .font(.system(size: 12))
                        }
                    }
                }
            }
        }
        .padding()
        .onAppear {
            // Show whatever the app delegate already restored from the shared
            // store so the UI doesn't flash zeros on launch while we wait for
            // the first live barometer sample.
            self.barometerInformationPressure = self.appDelegate.barometerInformationPressure
            self.barometerInformationDelta = self.appDelegate.barometerInformationDelta
            self.barometerInformationHeight = self.appDelegate.barometerInformationHeight
            self.barometerInformationEverest = self.appDelegate.barometerInformationEverest

            self.appDelegate.registerCallback { pressure, delta, height, everest in
                self.barometerInformationPressure = pressure
                self.barometerInformationDelta = delta

                // Use the calibrated altitude the delegate already computed from the
                // iPhone reference; do not re-derive an uncalibrated value here.
                self.barometerInformationHeight = height
                self.barometerInformationEverest = everest

                // Append only real samples (no pre-seeded zeros) so the graph
                // autoscales over actual data from the first two points, mirroring
                // the Android Wear sparkline.
                let firstAdd: Bool = self.historyData.isEmpty

                if firstAdd || self.lastInfoUpdateDate.addingTimeInterval(30) < Date() {
                    self.historyData.append(DataItem(Value: height, Legend: trackingDateFormatter.string(from:Date())))
                    while self.historyData.count > self.historyCount {
                        self.historyData.removeFirst()
                    }

                    let minDataItem = self.historyData.min(by: { $0.Value < $1.Value })
                    let maxDataItem = self.historyData.max(by: { $0.Value < $1.Value })

                    self.historyDataMin =
                        if (minDataItem?.Value ?? 0) - 250 > 0 {
                            (minDataItem?.Value ?? 0) - 50
                        } else {
                            0
                        }
                    self.historyDataMax =
                        if (maxDataItem?.Value ?? 0) + 250 < 9000 {
                            (maxDataItem?.Value ?? 0) + 50
                        } else {
                            9000
                        }
                    self.lastInfoUpdateDate = Date();
                }
            }
            self.appDelegate.startUpdating()
        }
    }
}

#Preview {
    ContentView(appDelegate: GeoWatchAppDelegate())
}
