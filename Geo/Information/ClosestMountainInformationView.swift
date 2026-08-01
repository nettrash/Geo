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
    @State var location: Location?
    var motion: DeviceMotionManager?
    /// Magnetic Conditions, published down from the card above so the bearing
    /// row can warn about a storm-time heading offset. `nil` until that card
    /// has evaluated once, and in previews.
    var magnetic: MagneticConditions?

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
                        Text(verbatim: ClosestMountainLocationLatitude())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(verbatim: ClosestMountainLocationLongitude())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding()
                }

                HStack(alignment: .top) {
                    Spacer()
                    Button {
                        OpenMapForClosestMountain()
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
    /// Current NOAA G level and the banded storm-time declination offset for
    /// this magnetic latitude. Only used to add a caption at G3 and above.
    let gScale: GScale
    let compass: CompassBand

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
                        Text(verbatim: "\(Int(bearing.rounded()) % 360)° \(Geometry.cardinalDirection(bearing))")
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
                // Both captions can be up at once: a figure-8 fixes an
                // uncalibrated compass, and nothing fixes a geomagnetic storm.
                // They are different problems and the user deserves both.
                if let storm = Self.stormCaption(gScale: gScale, compass: compass) {
                    HStack {
                        Spacer()
                        Text(verbatim: storm)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.trailing)
                            .padding([.horizontal, .bottom], 8)
                    }
                }
            }
        }
    }

    /// The G3+ heading caption. Banded rather than a single figure — the
    /// number never reaches a readout (honesty contract item 9) — and it
    /// closes by saying plainly that the compass's own error is the bigger
    /// problem, so nobody reads it as a correction to dial in.
    private static func stormCaption(gScale: GScale, compass: CompassBand) -> String? {
        guard gScale.rawValue >= Geomagnetic.compassAdvisoryMinG else { return nil }
        let band: String
        switch compass {
        case .normal:    return nil
        case .underOne:  band = "under 1°"
        case .oneToTwo:  band = "1–2°"
        case .twoToFive: band = "2–5°"
        case .overFive:  band = "over 5°"
        }
        return "Geomagnetic storm (G\(gScale.rawValue)) — roughly \(band) extra heading error here. "
             + "Your compass's own error is larger."
    }
}

#Preview {
    ClosestMountainInformationView(location: nil, motion: nil, magnetic: nil)
}
