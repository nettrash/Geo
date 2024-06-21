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
            /*VStack {
                Text("Information")
                    .font(.largeTitle)
                    .padding()*/
                ScrollView {
                    BarometerInformationView(barometer: app?.barometer)
                    
                    SatelliteInformationView(location: app?.location)
                        .onAppear(perform: {
                            app?.location?.initialize()
                        })
                }
            /*}*/
        })
    }
}

#Preview {
    GeoInfoView(app: nil)
}
