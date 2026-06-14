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
    var motion: DeviceMotionManager?

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

                if let motion {
                    PeakBearingRow(userCoordinate: location?.location?.coordinate,
                                   peakLatitude: location?.closestMountain?.coordinates?.latitude,
                                   peakLongitude: location?.closestMountain?.coordinates?.longitude,
                                   motion: motion)
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

/// Distance-paired "point me toward it" row: a true-bearing readout
/// ("117° SE") plus an arrow that rotates to the device's live heading so
/// it always points at the peak. Reused by the closest- and highest-peak
/// cards. Renders nothing until both the observer and peak coordinates are
/// known. A low-power, AR-free direction finder.
struct PeakBearingRow: View {
    let userCoordinate: CLLocationCoordinate2D?
    let peakLatitude: Double?
    let peakLongitude: Double?
    @ObservedObject var motion: DeviceMotionManager

    /// True bearing (deg) from observer to peak, or `nil` when either
    /// coordinate is missing or an unset `(0,0)`.
    private var bearing: Double? {
        guard let user = userCoordinate, let plat = peakLatitude, let plon = peakLongitude,
              CLLocationCoordinate2DIsValid(user),
              !(user.latitude == 0 && user.longitude == 0),
              !(plat == 0 && plon == 0) else { return nil }
        let peak = CLLocationCoordinate2D(latitude: plat, longitude: plon)
        return Geometry.bearing(from: user, to: peak)
    }

    var body: some View {
        if let bearing {
            VStack(spacing: 2) {
                HStack(alignment: .top) {
                    Text("Bearing")
                        .font(.subheadline)
                        .padding()
                    Spacer()
                    HStack(spacing: 6) {
                        // `location.north.fill` points up; rotating by
                        // (bearing − heading) aims it at the peak's real-world
                        // direction relative to where the device points.
                        Image(systemName: "location.north.fill")
                            .rotationEffect(.degrees(bearing - motion.heading))
                        Text(verbatim: "\(Int(bearing.rounded()))° \(Geometry.cardinalDirection(bearing))")
                    }
                    .padding()
                }
                if motion.headingAccuracy < 0 || motion.headingAccuracy > 25 {
                    HStack {
                        Spacer()
                        Text("Calibrate compass — move in a figure-8")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .padding([.horizontal, .bottom], 8)
                    }
                }
            }
        }
    }
}

#Preview {
    ClosestMountainInformationView(location: nil, motion: nil)
}
