//
//  Geomagnetic.swift
//  Geo
//
//  The Magnetic Conditions core: planetary Kp in, magnetic latitude,
//  auroral-oval reach, compass and GNSS advisories out. Pure and
//  dependency-free (no CoreLocation, no networking, no sensors) so both
//  platforms can run the identical fixture tables against it.
//
//  Kept line-for-line in step with Android
//  `Geo.Android/Geo/src/main/java/me/nettrash/geo/util/Geomagnetic.kt`,
//  the same way `StormWarning` (History.swift) mirrors `sensor/StormWarning.kt`.
//  Every constant, threshold and branch order below comes from the shared
//  parity spec — change one side and you must change the other.
//
//  ── THE HONESTY CONTRACT ────────────────────────────────────────────────
//  This card reports a PUBLISHED planetary index and what it implies for a
//  place on the map. It reports nothing this handset measured. Neither this
//  file nor anything downstream of it may claim:
//
//   1. That Geo measures, observes or otherwise establishes a geomagnetic
//      storm from the device. A phone magnetometer's noise floor is
//      ±190–220 nT and does not average down; the whole G1–G3 mid-latitude
//      signal is 70–330 nT; thermal drift is ±200 nT/K and baseline wander
//      ±1500–2000 nT. The measurement is impossible, not merely imprecise.
//   2. A Kp, ap, K, Dst or SYM-H derived from this device.
//   3. That a field change seen on the device is attributable to space weather.
//   4. An absolute field-strength reading.
//   5. A solar flare or CME, or anything at all about the Sun.
//   6. ANY health, wellness, sleep or mood effect — not hedged, not "some
//      people report", not in an FAQ. The largest study to date (63 M posts
//      across a solar maximum) is a well-powered NULL result.
//   7. A headache line on the card. The one sourced sentence on the subject
//      lives in the explainer sheet and is never promoted to a readout.
//   8. That the aurora verdict forecasts what you will see. No brightness
//      adjective anywhere: the model has no brightness term.
//   9. That the compass figure is a measurement, or a correction to apply.
//  10. GPS degradation quantified in metres on the card.
//  11. That a local declination anomaly is space weather. Crustal anomalies
//      of 3–4° are common and can exceed 10°.
//  12. An aurora verdict from the raw dipole when the grid failed to decode
//      (that is the +5.63° London bug — see `MLatDeltaGrid`).
//  13. A decimal Kp threshold. Kp is thirds; render `kpThirdsLabel`.
//  14. "Official", NOAA branding, or any implied endorsement.
//  15. That R-scale or S-scale events reach a hiker's VHF/UHF handheld, PLB
//      or satellite messenger. Geo shows the G scale only.
//  16. "No network required" for this card.
//
//  Structural guarantee: there is no function in this file that could emit a
//  device-derived index, and no magnetometer API is imported anywhere in the
//  feature.
//

import Foundation

// MARK: - Value types (mirrored by Android data classes / enum classes)

/// Where a Kp value came from in the SWPC product. The raw values are the
/// exact strings SWPC puts in its `observed` field, so the parser maps them
/// straight through. `predicted` is surfaced to the user as "forecast".
enum KpProvenance: String, Sendable, Equatable, Codable {
    case observed
    case estimated
    case predicted
}

/// One 3-hour planetary-Kp bin. `time` is the bin START in UTC.
struct KpPoint: Sendable, Equatable, Codable {
    let time: Date
    let kp: Double
    let provenance: KpProvenance
}

/// A fetched Kp product plus the stamp of when we fetched it. `points` is
/// ALWAYS sorted ascending by `time` — SWPC's own ordering is inconsistent
/// between products, so the parser sorts and nothing downstream may index
/// by array position.
struct KpSeries: Sendable, Equatable, Codable {
    let fetchedAt: Date
    let points: [KpPoint]
}

/// NOAA G scale. `rawValue` is the G number so the UI can render "G3"
/// without a lookup, and `Comparable` lets the rules read `g <= .g2`.
enum GScale: Int, Sendable, Equatable, Comparable, Codable {
    case g0 = 0, g1, g2, g3, g4, g5

    static func < (lhs: GScale, rhs: GScale) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// How far the auroral oval reaches relative to the observer. Deliberately
/// four verdicts and no brightness term — see honesty contract item 8.
enum AuroraVisibility: Sendable, Equatable {
    case unknown        // no Kp, or no magnetic latitude — the row is suppressed
    case notVisible
    case horizonGlow    // the oval is equatorward-of-you by less than the horizon reach
    case ovalReaches
    case overhead
}

/// Coarse band for the storm-time declination offset. Bands, never a number
/// to dial into a compass — honesty contract item 9.
enum CompassBand: Sendable, Equatable {
    case normal
    case underOne
    case oneToTwo
    case twoToFive
    case overFive
}

/// GNSS advisory. Latitude-gated, not G-only — see `gnssHighMLatDeg`.
enum GNSSAdvisory: Sendable, Equatable {
    case nominal
    case mayDegrade
    case degraded
}

/// How old our copy of the Kp product is — and, below the live window,
/// whether it still covers now: `cached` means one of the payload's own bins
/// contains this moment. `expired` still yields magnetic latitude and the Kp
/// threshold for this spot (neither depends on Kp), but never a stale "now"
/// value.
enum Freshness: Sendable, Equatable {
    case live
    case cached
    case expired
    case none
}

// MARK: - AACGM correction grid

/// The bundled AACGM-v2-minus-dipole magnetic-latitude correction table
/// (`mlat_delta_2026.bin`, 4680 bytes, one signed byte of tenths-of-a-degree
/// per node), generated by `tools/gen_mlat_delta.py` and byte-identical to
/// the copy in the Android assets.
///
/// WHY IT EXISTS: the centred dipole is three lines of trigonometry and it is
/// badly wrong exactly where our users are — London dipole 53.34 against
/// AACGM-v2 47.71, i.e. +5.63°, which is 2.5 whole Kp steps. Dipole-only,
/// Geo would promise a hiker in Britain an aurora at about Kp 2.5 when the
/// truth is Kp 5+. If the asset ever fails to decode the app shows NO aurora
/// verdict at all; it must never quietly fall back to the raw dipole.
///
/// LOW-LATITUDE TAPER: the stored correction is smoothstep-tapered to exactly
/// zero below |dipole mlat| 35° (full above 50°), because AACGM-v2 is
/// undefined near the magnetic equator — 150 of the 4680 nodes — and returns
/// wild values just outside that region (−20.6° at 25 °N 0 °E) which would
/// overflow the Int8 encoding. Inside the taper the app therefore shows plain
/// centred-dipole magnetic latitude, which is the only well-defined quantity
/// there and costs nothing: the oval never reaches |mlat| 35 at any Kp, so
/// every tapered location is `notVisible` regardless of the model used.
struct MLatDeltaGrid: Sendable, Equatable {

    /// Row-major signed tenths of a degree, `raw[row * cols + col]`, row =
    /// latitude index from −80°, col = longitude index from −180°.
    let raw: [Int8]

    /// Bundle resource name (no extension) of the shipped grid.
    static let resourceName = "mlat_delta_2026"
    static let resourceExtension = "bin"

    /// Decode a shipped blob. Returns nil unless the input is EXACTLY the
    /// expected byte count — a truncated or padded asset must fail loudly
    /// (no aurora row) rather than silently shift every node by a column.
    static func decode(_ data: Data) -> MLatDeltaGrid? {
        guard data.count == Geomagnetic.mlatGridByteCount else { return nil }
        return MLatDeltaGrid(raw: data.map { Int8(bitPattern: $0) })
    }

    /// Load the grid from a bundle. The only impure entry point in this file,
    /// and it only ever reads a read-only asset we shipped ourselves.
    static func bundled(in bundle: Bundle = .main) -> MLatDeltaGrid? {
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension),
              let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    /// Bilinear correction (degrees) at a geodetic position. Longitude WRAPS
    /// at the antimeridian (so ±180 give bit-identical answers); latitude
    /// CLAMPS to the edge row, because the grid stops at ±80 and the poles
    /// are inside the fully-corrected region anyway.
    func delta(latitude: Double, longitude: Double) -> Double {
        // Guard non-finite input before any Int conversion: `Int(NaN)` traps
        // in Swift. Android guards at exactly this point too — left alone,
        // Kotlin would carry the NaN through the interpolation weights and
        // hand back a NaN correction — so both platforms return a flat 0.
        guard latitude.isFinite, longitude.isFinite else { return 0 }
        let rows = Geomagnetic.mlatGridRows
        let cols = Geomagnetic.mlatGridCols

        let lat = min(max(latitude, -90), 90)
        let fi = (lat - Geomagnetic.mlatGridLatMinDeg) / Geomagnetic.mlatGridLatStepDeg
        let shifted = (longitude - Geomagnetic.mlatGridLonMinDeg).truncatingRemainder(dividingBy: 360)
        let fj = (shifted < 0 ? shifted + 360 : shifted) / Geomagnetic.mlatGridLonStepDeg

        let i0 = min(max(Int(fi.rounded(.down)), 0), rows - 1)
        let i1 = min(max(i0 + 1, 0), rows - 1)
        let ti = min(max(fi - Double(i0), 0), 1)
        let jFloor = Int(fj.rounded(.down))
        let j0 = ((jFloor % cols) + cols) % cols
        let j1 = (j0 + 1) % cols
        let tj = fj - fj.rounded(.down)

        func node(_ i: Int, _ j: Int) -> Double {
            Double(raw[i * cols + j]) * Geomagnetic.mlatGridScaleDeg
        }
        return node(i0, j0) * (1 - ti) * (1 - tj)
             + node(i1, j0) * ti * (1 - tj)
             + node(i0, j1) * (1 - ti) * tj
             + node(i1, j1) * ti * tj
    }
}

// MARK: - Result types

/// What the auroral oval is doing relative to the observer, plus the darkness
/// window that decides whether any of it is worth showing tonight.
struct AuroraOutlook: Sendable, Equatable {
    /// Verdict. `.unknown` whenever Kp or magnetic latitude is missing.
    var visibility: AuroraVisibility = .unknown
    /// |mlat| − oval edge, degrees. Positive = the oval has reached you.
    var marginDeg: Double?
    /// |margin| turned into a distance for the card ("the edge is ~500 km away").
    var rangeKm: Double?
    /// Kp at which this spot first gets a horizon glow, rounded UP to the next
    /// third. Independent of the current Kp, so it survives an expired cache.
    var kpNeededForHorizonGlow: Double?
    /// True bearing to the magnetic pole of the observer's own hemisphere —
    /// which way to look, not where the aurora is.
    var poleBearingDeg: Double?
    var windowStart: Date?
    var windowEnd: Date?
    var hasDarkness: Bool = false
    /// First evening darkness returns, for the polar-summer case where
    /// `hasDarkness` is false.
    var nextDarknessDate: Date?
    var isNorthernHemisphere: Bool = true
}

/// Everything the Magnetic Conditions card renders, in one value.
struct MagneticConditions: Sendable, Equatable {
    /// Kp of the bin covering now. Nil when the cache is expired or empty —
    /// a stale Kp on a card labelled "now" is a lie, so we show nothing.
    var kpNow: Double?
    var kpProvenance: KpProvenance?
    /// Start of the 3-hour bin `kpNow` came from.
    var binStart: Date?
    var gScale: GScale = .g0
    /// Nil ONLY when the correction grid failed to decode (or there is no
    /// position fix). Nil suppresses the magnetic-latitude and aurora rows
    /// entirely — it never falls back to the raw dipole.
    var magneticLatitudeDeg: Double?
    /// Dipole horizontal component at that magnetic latitude. An explainer
    /// for the compass band, never presented as a measured field.
    var horizontalIntensityNT: Double?
    var compass: CompassBand = .normal
    var gnss: GNSSAdvisory = .nominal
    var aurora = AuroraOutlook()
    var freshness: Freshness = .none
    /// Age of our copy of the Kp product at evaluation time.
    var dataAge: TimeInterval?
}

// MARK: - The model

/// Pure geomagnetic math for the Magnetic Conditions card. Byte-identical in
/// behaviour to Android `me.nettrash.geo.util.Geomagnetic`.
enum Geomagnetic {

    // ── Shared constants — MUST match Android Geomagnetic ───────────────

    /// IGRF-14 centred-dipole north pole at epoch 2026.0, computed from the
    /// degree-1 Gauss coefficients shipped inside `aacgmv2` 2.7.1
    /// (g10 = −29350.0 + 12.6, g11 = −1410.3 + 10.0, h11 = 4545.5 − 21.5) and
    /// verified against the grid generator's own output. The 9.1698° tilt this
    /// implies agrees with NCEI's published WMM2025 pole (80.79 °N / 72.76 °W,
    /// tilt ~9.21°) to about 0.04° — close, but NOT "to three decimals";
    /// do not upgrade that claim in a comment, a test or the explainer.
    static let dipolePoleLatDeg = 80.8302
    static let dipolePoleLonDeg = -72.8013
    /// Dipole moment as a surface field strength, sqrt(g10² + g11² + h11²) nT.
    /// Feeds H = B0·cos(mlat) and nothing else.
    static let dipoleMomentNT = 29717.1744

    /// Geometry of `mlat_delta_2026.bin` — 65 latitude rows from −80° in
    /// 2.5° steps by 72 longitude columns from −180° in 5° steps, one signed
    /// byte of tenths of a degree each.
    static let mlatGridLatMinDeg = -80.0
    static let mlatGridLatStepDeg = 2.5
    static let mlatGridLonMinDeg = -180.0
    static let mlatGridLonStepDeg = 5.0
    static let mlatGridRows = 65
    static let mlatGridCols = 72
    static let mlatGridScaleDeg = 0.1
    static let mlatGridByteCount = 4680

    /// NOAA SWPC Aurora Tutorial: the oval's equatorward edge sits at 66.5°
    /// magnetic at Kp 0 and moves about 2° equatorward per Kp step, reaching
    /// 48.1° at Kp 9.
    static let ovalBaseMLatDeg = 66.5
    static let ovalMLatPerKp = 2.0444
    /// NOAA again: "a person can see aurora even when it is 1000 km further
    /// north". 1000 km is 8.99° of latitude; we use 8.0° so the 100 km
    /// emission base stands ~3° above the horizon rather than exactly grazing
    /// it. It also lands Kp 9 on NOAA's own G5 observation of 40° magnetic
    /// (48.1004 − 8.0 = 40.1004).
    static let horizonReachDeg = 8.0
    /// How far inside the oval you must be before the card says "overhead".
    static let overheadMarginDeg = 2.0
    /// Kp is defined on 0…9; anything needing more than this is unreachable.
    static let maxKp = 9.0
    /// 1° of latitude on a sphere of mean radius 6371 km (2πR/360 = 111.195).
    /// Only ever used to turn the oval margin into an approximate distance.
    static let kmPerDegreeLatitude = 111.19
    /// Planetary Kp is published in 3-hour bins.
    static let kpBinHours = 3.0

    /// Dark-sky thresholds, the same numbers as `Solar.astroDarkElevation` /
    /// `Solar.idealDarkElevation` (a test pins them together).
    static let darkElevationDeg = -12.0
    static let idealDarkElevationDeg = -18.0

    /// G-scale boundaries. G is a FLOOR on the INTEGER Kp step: `9−`
    /// (= 8.667) is G4, not G5. Never `round()` a decimal Kp to get G — that
    /// rounding is the classic bug and it has its own named test.
    static let kpG1 = 5.0
    static let kpG2 = 6.0
    static let kpG3 = 7.0
    static let kpG4 = 8.0
    static let kpG5 = 9.0

    /// Order-of-magnitude horizontal-component perturbation by G level, nT,
    /// linearly interpolated on decimal Kp. An order of magnitude is all this
    /// is — never render it to a decimal in the UI.
    static let stormPerturbationNT: [Double] = [0, 100, 200, 400, 800, 1500]

    /// Band edges (degrees) for the storm-time declination offset.
    static let compassBandLowDeg = 1.0
    static let compassBandMidDeg = 2.0
    static let compassBandHighDeg = 5.0

    /// WMM2025 quiet-time declination error model σ_D = sqrt(0.26² +
    /// (5417/H)²) degrees, H in nT. Explainer only: it is the model's own
    /// uncertainty, not a storm effect and not a correction to apply.
    static let declSigmaBaseDeg = 0.26
    static let declSigmaHCoeff = 5417.0

    /// The GNSS advisory is latitude-gated, not G-only: measured
    /// dual-frequency PPP 3D RMS stayed under 0.32 m at mid and low latitude
    /// from quiet conditions through a super-storm, and only high latitude
    /// climbed (0.163 → 1.051 m).
    static let gnssHighMLatDeg = 55.0

    /// ap for each of the 28 Kp thirds, 0 … 9. There is no `9+` step.
    static let apTable: [Int] = [0, 2, 3, 4, 5, 6, 7, 9, 12, 15, 18, 22, 27, 32, 39,
                                 48, 56, 67, 80, 94, 111, 132, 154, 179, 207, 236, 300, 400]

    /// Below this G level the card shows no compass advisory at all.
    static let compassAdvisoryMinG = 3

    /// Kp is published in 3-hour bins, so refetching sooner than that can
    /// only ever return the same numbers at the cost of the user's data.
    static let fetchMinIntervalHours = 3.0
    /// Within two bins the product still describes now even across a bin
    /// rollover, so the live tier keeps the whole `currentPoint` fallback.
    static let liveMaxAgeHours = 6.0
    /// A BACKSTOP, not the expiry rule. What ends a cached copy is its own
    /// forward coverage: the payload is 81 bins spanning −177 h to +62.5 h, so
    /// a fresh copy keeps answering "what is Kp now?" from NOAA's own forecast
    /// for about 65 h and then simply stops containing now. 72 h sits just
    /// beyond that measured reach deliberately — in normal operation coverage
    /// always runs out first, and this cap only ever catches a corrupt or
    /// far-future cache.
    static let cachedMaxAgeHours = 72.0

    /// G1 is the floor for an alert: below it the oval stays north of almost
    /// every user and the notification is noise.
    static let auroraAlertMinKp = 5.0
    /// At most one alert per storm-night, not one per fetch.
    static let auroraAlertCooldownHours = 20.0
    /// How far ahead of darkness an alert is still useful — enough warning to
    /// get somewhere dark, not so much that it is forgotten by nightfall.
    static let auroraAlertDarkLookaheadHours = 6.0

    // ── End of the shared constant block ────────────────────────────────

    /// Kp at which each entry of `stormPerturbationNT` applies: quiet, then
    /// the five G boundaries. Derived so the two tables cannot drift apart.
    private static let perturbationKnotKp: [Double] = [0, kpG1, kpG2, kpG3, kpG4, kpG5]

    /// How far ahead `nextDarkness` will look. The dark-free stretch is
    /// longest at the pole — late January to mid-November, about 285 days —
    /// so a year of lookahead is the smallest bound that always answers.
    static let nextDarknessSearchDays = 366

    // MARK: - Magnetic coordinates

    /// Centred-dipole magnetic latitude (degrees) of a geodetic position.
    /// The geodetic latitude goes straight in, exactly as the grid generator
    /// did it, so the grid also absorbs the geodetic-vs-geocentric difference.
    static func dipoleMagneticLatitude(latitude: Double, longitude: Double) -> Double {
        let poleLat = dipolePoleLatDeg * .pi / 180
        let poleLon = dipolePoleLonDeg * .pi / 180
        let lat = latitude * .pi / 180
        let lon = longitude * .pi / 180
        let s = sin(poleLat) * sin(lat) + cos(poleLat) * cos(lat) * cos(lon - poleLon)
        return asin(min(max(s, -1), 1)) * 180 / .pi
    }

    /// Centred-dipole magnetic longitude (degrees, −180…180). Completes the
    /// coordinate pair; nothing on the card renders it today.
    static func dipoleMagneticLongitude(latitude: Double, longitude: Double) -> Double {
        let poleLat = dipolePoleLatDeg * .pi / 180
        let poleLon = dipolePoleLonDeg * .pi / 180
        let lat = latitude * .pi / 180
        let lon = longitude * .pi / 180
        let y = -cos(lat) * sin(lon - poleLon)
        let x = sin(lat) * cos(poleLat) - cos(lat) * sin(poleLat) * cos(lon - poleLon)
        return atan2(y, x) * 180 / .pi
    }

    /// Corrected (AACGM-v2-equivalent) magnetic latitude. The grid is NOT
    /// optional here on purpose: there is no such thing as a corrected value
    /// without it, and every caller must decide what to do when the asset is
    /// missing rather than inheriting a silently wrong dipole number.
    static func magneticLatitude(latitude: Double, longitude: Double,
                                 grid: MLatDeltaGrid) -> Double {
        dipoleMagneticLatitude(latitude: latitude, longitude: longitude)
            + grid.delta(latitude: latitude, longitude: longitude)
    }

    /// Whether the observer is in the northern MAGNETIC hemisphere, which is
    /// what decides which pole to face — not the geographic sign.
    static func isNorthernMagnetic(latitude: Double, longitude: Double) -> Bool {
        dipoleMagneticLatitude(latitude: latitude, longitude: longitude) >= 0
    }

    /// True bearing (0…360) to the magnetic pole of the observer's own
    /// hemisphere. In the southern magnetic hemisphere it is the northern
    /// bearing turned by exactly 180° — exact on a sphere, since both poles
    /// and the observer share one great circle.
    static func poleBearing(latitude: Double, longitude: Double) -> Double {
        let poleLat = dipolePoleLatDeg * .pi / 180
        let poleLon = dipolePoleLonDeg * .pi / 180
        let lat = latitude * .pi / 180
        let lon = longitude * .pi / 180
        let y = sin(poleLon - lon) * cos(poleLat)
        let x = cos(lat) * sin(poleLat) - sin(lat) * cos(poleLat) * cos(poleLon - lon)
        var bearing = atan2(y, x) * 180 / .pi
        if bearing < 0 { bearing += 360 }
        if !isNorthernMagnetic(latitude: latitude, longitude: longitude) {
            bearing = (bearing + 180).truncatingRemainder(dividingBy: 360)
        }
        return bearing
    }

    /// Dipole horizontal component H = B0·cos(mlat), nT. 19101.8 at 50°,
    /// 11611.4 at 67°. Used only as the denominator of the compass band.
    static func horizontalIntensityNT(magneticLatitudeDeg: Double) -> Double {
        dipoleMomentNT * cos(magneticLatitudeDeg * .pi / 180)
    }

    // MARK: - Auroral oval

    /// Equatorward edge of the oval, in magnetic latitude, at a given Kp.
    static func ovalEdgeMLat(kp: Double) -> Double {
        ovalBaseMLatDeg - ovalMLatPerKp * kp
    }

    /// |mlat| − oval edge. The abs() is what makes the southern hemisphere
    /// need no special case at all.
    static func margin(magneticLatitudeDeg: Double, kp: Double) -> Double {
        abs(magneticLatitudeDeg) - ovalEdgeMLat(kp: kp)
    }

    /// Approximate distance to the oval edge for the card.
    static func rangeKm(marginDeg: Double) -> Double {
        abs(marginDeg) * kmPerDegreeLatitude
    }

    static func visibility(marginDeg: Double) -> AuroraVisibility {
        if marginDeg >= overheadMarginDeg { return .overhead }
        if marginDeg >= 0 { return .ovalReaches }
        if marginDeg >= -horizonReachDeg { return .horizonGlow }
        return .notVisible
    }

    static func visibility(magneticLatitudeDeg: Double, kp: Double) -> AuroraVisibility {
        visibility(marginDeg: margin(magneticLatitudeDeg: magneticLatitudeDeg, kp: kp))
    }

    /// Lowest Kp at which this spot gets a horizon glow, rounded UP to the
    /// next third of a Kp step (Kp only exists in thirds, and rounding DOWN
    /// would promise an aurora the oval cannot deliver). Nil above Kp 9.
    static func kpNeededForHorizonGlow(magneticLatitudeDeg: Double) -> Double? {
        let raw = (ovalBaseMLatDeg - horizonReachDeg - abs(magneticLatitudeDeg)) / ovalMLatPerKp
        let needed = (max(raw, 0) * 3).rounded(.up) / 3
        return needed > maxKp ? nil : needed
    }

    /// Card copy for that threshold. Never a decimal — honesty contract 13.
    static func requiredKpLabel(magneticLatitudeDeg: Double) -> String? {
        guard let needed = kpNeededForHorizonGlow(magneticLatitudeDeg: magneticLatitudeDeg) else {
            return nil
        }
        return needed <= 0 ? "any night" : "about Kp " + kpThirdsLabel(needed)
    }

    // MARK: - Kp, ap and the G scale

    /// Kp in thirds, 0…27, which is the only resolution Kp actually has.
    static func kpStep(_ kp: Double) -> Int {
        guard kp.isFinite else { return 0 }
        return min(max(Int((kp * 3).rounded()), 0), apTable.count - 1)
    }

    static func ap(kp: Double) -> Int {
        apTable[kpStep(kp)]
    }

    /// "0", "0+", "1-", … "9-", "9". A `+` is a third above the integer, a
    /// `-` is a third below the NEXT integer — 8.667 renders "9-", not "8++".
    static func kpThirdsLabel(_ kp: Double) -> String {
        let step = kpStep(kp)
        let whole = step / 3
        switch step % 3 {
        case 0: return "\(whole)"
        case 1: return "\(whole)+"
        default: return "\(whole + 1)-"
        }
    }

    /// G is a FLOOR on the integer Kp step, so `9−` (8.667) is G4. The 1e-6
    /// slack only absorbs the binary representation of 9.0 itself.
    static func gScale(kp: Double) -> GScale {
        if kp >= kpG5 - 1e-6 { return .g5 }
        if kp >= kpG4 { return .g4 }
        if kp >= kpG3 { return .g3 }
        if kp >= kpG2 { return .g2 }
        if kp >= kpG1 { return .g1 }
        return .g0
    }

    /// Order-of-magnitude horizontal perturbation at a decimal Kp, nT,
    /// linearly interpolated between the G knots and clamped at both ends.
    static func disturbanceNT(kp: Double) -> Double {
        guard let firstKnot = perturbationKnotKp.first,
              let lastKnot = perturbationKnotKp.last,
              let firstValue = stormPerturbationNT.first,
              let lastValue = stormPerturbationNT.last else { return 0 }
        if kp <= firstKnot { return firstValue }
        if kp >= lastKnot { return lastValue }
        for i in 1..<perturbationKnotKp.count where kp <= perturbationKnotKp[i] {
            let lower = perturbationKnotKp[i - 1]
            let t = (kp - lower) / (perturbationKnotKp[i] - lower)
            return stormPerturbationNT[i - 1] + t * (stormPerturbationNT[i] - stormPerturbationNT[i - 1])
        }
        return lastValue
    }

    /// Angular offset a storm of this size implies for a compass needle at
    /// this H, degrees: atan(dB / H). An ILLUSTRATION of the size of the
    /// effect, not a measurement and not a correction to dial in.
    static func compassOffsetDeg(kp: Double, horizontalIntensityNT h: Double) -> Double {
        guard h > 0 else { return 0 }
        return atan(disturbanceNT(kp: kp) / h) * 180 / .pi
    }

    /// Compass band. Below G3 there is no advisory at all, whatever the
    /// arithmetic says — the effect is smaller than a phone compass's own
    /// error and claiming otherwise would be honesty contract item 9.
    static func compassBand(kp: Double, horizontalIntensityNT h: Double) -> CompassBand {
        guard gScale(kp: kp).rawValue >= compassAdvisoryMinG else { return .normal }
        let theta = compassOffsetDeg(kp: kp, horizontalIntensityNT: h)
        if theta < compassBandLowDeg { return .underOne }
        if theta < compassBandMidDeg { return .oneToTwo }
        if theta < compassBandHighDeg { return .twoToFive }
        return .overFive
    }

    /// WMM2025 quiet-time declination uncertainty at this H, degrees. The
    /// FORMULA is authoritative; the prose roundings (~0.36° at H 20000,
    /// ~0.60° at H 10000) are not — do not "fix" the constants to match them.
    static func declinationSigmaDeg(horizontalIntensityNT h: Double) -> Double {
        guard h > 0 else { return declSigmaBaseDeg }
        let ratio = declSigmaHCoeff / h
        return (declSigmaBaseDeg * declSigmaBaseDeg + ratio * ratio).squareRoot()
    }

    /// GNSS advisory, in the spec's own branch order: below G3 nothing is
    /// said at all, then G3–G4 and G5 each apply the latitude gate, and the
    /// missing-latitude case comes last — without a magnetic latitude the
    /// gate cannot be applied, so we say nominal rather than guess.
    static func gnssAdvisory(gScale g: GScale, magneticLatitudeDeg: Double?) -> GNSSAdvisory {
        if g <= .g2 { return .nominal }
        if let mlat = magneticLatitudeDeg {
            let high = abs(mlat) >= gnssHighMLatDeg
            if g <= .g4 { return high ? .mayDegrade : .nominal }
            return high ? .degraded : .mayDegrade
        }
        return .nominal
    }

    // MARK: - Freshness and the current bin

    /// How much to trust a copy of this age. Below the live window the gate is
    /// COVERAGE, not the clock: a cached copy is good for exactly as long as
    /// one of its own bins still contains now, which is what turns a three-day
    /// forecast into three days of offline answers. `cachedMaxAgeHours` is the
    /// backstop behind that, for a corrupt or far-future cache.
    static func freshness(dataAge: TimeInterval?, hasCoveringBin: Bool) -> Freshness {
        guard let age = dataAge else { return .none }
        if age <= liveMaxAgeHours * 3600 { return .live }
        if hasCoveringBin, age <= cachedMaxAgeHours * 3600 { return .cached }
        return .expired
    }

    /// The bin that strictly CONTAINS now — `now >= start` and `now < start +
    /// kpBinHours`. Tier 1 of `currentPoint`, lifted out because freshness and
    /// `conditions` both need to ask it: it is the difference between a copy
    /// that still describes this moment and one that merely used to. Nil when
    /// no bin covers now.
    static func coveringPoint(in points: [KpPoint], now: Date) -> KpPoint? {
        let bin = kpBinHours * 3600
        return points.sorted { $0.time < $1.time }
                     .last { $0.time <= now && now < $0.time.addingTimeInterval(bin) }
    }

    /// The Kp bin that describes "now", in this order: the newest bin that
    /// CONTAINS now; else the newest observed/estimated bin at or before now;
    /// else — for a cache older than its own observed tail — the newest
    /// predicted bin covering now. Never by array position: SWPC's ordering
    /// is not something to rely on.
    static func currentPoint(in points: [KpPoint], now: Date) -> KpPoint? {
        if let containing = coveringPoint(in: points, now: now) {
            return containing
        }
        let sorted = points.sorted { $0.time < $1.time }
        if let past = sorted.last(where: { $0.time <= now && $0.provenance != .predicted }) {
            return past
        }
        return sorted.last { $0.provenance == .predicted && $0.time <= now }
    }

    // MARK: - Darkness

    /// The dark window that matters right now: the one already under way if
    /// there is one, otherwise tonight's. Asking only for "today's" window is
    /// the classic bug — at 02:00 the window under way began yesterday
    /// evening, and a naive lookup would report darkness as ~17 hours off and
    /// suppress the alert while the sky is at its darkest.
    static func darkWindow(latitude: Double, longitude: Double,
                           now: Date, calendar: Calendar) -> Solar.NightWindow? {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)
                     ?? now.addingTimeInterval(-86_400)
        if let previous = Solar.nightWindow(date: yesterday, latitude: latitude,
                                            longitude: longitude, calendar: calendar),
           previous.end > now {
            return previous
        }
        return Solar.nightWindow(date: now, latitude: latitude,
                                 longitude: longitude, calendar: calendar)
    }

    /// When darkness next returns, for the polar-summer case. Nil if it does
    /// not inside the search horizon.
    static func nextDarkness(latitude: Double, longitude: Double,
                             now: Date, calendar: Calendar) -> Date? {
        for day in 1...nextDarknessSearchDays {
            guard let probe = calendar.date(byAdding: .day, value: day, to: now) else { continue }
            if let window = Solar.nightWindow(date: probe, latitude: latitude,
                                              longitude: longitude, calendar: calendar) {
                return window.start
            }
        }
        return nil
    }

    // MARK: - Aggregation

    /// The aurora half of the card. `magneticLatitudeDeg` nil (grid failed to
    /// decode, or no fix) suppresses every oval field; `kp` nil (expired
    /// cache) suppresses only the ones that depend on the current storm, so
    /// "you need about Kp 5+ here" survives going offline.
    static func auroraOutlook(magneticLatitudeDeg: Double?,
                              kp: Double?,
                              latitude: Double?,
                              longitude: Double?,
                              now: Date,
                              calendar: Calendar) -> AuroraOutlook {
        var outlook = AuroraOutlook()

        if let lat = latitude, let lon = longitude {
            outlook.isNorthernHemisphere = isNorthernMagnetic(latitude: lat, longitude: lon)
            outlook.poleBearingDeg = poleBearing(latitude: lat, longitude: lon)
            if let window = darkWindow(latitude: lat, longitude: lon, now: now, calendar: calendar) {
                outlook.windowStart = window.start
                outlook.windowEnd = window.end
                outlook.hasDarkness = true
            } else {
                outlook.nextDarknessDate = nextDarkness(latitude: lat, longitude: lon,
                                                        now: now, calendar: calendar)
            }
        }

        guard let mlat = magneticLatitudeDeg else { return outlook }
        outlook.kpNeededForHorizonGlow = kpNeededForHorizonGlow(magneticLatitudeDeg: mlat)

        guard let kp else { return outlook }
        let marginDeg = margin(magneticLatitudeDeg: mlat, kp: kp)
        outlook.marginDeg = marginDeg
        outlook.rangeKm = rangeKm(marginDeg: marginDeg)
        outlook.visibility = visibility(marginDeg: marginDeg)
        return outlook
    }

    /// Everything the card shows, from a Kp series and a position. Pure: the
    /// clock and the calendar are injected so the fixtures run identically on
    /// both platforms and in any device time zone.
    static func conditions(series: KpSeries?,
                           latitude: Double?,
                           longitude: Double?,
                           grid: MLatDeltaGrid?,
                           now: Date = Date(),
                           calendar: Calendar = .current) -> MagneticConditions {
        var result = MagneticConditions()

        // Freshness first, because everything Kp-derived is gated on it. An
        // empty product is "none", not "live with no value".
        let points = series?.points ?? []
        let dataAge: TimeInterval? = points.isEmpty
            ? nil
            : series.map { now.timeIntervalSince($0.fetchedAt) }
        let covering = coveringPoint(in: points, now: now)
        result.dataAge = dataAge
        result.freshness = freshness(dataAge: dataAge, hasCoveringBin: covering != nil)

        // The tier picks the bin. Live keeps the 3-tier fallback: a copy
        // fetched minutes ago describes now even at a bin rollover. Cached is
        // strict — it exists only BECAUSE a bin covers now, so presenting any
        // other bin as "now" would be the stale-Kp lie the tier prevents.
        let point: KpPoint?
        switch result.freshness {
        case .live: point = currentPoint(in: points, now: now)
        case .cached: point = covering
        case .expired, .none: point = nil
        }

        if let point {
            // Kp is DEFINED on 0…9, so a corrupt cache or a malformed row is
            // clamped here rather than at every use site downstream — an
            // out-of-range value would otherwise reach the ap lookup and the
            // compass band. Android clamps in the same place.
            let kp = min(max(point.kp, 0), maxKp)
            result.kpNow = kp
            result.kpProvenance = point.provenance
            result.binStart = point.time
            result.gScale = gScale(kp: kp)
        }

        if let lat = latitude, let lon = longitude, let grid {
            let mlat = magneticLatitude(latitude: lat, longitude: lon, grid: grid)
            result.magneticLatitudeDeg = mlat
            result.horizontalIntensityNT = horizontalIntensityNT(magneticLatitudeDeg: mlat)
        }

        if let kp = result.kpNow, let h = result.horizontalIntensityNT {
            result.compass = compassBand(kp: kp, horizontalIntensityNT: h)
        }
        result.gnss = gnssAdvisory(gScale: result.gScale,
                                   magneticLatitudeDeg: result.magneticLatitudeDeg)
        result.aurora = auroraOutlook(magneticLatitudeDeg: result.magneticLatitudeDeg,
                                      kp: result.kpNow,
                                      latitude: latitude, longitude: longitude,
                                      now: now, calendar: calendar)
        return result
    }
}

// MARK: - Opt-in aurora alert

/// The alert gate. Pure — no notification framework, no I/O — so every "we
/// must not wake the user for this" rule is a unit test rather than a manual
/// check. The caller owns scheduling and the `lastNotifiedAt` stamp.
enum AuroraAlert {

    /// True only when every one of these holds: the user opted in; our Kp is
    /// live or cached; Kp is at least 5; the oval reaches at least the
    /// horizon; there is darkness, and it is under way or starts within 6 h;
    /// and we have not already sent one inside the 20 h cooldown.
    ///
    /// There is no separate alert age cap. The alert is allowed whenever a
    /// NOAA bin still covers this moment, which is exactly what LIVE-or-
    /// CACHED means, and how stale that copy may be is already bounded by
    /// `cachedMaxAgeHours`. So a multi-day walk-in can still be told about a
    /// storm from the copy fetched at the trailhead — which is what a
    /// three-day forecast is for, and the notification already says
    /// "forecast".
    static func shouldNotify(conditions: MagneticConditions,
                             enabled: Bool,
                             lastNotifiedAt: Date?,
                             now: Date) -> Bool {
        guard enabled else { return false }

        guard conditions.freshness == .live || conditions.freshness == .cached else { return false }

        guard let kp = conditions.kpNow, kp >= Geomagnetic.auroraAlertMinKp else { return false }

        let visibility = conditions.aurora.visibility
        guard visibility != .unknown, visibility != .notVisible else { return false }

        guard conditions.aurora.hasDarkness,
              let start = conditions.aurora.windowStart,
              let end = conditions.aurora.windowEnd,
              end > now,
              start <= now.addingTimeInterval(Geomagnetic.auroraAlertDarkLookaheadHours * 3600)
        else { return false }

        if let last = lastNotifiedAt,
           now.timeIntervalSince(last) < Geomagnetic.auroraAlertCooldownHours * 3600 {
            return false
        }
        return true
    }
}
