//
//  GeoStatView.swift
//  Geo
//
//  Created by nettrash on 18/06/2024.
//

import SwiftUI

struct GeoStatView: View {
    @State var app: GeoAppDelegate
        
    var body: some View {
        ZStack(content: {
            Image("GeoBig")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .opacity(0.02)
            ScrollView {
                GraphView(Caption: "PRESSURE", Data: self.app.history.pressureDataSet, Lines: [GraphLine(value: 760, text: "normal", color: Color.green)],
                          min: self.app.history.pressureDataSetMin, max: self.app.history.pressureDataSetMax, measurement: "mm Hg")
                GraphView(Caption: "ALTITUDE BAROMETER", Data: self.app.history.altitudeBarometerDataSet, Lines: [GraphLine(value: 4500, text: "thin air", color: Color.yellow), GraphLine(value: 7980, text: "death zone", color: Color.red)],
                          min: self.app.history.altitudeBarometerDataSetMin, max: self.app.history.altitudeBarometerDataSetMax, measurement: "m")
                GraphView(Caption: "ALTITUDE GPS", Data: self.app.history.altitudeGPSDataSet, Lines: [GraphLine(value: 4500, text: "thin air", color: Color.yellow), GraphLine(value: 7980, text: "death zone", color: Color.red)], min: self.app.history.altitudeGPSDataSetMin, max: self.app.history.altitudeGPSDataSetMax, measurement: "m")
            }
        })
    }
    
    init(app: GeoAppDelegate?) {
        app?.history.Refresh()
        
        self.app = app ?? GeoAppDelegate()
    }

}

#Preview {
    GeoStatView(app: GeoAppDelegate())
}
