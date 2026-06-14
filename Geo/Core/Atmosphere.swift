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
}
