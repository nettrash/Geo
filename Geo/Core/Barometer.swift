//
//  Barometer.swift
//  Geo
//
//  Created by Ivan Alekseev on 24/05/2019.
//  Copyright © 2019 NETTRASH. All rights reserved.
//

import Foundation
import CoreMotion

@Observable
class Barometer {

    private var barometerManager: CMAltimeter!

    /// Relative altitude updates available (pressure + change since
    /// the stream was started).
    let available: Bool

    /// Apple-calibrated absolute altitude (MSL) updates available.
    /// Requires iOS 15+, an iPhone with a barometer, and location
    /// permission. Uses Apple's location-tagged sea-level-pressure
    /// data to compensate for weather, so the value tracks real MSL
    /// altitude rather than the pressure-derived estimate.
    let absoluteAvailable: Bool

    /// Most recent absolute pressure in kPa.
    var pressure: Double
    /// Change in altitude (m) since the stream was started.
    var delta: Double
    /// Altitude above mean sea level in metres.
    ///
    /// When `absoluteAvailable` is true and at least one absolute
    /// reading has arrived, this is Apple's calibrated MSL altitude.
    /// Otherwise it falls back to the isothermal-standard-atmosphere
    /// approximation derived from raw pressure — accurate to roughly
    /// ±100–500 m depending on weather and temperature.
    var height: Double
    /// Mt. Everest progress in the [0, 1] sense — `height / 8848`.
    var everest: Double
    /// 1-sigma uncertainty (m) of `height` reported by the absolute
    /// altitude stream. Zero when the fallback formula is in use.
    var heightAccuracy: Double

    var dataUpdated: (() -> Void)?

    /// True once at least one absolute-altitude callback has landed.
    /// Until that happens we keep refreshing `height` from the
    /// pressure-derived formula so the value isn't stuck at zero on
    /// launch.
    private var hasAbsoluteFix: Bool = false

    init() {
        barometerManager = CMAltimeter()
        pressure = 0
        delta = 0
        height = 0
        everest = 0
        heightAccuracy = 0
        available = CMAltimeter.isRelativeAltitudeAvailable()
        if #available(iOS 15.0, *) {
            absoluteAvailable = CMAltimeter.isAbsoluteAltitudeAvailable()
        } else {
            absoluteAvailable = false
        }
    }

    init(autoStart: Bool) {
        barometerManager = CMAltimeter()
        pressure = 0
        delta = 0
        height = 0
        everest = 0
        heightAccuracy = 0
        available = CMAltimeter.isRelativeAltitudeAvailable()
        if #available(iOS 15.0, *) {
            absoluteAvailable = CMAltimeter.isAbsoluteAltitudeAvailable()
        } else {
            absoluteAvailable = false
        }
        if autoStart {
            Start()
        }
    }

    init(_ handler: @escaping (() -> Void)) {
        barometerManager = CMAltimeter()
        pressure = 0
        delta = 0
        height = 0
        everest = 0
        heightAccuracy = 0
        available = CMAltimeter.isRelativeAltitudeAvailable()
        if #available(iOS 15.0, *) {
            absoluteAvailable = CMAltimeter.isAbsoluteAltitudeAvailable()
        } else {
            absoluteAvailable = false
        }
        dataUpdated = handler
    }

    func Start() {
        if available {
            barometerManager.startRelativeAltitudeUpdates(to: OperationQueue.main, withHandler: self.Handler(_:_:))
        }
        if #available(iOS 15.0, *), absoluteAvailable {
            barometerManager.startAbsoluteAltitudeUpdates(to: OperationQueue.main, withHandler: self.AbsoluteHandler(_:_:))
        }
    }

    func Stop() {
        if available {
            barometerManager.stopRelativeAltitudeUpdates()
        }
        if #available(iOS 15.0, *), absoluteAvailable {
            barometerManager.stopAbsoluteAltitudeUpdates()
        }
    }

    func Handler(_ data: CMAltitudeData?, _ error: Error?) {
        guard let data = data else { return }
        self.pressure = data.pressure.doubleValue
        self.delta = data.relativeAltitude.doubleValue

        // Fall back to the pressure-derived formula only when the
        // calibrated absolute stream isn't running (older OS / device
        // without a barometer) or hasn't delivered its first reading
        // yet. The formula assumes standard sea-level pressure
        // (101.325 kPa) and an isothermal atmosphere — useful as a
        // bootstrap value, but biased by 100–500 m in real weather,
        // so we let the absolute reading overwrite it as soon as one
        // arrives.
        if !absoluteAvailable || !hasAbsoluteFix {
            //Ph = P0 * exp(-0.00012 * h)
            //exp(-0.00012 * h) = Ph / P0
            //-0.00012 * h = ln( Ph / P0 )
            //ln( P0 / Ph ) = 0.00012 * h
            // h = ln ( P0 / Ph ) / 0.00012
            // P0 = 101.325
            let P0: Double = 101.325
            let Ph: Double = data.pressure.doubleValue
            let h: Double = log(P0 / Ph) / 0.00012
            self.height = h
            self.everest = h / 8848
        }

        self.dataUpdated?()
    }

    /// Absolute-altitude callback (iOS 15+). Delivers Apple's
    /// calibrated MSL altitude. Runs on `OperationQueue.main`, same
    /// as `Handler`, so no synchronisation needed against the relative
    /// stream.
    @available(iOS 15.0, *)
    func AbsoluteHandler(_ data: CMAbsoluteAltitudeData?, _ error: Error?) {
        guard let data = data else { return }
        self.height = data.altitude
        self.everest = data.altitude / 8848
        self.heightAccuracy = data.accuracy
        self.hasAbsoluteFix = true
        // No `dataUpdated?()` here on purpose — the relative stream
        // fires at ~1 Hz and will pick up the new `height` on its
        // next tick. Avoids doubling the notification rate for
        // downstream MainActor consumers (widget refresh, etc.).
    }
}
