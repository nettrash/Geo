//
//  GeoMapView.swift
//  Geo
//
//  Created by nettrash on 18/06/2024.
//

import SwiftUI
import MapKit

struct GeoMapView: View {
    var body: some View {
        ZStack {
            Map {
                
            }
            .mapControlVisibility(.visible)
            
            VStack {
                Text("Geo Information")
                    .font(.largeTitle)
                    .padding()
                
                Spacer()
            }
        }
    }
}

#Preview {
    GeoMapView()
}
