//
//  GeoStatView.swift
//  Geo
//
//  Created by nettrash on 18/06/2024.
//

import SwiftUI

struct GeoStatView: View {
    @State @ObservedObject var history: History
        
    var body: some View {
        ZStack(content: {
            Image("GeoBig")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .opacity(0.02)
            ScrollView {
                GraphView(Caption: "PRESSURE", Data: history.pressureDataSet, Lines: [GraphLine(value: 760, text: "normal", color: Color.green)],
                          min: history.pressureDataSetMin, max: history.pressureDataSetMax, measurement: "mm Hg")
                GraphView(Caption: "ALTITUDE BAROMETER", Data: history.altitudeBarometerDataSet, Lines: [GraphLine(value: 4500, text: "thin air", color: Color.yellow), GraphLine(value: 7980, text: "death zone", color: Color.red)],
                          min: history.altitudeBarometerDataSetMin, max: history.altitudeBarometerDataSetMax, measurement: "m")
                GraphView(Caption: "ALTITUDE GPS", Data: history.altitudeGPSDataSet, Lines: [GraphLine(value: 4500, text: "thin air", color: Color.yellow), GraphLine(value: 7980, text: "death zone", color: Color.red)], min: history.altitudeGPSDataSetMin, max: history.altitudeGPSDataSetMax, measurement: "m")
            }
        })
    }
    
    init(history: History) {
        self.history = history
        RefreshHistory()
    }
    
    mutating func RefreshHistory() {
        self.history.Refresh()
    }
}

#Preview {
    GeoStatView(history: History())
}
