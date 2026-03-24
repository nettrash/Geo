//
//  MountainDetailsView.swift
//  Geo
//
//  Created by Ivan Alekseev on 03/01/2025.
//

import SwiftUI
import MapKit

struct MountainDetailsView: View {
    let mountain: MountainInfo
    
    var body: some View {
        ZStack {
            Map(initialPosition: MapCameraPosition.region(
                MKCoordinateRegion(
                    center: CLLocationCoordinate2D(
                        latitude: mountain.coordinates?.latitude ?? 0,
                        longitude: mountain.coordinates?.longitude ?? 0),
                    latitudinalMeters: 5000,
                    longitudinalMeters: 5000)
                )
            )
                .mapStyle(.imagery)
                .opacity(0.2)
                .disabled(true)

            VStack {
                
                VStack {
                    Text(mountain.name ?? "")
                        .font(.headline)
                    
                    Text(verbatim: "\(mountain.height ?? 0) m")
                        .font(.system(size: 10))
                }
                .padding()
                
                /*if mountain.image != nil && mountain.image != "" {
                    Image(mountain.image ?? "")
                        .resizable(resizingMode: .stretch)
                        .frame(height: 200)
                        .padding()
                }*/
                
                HStack(alignment: .top) {
                    Text("Geography")
                        .font(.subheadline)
                        .padding()
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(mountain.partOfTheWorld ?? "")
                            .font(.system(size: 10))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(mountain.country ?? "")
                            .font(.system(size: 10))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(mountain.location ?? "")
                            .font(.system(size: 10))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Spacer()
                            .frame(height: 10)
                        Text(verbatim: "latitude: \(mountain.coordinates?.latitude ?? 0)")
                            .font(.system(size: 10))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(verbatim: "longitude: \(mountain.coordinates?.longitude ?? 0)")
                            .font(.system(size: 10))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Spacer()
                            .frame(height: 10)
                        Button(action: {
                            openMapForMountain()
                        }) {
                            Text("Show Map")
                                .font(.system(size: 12))
                                .padding(6)
                                .foregroundColor(.white)
                                .background(.gray)
                                .cornerRadius(8)
                        }
                    }
                    .padding()
                }
                
                if (mountain.firstAscent ?? "") != "" {
                    
                    HStack(alignment: .top) {
                        Text("Mountain")
                            .font(.subheadline)
                            .padding()
                        Spacer()
                        VStack(alignment: .trailing) {
                            if (mountain.firstAscent ?? "") == "" {
                                Text("first ascent is unknown")
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .font(.system(size: 10))
                            } else {
                                Text("first ascent was in \(mountain.firstAscent ?? "")")
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .font(.system(size: 10))
                            }
                        }
                        .padding()
                    }
                    
                }
                
                Spacer()
                
            }
        }
    }
    
    func openMapForMountain() {
        let coordinate = CLLocationCoordinate2D(
            latitude: mountain.coordinates?.latitude ?? 0,
            longitude: mountain.coordinates?.longitude ?? 0
        )
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        
        let destination = MKMapItem(location: location, address: nil)
        destination.name = mountain.name ?? "Destination"
        
        MKMapItem.openMaps(
            with: [destination],
            launchOptions: [:]
        )
    }
}

#Preview {
    MountainDetailsView(mountain: emptyMountainInfo)
}
