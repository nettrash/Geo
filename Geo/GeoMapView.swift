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
    
    @State var history: History
    
    var body: some View {
        Map(position: $cameraPosition, interactionModes: .all)
        {
            ForEach(history.historyItems) { item in
                Marker(coordinate: CLLocationCoordinate2DMake(item.gpsLatitude,item.gpsLongitude)) {
                    Text(item.recordDate?.formatted() ?? "")
                }
            }
        }
        .scrollDisabled(true)
        .mapControlVisibility(.visible)
        .mapControls {
            MapCompass()
            MapUserLocationButton()
            MapScaleView()
            MapPitchToggle()
        }
        .onAppear {
            self.history.Refresh()
        }
    }
}

#Preview {
    GeoMapView(history: History())
}
