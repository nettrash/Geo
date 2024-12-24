//
//  GeoStatView.swift
//  Geo
//
//  Created by nettrash on 18/06/2024.
//

import SwiftUI

struct GeoStatView: View {
    @State var history: History
    var decimal: Decimal = 0.0
    var body: some View {
        ZStack(content: {
            Image("GeoBig")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .opacity(0.02)
            ScrollView {
                GraphView(Caption: "PRESSURE", Data: pressureDataSet())
                GraphView(Caption: "ALTITUDE BAROMETER", Data: barometerDataSet())
                GraphView(Caption: "ALTITUDE GPS", Data: gpsDataSet())
            }
        })
    }
    
    init(history: History) {
        self.history = history
        RefreshHistory()
    }

    func RefreshHistory() {
        self.history.Refresh()
    }
    
    func pressureDataSet() -> [DataItem] {
        var data: [DataItem] = []
        
        for historyItem in history.historyItems {
            data.append(DataItem(Value: historyItem.barometerPressure, Legend: historyItem.description))
        }
        
        return data
    }
    
    func barometerDataSet() -> [DataItem] {
        var data: [DataItem] = []
        
        for historyItem in history.historyItems {
            data.append(DataItem(Value: historyItem.barometerAltitude, Legend: historyItem.recordDate?.ISO8601Format() ?? ""))
        }
        
        return data
    }
    
    func gpsDataSet() -> [DataItem] {
        var data: [DataItem] = []
        
        for historyItem in history.historyItems {
            data.append(DataItem(Value: historyItem.gpsAltitude, Legend: historyItem.recordDate?.ISO8601Format() ?? ""))
        }
        
        return data
    }
}

#Preview {
    GeoStatView(history: History())
}
