//
//  GeoStatView.swift
//  Geo
//
//  Created by nettrash on 18/06/2024.
//

import SwiftUI

struct GeoStatView: View {
    @ObservedObject var history: History
        
    var body: some View {
        ZStack(content: {
            Image("GeoBig")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .opacity(0.02)
            ScrollView {
                Text("TRACKING")
                    .font(.title)
                    .padding()
                PairGraphView(Caption: "TRACKING ALTITUDE", Data: $history.trackingAltitudeDataSet, Lines: [GraphLine(value: 4500, text: "thin air", color: Color.yellow), GraphLine(value: 7980, text: "death zone", color: Color.red)],
                              min: $history.trackingAltitudeDataSetMin, max: $history.trackingAltitudeDataSetMax, Colors: [.white, .orange], Legend: ["barometer", "gps"], measurement: "m"
                )
                Text("STATISTICS")
                    .font(.title)
                    .padding()
                GraphView(Caption: "PRESSURE", Data: $history.pressureDataSet, Lines: [GraphLine(value: 760, text: "normal", color: Color.green)],
                          min: $history.pressureDataSetMin, max: $history.pressureDataSetMax, measurement: "mm Hg")
                GraphView(Caption: "ALTITUDE BAROMETER", Data: $history.altitudeBarometerDataSet, Lines: [GraphLine(value: 4500, text: "thin air", color: Color.yellow), GraphLine(value: 7980, text: "death zone", color: Color.red)],
                          min: $history.altitudeBarometerDataSetMin, max: $history.altitudeBarometerDataSetMax, measurement: "m")
                GraphView(Caption: "ALTITUDE GPS", Data: $history.altitudeGPSDataSet, Lines: [GraphLine(value: 4500, text: "thin air", color: Color.yellow), GraphLine(value: 7980, text: "death zone", color: Color.red)], min: $history.altitudeGPSDataSetMin, max: $history.altitudeGPSDataSetMax, measurement: "m")
            }
        })
    }
    
    init(app: GeoAppDelegate?) {
        app?.history.Refresh()
        self.history = (app ?? GeoAppDelegate()).history
    }

}

#Preview {
    GeoStatView(app: GeoAppDelegate())
}
