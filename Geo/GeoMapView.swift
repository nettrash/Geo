//
//  GeoMapView.swift
//  Geo
//
//  Created by nettrash on 18/06/2024.
//

import SwiftUI
import MapKit

struct GeoMapView: View {
    
    @State var cameraPosition = MapCameraPosition.userLocation(followsHeading: false, fallback: MapCameraPosition.automatic)
    
    var body: some View {
        Map(position: $cameraPosition, interactionModes: .all)
            .scrollDisabled(true)
            .mapControlVisibility(.visible)
            .mapControls {
                MapCompass()
                MapUserLocationButton()
                MapScaleView()
                MapPitchToggle()
            }
    }
}

#Preview {
    GeoMapView()
}
