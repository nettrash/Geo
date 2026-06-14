//
//  GeoInfoView.swift
//  Geo
//
//  Created by nettrash on 18/06/2024.
//

import SwiftUI

struct GeoInfoView: View {
    @State var app: GeoAppDelegate?
        
    var body: some View {
        ZStack(content: {
            Image("GeoBig")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .opacity(0.02)
                ScrollView {
                    BarometerInformationView(barometer: app?.barometer, history: app?.history)
                        .onAppear { app?.history.refreshIfNeeded() }
                    
                    SatelliteInformationView(location: app?.location)
                        .onAppear(perform: {
                            app?.location?.initialize()
                        })
                    
                    ClosestMountainInformationView(location: app?.location)
                    
                    HighestMountainInformationView(location: app?.location)
                }
            /*}*/
        })
    }
}

#Preview {
    GeoInfoView(app: nil)
}
