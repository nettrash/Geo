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
    var body: some View {
        ZStack(content: {
            Image("GeoBig")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .opacity(0.02)
            ScrollView {
                GraphView(Caption: "PRESSURE", Data: pressureDataSet,
                          min: 700.0, max: 810.0, measurement: "mm Hg", useGreenBorder: true, useYellowBorder: false, useRedBorder: false, greenValue: 762, greenText: "normal")
                GraphView(Caption: "ALTITUDE BAROMETER", Data: altitudeBarometerDataSet,
                          min: 0.0, max: 10000.0, measurement: "m", useGreenBorder: false, useYellowBorder: true, useRedBorder: true, yellowValue: 2500, redValue: 7980, yellowText: "thin air", redText: "death zone")
                GraphView(Caption: "ALTITUDE GPS", Data: altitudeGPSDataSet, min: 0.0, max: 10000.0, measurement: "m", useGreenBorder: false, useYellowBorder: true, useRedBorder: true, yellowValue: 2500, redValue: 7980, yellowText: "thin air", redText: "death zone")
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
        
        for historyItem in history.historyItems.suffix(7) {
            pressureDataSet.append(DataItem(Value: historyItem.barometerPressure * 7.50062, Legend: historyItem.description))
        }
    }
    
    mutating func barometerDataSetRefresh() {
        altitudeBarometerDataSet.removeAll()
        
        for historyItem in history.historyItems.suffix(7) {
            altitudeBarometerDataSet.append(DataItem(Value: historyItem.barometerAltitude, Legend: historyItem.recordDate?.ISO8601Format() ?? ""))
        }
    }
    
    mutating func gpsDataSetRefresh() {
        altitudeGPSDataSet.removeAll()
        
        for historyItem in history.historyItems.suffix(7) {
            altitudeGPSDataSet.append(DataItem(Value: historyItem.gpsAltitude, Legend: historyItem.recordDate?.ISO8601Format() ?? ""))
        }
    }
}

#Preview {
    GeoStatView(history: History())
}
