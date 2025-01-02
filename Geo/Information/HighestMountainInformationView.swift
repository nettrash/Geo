//
//  SatelliteInformationView.swift
//  Geo
//
//  Created by nettrash on 18/06/2024.
//

import SwiftUI
import MapKit
import CoreLocation

struct HighestMountainInformationView: View {
    @State var location: Location?;

    var body: some View {
        ZStack {
            Text("HIGHEST MOUNTAIN")
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
                        Text(HighestMountainName())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(HighestMountainAltitude())
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
                        Text(HighestMountainDistance())
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
                        Text(HighestMountainLocationLatitude())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(HighestMountainLocationLongitude())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding()
                }

                HStack(alignment: .top) {
                    Spacer()
                    Button(action: {
                        OpenMapForHighestMountain()
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
    
    func HighestMountainName() -> String {
        guard location?.highestMountain != nil else { return "?" }
        return location?.highestMountain?.name ?? "-"
    }
    
    func HighestMountainAltitude() -> String {
        guard location?.highestMountain != nil else { return "? m" }
        return "\(String(location?.highestMountain?.height ?? 0)) m"
    }
    
    func HighestMountainDistance() -> String {
        guard location?.highestMountain != nil else { return "? m" }
        return "\(String(format: "%.2f", (location?.highestMountainDistance ?? 0) / 1000)) km"
    }
    
    func HighestMountainLocationLatitude() -> String {
        guard location?.highestMountain != nil else { return "? lt" }
        return "\(String(format: "%.6f", location?.highestMountain?.coordinates?.latitude ?? 0)) lt"
    }
    
    func HighestMountainLocationLongitude() -> String {
        guard location?.highestMountain != nil else { return "? lg" }
        return "\(String(format: "%.6f", location?.highestMountain?.coordinates?.longitude ?? 0)) lg"
    }
    
    func OpenMapForHighestMountain() {
        guard location != nil else { return }
        
        let source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: location?.location?.coordinate.latitude ?? 0, longitude: location?.location?.coordinate.longitude ?? 0)))
        source.name = "Current location"
                
        let destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: location?.highestMountain?.coordinates?.latitude ?? 0, longitude: location?.highestMountain?.coordinates?.longitude ?? 0)))
        destination.name = location?.highestMountain?.name ?? "Destination"
                
        MKMapItem.openMaps(
          with: [source, destination],
          launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving]
        )
    }
}

#Preview {
    HighestMountainInformationView(location: nil)
}
