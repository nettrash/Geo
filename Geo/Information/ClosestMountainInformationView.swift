//
//  SatelliteInformationView.swift
//  Geo
//
//  Created by nettrash on 18/06/2024.
//

import SwiftUI
import MapKit
import CoreLocation

struct ClosestMountainInformationView: View {
    @State var location: Location?;

    var body: some View {
        ZStack {
            Text("CLOSEST MOUNTAIN")
                .opacity(0.2)
                .font(.title)
                .rotationEffect(.degrees(-25))
                .padding()

            VStack {
                
                HStack(alignment: .top) {
                    Text("Name")
                        .font(.subheadline)
                        .padding()
                    Spacer()
                    VStack {
                        Text(ClosestMountainName())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(ClosestMountainAltitude())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding()
                }
                
                HStack(alignment: .top) {
                    Text("Distance")
                        .font(.subheadline)
                        .padding()
                    Spacer()
                    VStack {
                        Text(ClosestMountainDistance())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding()
                }

                HStack(alignment: .top) {
                    Text("Coordinates")
                        .font(.subheadline)
                        .padding()
                    Spacer()
                    VStack {
                        Text(ClosestMountainLocationLatitude())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(ClosestMountainLocationLongitude())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding()
                }

                HStack(alignment: .top) {
                    Spacer()
                    Button(action: {
                        OpenMapForClosestMountain()
                    }) {
                        Text("Directions")
                            .font(.subheadline)
                            .padding(10)
                            .foregroundColor(.white)
                            .background(.gray)
                            .cornerRadius(8)
                    }
                    Spacer()
                        .frame(width: 10)
                }
                
                Spacer()
                    .frame(height: 10)
            }
            .background(
                Color.gray.opacity(0.3)
            )
            .fontDesign(.monospaced)
            .cornerRadius(15)
            .padding()
        }
    }
    
    func ClosestMountainName() -> String {
        guard location?.closestMountain != nil else { return "?" }
        return location?.closestMountain?.name ?? "-"
    }
    
    func ClosestMountainAltitude() -> String {
        guard location?.closestMountain != nil else { return "? m" }
        return "\(String(location?.closestMountain?.height ?? 0)) m"
    }
    
    func ClosestMountainDistance() -> String {
        guard location?.closestMountain != nil else { return "? m" }
        return "\(String(format: "%.2f", (location?.closestMountainDistance ?? 0) / 1000)) km"
    }
    
    func ClosestMountainLocationLatitude() -> String {
        guard location?.closestMountain != nil else { return "? lt" }
        return "\(String(format: "%.6f", location?.closestMountain?.coordinates?.latitude ?? 0)) lt"
    }
    
    func ClosestMountainLocationLongitude() -> String {
        guard location?.closestMountain != nil else { return "? lg" }
        return "\(String(format: "%.6f", location?.closestMountain?.coordinates?.longitude ?? 0)) lg"
    }
    
    func OpenMapForClosestMountain() {
        guard location != nil else { return }
        
        let source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: location?.location?.coordinate.latitude ?? 0, longitude: location?.location?.coordinate.longitude ?? 0)))
        source.name = "Current location"
                
        let destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: location?.closestMountain?.coordinates?.latitude ?? 0, longitude: location?.closestMountain?.coordinates?.longitude ?? 0)))
        destination.name = location?.closestMountain?.name ?? "Destination"
                
        MKMapItem.openMaps(
          with: [source, destination],
          launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving]
        )
    }
}

#Preview {
    ClosestMountainInformationView(location: nil)
}
