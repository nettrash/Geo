//
//  GeoStatView.swift
//  Geo
//
//  Created by nettrash on 18/06/2024.
//

import SwiftUI

struct GeoStatView: View {
    @State @ObservedObject var history: History
    var pressureDataSet: [DataItem] = []
    var altitudeBarometerDataSet: [DataItem] = []
    var altitudeGPSDataSet: [DataItem] = []
    var decimal: Decimal = 0.0
    
    private let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter
        }()
    
    var body: some View {
        ZStack(content: {
            Image("GeoBig")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .opacity(0.02)
            ScrollView {
                GraphView(Caption: "PRESSURE", Data: pressureDataSet,
                          min: 150.0, max: 850.0, measurement: "mm Hg", useGreenBorder: true, useYellowBorder: false, useRedBorder: false, greenValue: 762, greenText: "normal")
                GraphView(Caption: "ALTITUDE BAROMETER", Data: altitudeBarometerDataSet,
                          min: 0.0, max: 10000.0, measurement: "m", useGreenBorder: false, useYellowBorder: true, useRedBorder: true, yellowValue: 4500, redValue: 7980, yellowText: "thin air", redText: "death zone")
                GraphView(Caption: "ALTITUDE GPS", Data: altitudeGPSDataSet, min: 0.0, max: 10000.0, measurement: "m", useGreenBorder: false, useYellowBorder: true, useRedBorder: true, yellowValue: 4500, redValue: 7980, yellowText: "thin air", redText: "death zone")
            }
        })
    }
    
    init(history: History) {
        self.history = history
        RefreshHistory()
    }
    
    mutating func RefreshHistory() {
        self.history.Refresh()
        pressureDataSetRefresh()
        barometerDataSetRefresh()
        gpsDataSetRefresh()
    }
    
    mutating func pressureDataSetRefresh() {
        pressureDataSet.removeAll()
        
        for historyItem in history.historyItems.suffix(15) {
            pressureDataSet.append(DataItem(Value: historyItem.barometerPressure * 7.50062, Legend: dateFormatter.string(from: historyItem.recordDate ?? Date())))
        }
    }
    
    mutating func barometerDataSetRefresh() {
        altitudeBarometerDataSet.removeAll()
        
        for historyItem in history.historyItems.suffix(15) {
            altitudeBarometerDataSet.append(DataItem(Value: historyItem.barometerAltitude, Legend: dateFormatter.string(from: historyItem.recordDate ?? Date())))
        }
    }
    
    mutating func gpsDataSetRefresh() {
        altitudeGPSDataSet.removeAll()
        
        for historyItem in history.historyItems.suffix(15) {
            altitudeGPSDataSet.append(DataItem(Value: historyItem.gpsAltitude, Legend: dateFormatter.string(from: historyItem.recordDate ?? Date())))
        }
    }
}

#Preview {
    GeoStatView(history: History())
}
