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
                        Text(verbatim: ClosestMountainName())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(verbatim: ClosestMountainAltitude())
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
                        Text(verbatim: ClosestMountainDistance())
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
                        Text(verbatim: ClosestMountainLocationLatitude())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(verbatim: ClosestMountainLocationLongitude())
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
                            .font(.system(size: 12))
                            .padding(6)
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
        return "\(String(format: "%.2f", (location?.closestMountainDistance ?? 0.0) / 1000.0)) km"
    }
    
    func ClosestMountainLocationLatitude() -> String {
        guard location?.closestMountain != nil else { return "? \(String(localized: "unit_latitude"))" }
        return "\(String(format: "%.6f", location?.closestMountain?.coordinates?.latitude ?? 0.0)) \(String(localized: "unit_latitude"))"
    }

    func ClosestMountainLocationLongitude() -> String {
        guard location?.closestMountain != nil else { return "? \(String(localized: "unit_longitude"))" }
        return "\(String(format: "%.6f", location?.closestMountain?.coordinates?.longitude ?? 0.0)) \(String(localized: "unit_longitude"))"
    }
    
    func OpenMapForClosestMountain() {
        guard location != nil else { return }
        
        let sourceCoordinate = CLLocationCoordinate2D(
            latitude: location?.location?.coordinate.latitude ?? 0,
            longitude: location?.location?.coordinate.longitude ?? 0
        )
        let sourceLocation = CLLocation(
            latitude: sourceCoordinate.latitude,
            longitude: sourceCoordinate.longitude
        )
        let source = MKMapItem(location: sourceLocation, address: nil)
        source.name = "Current location"
        
        let destinationCoordinate = CLLocationCoordinate2D(
            latitude: location?.closestMountain?.coordinates?.latitude ?? 0,
            longitude: location?.closestMountain?.coordinates?.longitude ?? 0
        )
        let destinationLocation = CLLocation(
            latitude: destinationCoordinate.latitude,
            longitude: destinationCoordinate.longitude
        )
        let destination = MKMapItem(location: destinationLocation, address: nil)
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
