//
//  Atmosphere.swift
//  Geo
//
//  Created by Ivan Alekseev on 13/06/2026.
//  Copyright © 2026 NETTRASH. All rights reserved.
//

import Foundation

/// Shared barometric helpers for the pressure-derived altitude fallback.
///
/// All pressures are in kilopascals (kPa); standard sea level is
/// 101.325 kPa. Used only when Apple's calibrated absolute-altitude
/// stream isn't available — it replaces the older crude
/// `log(101.325 / p) / 0.00012` isothermal estimate with the
/// international-barometric-formula (lapse-rate) approximation, which
/// tracks the real standard atmosphere more closely.
enum Atmosphere {
    static let seaLevelKPa = 101.325

    /// Height of Mt. Everest above sea level in metres (the modern
    /// 2020 China/Nepal joint survey figure). Used as the upper bound
    /// of the "Everest progress" gauges and the `everest` fraction.
    static let everestHeightM = 8848.86

    /// Barometric (lapse-rate) altitude in metres for a pressure reading,
    /// clamped to a sane window first (Improvement #11: 300–1100 hPa = 30–110 kPa).
    static func altitude(pressureKPa p: Double, referenceKPa p0: Double = seaLevelKPa) -> Double {
        let pc = min(max(p, 30.0), 110.0); let p0c = min(max(p0, 30.0), 110.0)
        return 44330.0 * (1.0 - pow(pc / p0c, 1.0 / 5.255))
    }

    /// Linear-decay window (hours) for a manual "I am at X m" calibration.
    /// The offset is fully applied when fresh and decays to zero over this
    /// window, so a stale calibration can't silently re-bias as weather drifts.
    static let calibrationDecayHours = 6.0

    /// Inverse of `altitude(pressureKPa:referenceKPa:)`: the sea-level
    /// reference pressure (kPa) that makes the lapse-rate formula output
    /// `knownAltitudeM` for the given live station pressure. The exact
    /// algebraic inverse — `p0 = p / (1 − h/44330)^5.255` — so a value fed
    /// back into the forward helper reproduces the entered altitude. Kept
    /// identical to Android `Atmosphere.solveReferencePressure`.
    static func solveReferencePressure(knownAltitudeM h: Double, livePressureKPa p: Double) -> Double {
        let pc = min(max(p, 30.0), 110.0)
        let base = 1.0 - h / 44330.0
        guard base > 0 else { return seaLevelKPa }   // h < 44330 m always on Earth
        return pc / pow(base, 5.255)
    }

    /// Weight in [0, 1] of a calibration of age `ageSeconds`: 1 when fresh,
    /// decaying linearly to 0 at `calibrationDecayHours`.
    static func calibrationWeight(ageSeconds: Double) -> Double {
        guard ageSeconds > 0 else { return 1.0 }
        return min(max(1.0 - ageSeconds / (calibrationDecayHours * 3600), 0.0), 1.0)
    }

    /// App-group `UserDefaults` keys for the manual "I am at X m" calibration.
    /// Defined here — in a file compiled into both the app and the widget
    /// target — so `Barometer` and the widget read/write the same store and
    /// can't drift on key names.
    static let calibrationOffsetKey = "BarometerCalibrationOffset"
    static let calibrationAtKey = "BarometerCalibratedAt"

    /// The decayed manual-calibration offset (m) currently persisted in the
    /// app group named `suiteName`, or 0 when none is set / it has fully
    /// decayed. Lets the widget apply the same "I am at X m" pin the main app
    /// shows, so the two surfaces agree on altitude (the v1.1 theme).
    static func persistedCalibrationOffset(suiteName: String, now: Date = Date()) -> Double {
        guard let ud = UserDefaults(suiteName: suiteName),
              let at = ud.object(forKey: calibrationAtKey) as? Date else { return 0 }
        let offset = ud.double(forKey: calibrationOffsetKey)
        return offset * calibrationWeight(ageSeconds: now.timeIntervalSince(at))
    }
}
