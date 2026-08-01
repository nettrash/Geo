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
    @State var location: Location?
    var motion: DeviceMotionManager?
    /// Magnetic Conditions, published down from the card above — same
    /// pass-through as `ClosestMountainInformationView`, since both cards
    /// share `PeakBearingRow`.
    var magnetic: MagneticConditions?

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
                        Text(verbatim: HighestMountainName())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(verbatim: HighestMountainAltitude())
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
                        Text(verbatim: HighestMountainDistance())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding()
                }

                if let motion {
                    PeakBearingRow(userCoordinate: location?.location?.coordinate,
                                   peakLatitude: location?.highestMountain?.coordinates?.latitude,
                                   peakLongitude: location?.highestMountain?.coordinates?.longitude,
                                   motion: motion,
                                   gScale: magnetic?.gScale ?? .g0,
                                   compass: magnetic?.compass ?? .normal)
                }

                HStack(alignment: .top) {
                    Text("Coordinates")
                        .font(.subheadline)
                        .padding()
                    Spacer()
                    VStack {
                        Text(verbatim: HighestMountainLocationLatitude())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(verbatim: HighestMountainLocationLongitude())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding()
                }

                HStack(alignment: .top) {
                    Spacer()
                    Button {
                        OpenMapForHighestMountain()
                    } label: {
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
        return "\(String(format: "%.2f", (location?.highestMountainDistance ?? 0.0) / 1000.0)) km"
    }

    func HighestMountainLocationLatitude() -> String {
        guard location?.highestMountain != nil else { return "? lt" }
        return "\(String(format: "%.6f", location?.highestMountain?.coordinates?.latitude ?? 0.0)) lt"
    }

    func HighestMountainLocationLongitude() -> String {
        guard location?.highestMountain != nil else { return "? lg" }
        return "\(String(format: "%.6f", location?.highestMountain?.coordinates?.longitude ?? 0.0)) lg"
    }

    func OpenMapForHighestMountain() {
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
            latitude: location?.highestMountain?.coordinates?.latitude ?? 0,
            longitude: location?.highestMountain?.coordinates?.longitude ?? 0
        )
        let destinationLocation = CLLocation(
            latitude: destinationCoordinate.latitude,
            longitude: destinationCoordinate.longitude
        )
        let destination = MKMapItem(location: destinationLocation, address: nil)
        destination.name = location?.highestMountain?.name ?? "Destination"

        MKMapItem.openMaps(
            with: [source, destination],
            launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving]
        )
    }
}

#Preview {
    HighestMountainInformationView(location: nil, motion: nil, magnetic: nil)
}
