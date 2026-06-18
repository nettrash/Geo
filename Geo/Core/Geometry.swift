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

    /// Great-circle (haversine) distance in metres between two coordinates.
    /// Kept identical to Android `GeoCalculations.distanceBetween` so trip
    /// distances match across platforms.
    static func distanceBetween(lat1: Double, lon1: Double,
                                lat2: Double, lon2: Double,
                                radius R: Double = earthRadius) -> Double {
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
              + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(a.squareRoot(), (1 - a).squareRoot())
        return R * c
    }

    /// 8-point compass labels, hoisted so `cardinalDirection` doesn't
    /// re-allocate the array on every (per-heading-update) call.
    private static let cardinalLabels = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

    /// 8-point compass abbreviation (N / NE / E / SE / S / SW / W / NW) for a
    /// bearing in degrees from true north. Kept identical to Android
    /// `GeoCalculations.cardinalDirection`.
    static func cardinalDirection(_ bearingDeg: Double) -> String {
        // Guard non-finite input before the integer conversion: `Int(NaN)`
        // traps in Swift. (Android maps NaN→0→"N" via the JVM cast; make
        // both explicit and identical.)
        guard bearingDeg.isFinite else { return "N" }
        let normalized = bearingDeg.truncatingRemainder(dividingBy: 360)
        let positive = (normalized + 360).truncatingRemainder(dividingBy: 360)
        let index = Int((positive + 22.5).truncatingRemainder(dividingBy: 360) / 45)
        return cardinalLabels[index % 8]
    }
}

// MARK: - Solar position & day-window math (NOAA / Meeus)

/// Pure, on-device solar-event math — sunrise / sunset / golden & blue
/// hour / civil twilight / solar noon — for an exact position and
/// altitude. Implements the NOAA solar-position algorithm (after Meeus);
/// kept byte-identical to Android `me.nettrash.geo.util.Solar`.
///
/// The core `…UTCMinutes` functions are pure (Int date + Double position
/// → Double minutes past 00:00 UTC) so they unit-test deterministically
/// and match across platforms; `times(…)` is the thin Foundation wrapper
/// that turns them into `Date`s for the UI.
enum Solar {

    /// Sun-centre geometric elevation (deg) at apparent sunrise/sunset.
    /// −0.833° folds in mean refraction (~34′) and the solar semidiameter
    /// (~16′); the altitude horizon-dip is added on top per observer.
    static let sunriseElevation = -0.833
    /// Civil twilight / blue-hour outer edge: sun centre 6° below horizon.
    static let civilElevation = -6.0
    /// Golden-hour band: sun between −4° and +6°.
    static let goldenLowerElevation = -4.0
    static let goldenUpperElevation = 6.0

    /// Geographic horizon dip (degrees) for an observer `h` m above MSL,
    /// reusing `Geometry.horizonDistance`: `dip = atan(d / R)`. Makes the
    /// sun rise earlier / set later from a summit. Zero at/below sea level.
    static func horizonDipDegrees(altitude h: Double) -> Double {
        guard h > 0 else { return 0 }
        return atan(Geometry.horizonDistance(observerAltitude: h) / Geometry.earthRadius) * 180 / .pi
    }

    /// Julian Day at 00:00 UTC of the given Gregorian calendar date.
    static func julianDay(year: Int, month: Int, day: Int) -> Double {
        var y = year
        var m = month
        if m <= 2 { y -= 1; m += 12 }
        let a = (Double(y) / 100).rounded(.down)
        let b = 2 - a + (a / 4).rounded(.down)
        return (365.25 * (Double(y) + 4716)).rounded(.down)
             + (30.6001 * (Double(m) + 1)).rounded(.down)
             + Double(day) + b - 1524.5
    }

    /// Sun declination (radians) and the equation of time (minutes) for
    /// Julian century `t`. NOAA formulae.
    private static func sunPosition(julianCentury t: Double) -> (declination: Double, eqTimeMinutes: Double) {
        let l0 = (280.46646 + t * (36000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
        let m = 357.52911 + t * (35999.05029 - 0.0001537 * t)
        let e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let mRad = m * .pi / 180
        let c = sin(mRad) * (1.914602 - t * (0.004817 + 0.000014 * t))
              + sin(2 * mRad) * (0.019993 - 0.000101 * t)
              + sin(3 * mRad) * 0.000289
        let trueLong = l0 + c
        let omega = (125.04 - 1934.136 * t) * .pi / 180
        let lambda = (trueLong - 0.00569 - 0.00478 * sin(omega)) * .pi / 180
        let epsilon0 = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let epsilon = (epsilon0 + 0.00256 * cos(omega)) * .pi / 180
        let declination = asin(sin(epsilon) * sin(lambda))
        let l0Rad = l0 * .pi / 180
        let y = tan(epsilon / 2) * tan(epsilon / 2)
        let eqTimeRad = y * sin(2 * l0Rad)
                      - 2 * e * sin(mRad)
                      + 4 * e * y * sin(mRad) * cos(2 * l0Rad)
                      - 0.5 * y * y * sin(4 * l0Rad)
                      - 1.25 * e * e * sin(2 * mRad)
        let eqTimeMinutes = 4 * eqTimeRad * 180 / .pi
        return (declination, eqTimeMinutes)
    }

    /// Julian century for the date's approximate local solar noon (good
    /// enough — declination / equation-of-time vary negligibly across the
    /// half-day from this estimate).
    private static func julianCentury(year: Int, month: Int, day: Int, longitude: Double) -> Double {
        let jdNoon = julianDay(year: year, month: month, day: day) + 0.5 - longitude / 360
        return (jdNoon - 2451545.0) / 36525.0
    }

    /// Minutes past 00:00 UTC of solar noon at `longitude` on the date.
    static func solarNoonUTCMinutes(year: Int, month: Int, day: Int, longitude: Double) -> Double {
        let t = julianCentury(year: year, month: month, day: day, longitude: longitude)
        let eq = sunPosition(julianCentury: t).eqTimeMinutes
        return 720 - 4 * longitude - eq
    }

    /// Minutes past 00:00 UTC when the sun centre is at `elevationDeg`
    /// (geometric) for the given date and position. `rising` selects the
    /// morning (true) or evening (false) crossing. `nil` when the sun
    /// never reaches that elevation that day (polar day / night).
    static func eventUTCMinutes(year: Int, month: Int, day: Int,
                                latitude: Double, longitude: Double,
                                elevationDeg: Double, rising: Bool) -> Double? {
        let t = julianCentury(year: year, month: month, day: day, longitude: longitude)
        let pos = sunPosition(julianCentury: t)
        let latRad = latitude * .pi / 180
        let elevRad = elevationDeg * .pi / 180
        let cosH = (sin(elevRad) - sin(latRad) * sin(pos.declination))
                 / (cos(latRad) * cos(pos.declination))
        if cosH > 1 || cosH < -1 { return nil }
        let haMinutes = 4 * acos(cosH) * 180 / .pi
        let noon = 720 - 4 * longitude - pos.eqTimeMinutes
        return rising ? noon - haMinutes : noon + haMinutes
    }

    /// Sun elevation (deg) at solar noon — disambiguates polar day (sun
    /// always up) from polar night (sun always down).
    static func noonElevationDeg(year: Int, month: Int, day: Int, latitude: Double, longitude: Double) -> Double {
        let t = julianCentury(year: year, month: month, day: day, longitude: longitude)
        let decl = sunPosition(julianCentury: t).declination
        let latRad = latitude * .pi / 180
        return asin(sin(latRad) * sin(decl) + cos(latRad) * cos(decl)) * 180 / .pi
    }
}

extension Solar {

    /// Resolved solar windows for one day at one position. All `Date`s are
    /// absolute instants (UTC under the hood) — format them in any time
    /// zone. `nil` fields mean that crossing doesn't occur that day.
    struct Times {
        var civilDawn: Date?          // sun −6° rising
        var goldenDawn: Date?         // sun −4° rising  (morning golden start / blue end)
        var sunrise: Date?            // sun −0.833°−dip rising
        var goldenMorningEnd: Date?   // sun +6° rising  (morning golden end)
        var solarNoon: Date?
        var goldenEveningStart: Date? // sun +6° falling (evening golden start)
        var sunset: Date?             // sun −0.833°−dip falling
        var goldenDusk: Date?         // sun −4° falling (evening golden end / blue start)
        var civilDusk: Date?          // sun −6° falling
        var dayLength: TimeInterval?
        var noonElevationDeg: Double = 0
        var isPolarDay: Bool = false
        var isPolarNight: Bool = false
    }

    /// Build the day's solar windows for `date` at the observer's position
    /// and `altitude` (used for the horizon dip on sunrise/sunset). The
    /// calendar's time zone selects which calendar day "today" is.
    static func times(date: Date, latitude: Double, longitude: Double, altitude: Double,
                      calendar: Calendar = .current) -> Times {
        // Anchor the solar day to LOCAL NOON, then take that instant's UTC
        // calendar date. Anchoring directly to UTC-midnight of the local
        // date would shift every event by a day in far-east clock zones
        // (UTC+13/+14, west of the date line: Samoa / Kiritimati / Chatham),
        // where the local day's solar events fall on the previous UTC date.
        let localComps = calendar.dateComponents([.year, .month, .day], from: date)
        guard let ly = localComps.year, let lm = localComps.month, let ld = localComps.day,
              let localNoon = calendar.date(from: DateComponents(year: ly, month: lm, day: ld, hour: 12)) else {
            return Times()
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let comps = utc.dateComponents([.year, .month, .day], from: localNoon)
        guard let year = comps.year, let month = comps.month, let day = comps.day,
              let utcMidnight = utc.date(from: DateComponents(year: year, month: month, day: day)) else {
            return Times()
        }
        func toDate(_ minutes: Double?) -> Date? { minutes.map { utcMidnight.addingTimeInterval($0 * 60) } }
        func event(_ elevation: Double, _ rising: Bool) -> Double? {
            eventUTCMinutes(year: year, month: month, day: day,
                            latitude: latitude, longitude: longitude,
                            elevationDeg: elevation, rising: rising)
        }

        let riseSetElevation = sunriseElevation - horizonDipDegrees(altitude: altitude)

        var t = Times()
        t.civilDawn = toDate(event(civilElevation, true))
        t.goldenDawn = toDate(event(goldenLowerElevation, true))
        t.sunrise = toDate(event(riseSetElevation, true))
        t.goldenMorningEnd = toDate(event(goldenUpperElevation, true))
        t.solarNoon = toDate(solarNoonUTCMinutes(year: year, month: month, day: day, longitude: longitude))
        t.goldenEveningStart = toDate(event(goldenUpperElevation, false))
        t.sunset = toDate(event(riseSetElevation, false))
        t.goldenDusk = toDate(event(goldenLowerElevation, false))
        t.civilDusk = toDate(event(civilElevation, false))
        if let sunrise = t.sunrise, let sunset = t.sunset {
            t.dayLength = sunset.timeIntervalSince(sunrise)
        }
        t.noonElevationDeg = noonElevationDeg(year: year, month: month, day: day,
                                              latitude: latitude, longitude: longitude)
        if t.sunrise == nil && t.sunset == nil {
            if t.noonElevationDeg > riseSetElevation { t.isPolarDay = true } else { t.isPolarNight = true }
        }
        return t
    }
}
