//
//  Geometry.swift
//  Geo
//
//  Pure, testable geometry helpers used by AR overlays and tests.
//  Keeping these as a single home means the unit tests don't need
//  to touch ARKit, CoreLocation, or SwiftUI.
//

import Foundation
import CoreLocation

enum Geometry {

    /// Earth's mean radius in metres.
    static let earthRadius: Double = 6_371_000

    /// Approximate metres per degree of latitude (WGS-84 mean).
    static let metersPerDegreeLatitude: Double = 111_320

    /// Distance to the geographic horizon for an observer at height
    /// `h` above mean sea level.
    ///
    /// `d = sqrt(2·R·h + h²)`. The `h²` term is negligible for normal
    /// observer altitudes but cheap to keep, and matters for high-flying
    /// edge cases (mountaintops, aircraft, etc.).
    static func horizonDistance(observerAltitude h: Double,
                                radius R: Double = earthRadius) -> Double {
        let safeH = max(h, 0)
        return (2 * R * safeH + safeH * safeH).squareRoot()
    }

    /// Convert a remote GPS coordinate into a local East-North-Up offset
    /// (metres) anchored on the observer.
    ///
    /// Includes Earth-curvature correction for points more than ~5 km
    /// away — without it distant peaks visibly "float" above the
    /// horizon.
    static func gpsToENU(from origin: CLLocationCoordinate2D,
                         originAltitude: Double,
                         to target: CLLocationCoordinate2D,
                         targetAltitude: Double,
                         radius R: Double = earthRadius)
        -> (east: Double, north: Double, up: Double)
    {
        let latRef = origin.latitude * .pi / 180
        let metersPerDegreeLon = metersPerDegreeLatitude * cos(latRef)

        let dLat = target.latitude - origin.latitude
        let dLon = target.longitude - origin.longitude

        let north = dLat * metersPerDegreeLatitude
        let east  = dLon * metersPerDegreeLon

        let horizontalDist = (north * north + east * east).squareRoot()
        let curvatureDrop  = (horizontalDist * horizontalDist) / (2 * R)

        // Apply curvature correction only for distant points (>5 km).
        let up = (targetAltitude - originAltitude)
               - (horizontalDist > 5_000 ? curvatureDrop : 0)
        return (east, north, up)
    }

    /// Initial bearing from `start` to `end`, in degrees from true north
    /// (clockwise, 0 ≤ bearing < 360).
    static func bearing(from start: CLLocationCoordinate2D,
                        to end: CLLocationCoordinate2D) -> Double {
        let lat1 = start.latitude * .pi / 180
        let lat2 = end.latitude * .pi / 180
        let dLon = (end.longitude - start.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        var b = atan2(y, x) * 180 / .pi
        if b < 0 { b += 360 }
        return b
    }

    /// Project a coordinate forward along a great-circle from `origin`
    /// at the given `bearing` (degrees, 0 = N, clockwise) by `distance`
    /// metres. Spherical-Earth approximation — accurate to <0.1 % over
    /// the 1–200 km ranges the skyline calculator uses.
    static func project(from origin: CLLocationCoordinate2D,
                        bearing degB: Double,
                        distance d: Double,
                        radius R: Double = earthRadius) -> CLLocationCoordinate2D {
        let theta = degB * .pi / 180
        let lat1 = origin.latitude * .pi / 180
        let lon1 = origin.longitude * .pi / 180
        let dR = d / R

        let lat2 = asin(sin(lat1) * cos(dR) + cos(lat1) * sin(dR) * cos(theta))
        let lon2 = lon1 + atan2(sin(theta) * sin(dR) * cos(lat1),
                                cos(dR) - sin(lat1) * sin(lat2))

        return CLLocationCoordinate2D(
            latitude: lat2 * 180 / .pi,
            longitude: ((lon2 * 180 / .pi) + 540).truncatingRemainder(dividingBy: 360) - 180
        )
    }

    /// Apparent altitude angle (radians, positive = above horizontal)
    /// of a target at `targetAltitude` and horizontal `distance` from
    /// an observer at `observerAltitude`. Includes Earth-curvature
    /// drop, which makes a distant peak look lower than its raw
    /// `(target - observer)` height suggests.
    static func apparentAltitudeAngle(observerAltitude: Double,
                                      targetAltitude: Double,
                                      distance: Double,
                                      radius R: Double = earthRadius) -> Double {
        guard distance > 0 else {
            return targetAltitude > observerAltitude ? .pi / 2 : -.pi / 2
        }
        let curvatureDrop = (distance * distance) / (2 * R)
        let apparentRise = (targetAltitude - observerAltitude) - curvatureDrop
        return atan2(apparentRise, distance)
    }
}
