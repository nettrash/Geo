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

    /// Calibration state of `height`, surfaced in the UI (Improvement #2)
    /// so the user can tell whether the altitude is Apple's calibrated MSL
    /// value or the weather-biased ±100–500 m pressure estimate.
    enum CalibrationState { case calibrated, calibrating, uncalibrated }
    var calibrationState: CalibrationState {
        if absoluteAvailable && hasAbsoluteFix { return .calibrated }
        if absoluteAvailable { return .calibrating }
        return .uncalibrated
    }

    // MARK: - Manual "I am at X m" calibration (M5b)

    /// Uncalibrated altitude — Apple's absolute value or the lapse fallback —
    /// before the manual offset is applied. `height` is this plus the
    /// decaying offset. Keeping it separate means the offset is always
    /// computed against the raw value and never compounds.
    private var rawHeight: Double = 0

    /// Persisted manual-calibration delta (m) and the time it was set.
    /// `CMAltimeter` has no setter, so the user's "I am at X m" pin is stored
    /// as a delta on top of the system value and decayed over time.
    private var calibrationOffset: Double = 0
    private var calibratedAt: Date?

    /// True once at least one real sensor sample has populated `rawHeight`.
    /// Before this, `rawHeight` is still the placeholder `0`, so calibrating
    /// would store `offset = known − 0 = known` and the first real tick would
    /// then double-bias `height` to `rawHeight + known`. Set only from the
    /// sensor handlers, so a rehydrated `height`/`pressure` (cold start /
    /// foreground resume) can't be mistaken for a live raw reading.
    private var hasRawAltitude = false

    private static let calOffsetKey = Atmosphere.calibrationOffsetKey
    private static let calAtKey = Atmosphere.calibrationAtKey

    /// Offset actually applied right now: the stored delta scaled by its
    /// age-based decay weight (zero once the calibration has expired).
    var effectiveOffset: Double {
        guard let calibratedAt else { return 0 }
        let age = Date().timeIntervalSince(calibratedAt)
        return calibrationOffset * Atmosphere.calibrationWeight(ageSeconds: age)
    }

    /// True while a manual calibration is set and not yet fully decayed.
    var isManuallyCalibrated: Bool {
        guard let calibratedAt else { return false }
        return Atmosphere.calibrationWeight(ageSeconds: Date().timeIntervalSince(calibratedAt)) > 0
    }

    /// Whether a manual calibration can be applied right now. Requires a real
    /// sensor sample to have populated `rawHeight` first — otherwise the
    /// offset would be measured against the placeholder `0` and double-bias
    /// the reading once the first tick lands. The Calibrate sheet disables
    /// its "Set" action until this is true.
    var canCalibrate: Bool { hasRawAltitude }

    /// Pin the displayed altitude to `known` metres by storing the delta
    /// against the current RAW (uncalibrated) altitude — so it agrees with
    /// the live readout immediately and doesn't compound with a prior offset.
    /// No-op until a real sensor sample has arrived (`canCalibrate`), so the
    /// offset is never measured against the placeholder `rawHeight == 0`.
    func calibrate(toAltitude known: Double) {
        guard hasRawAltitude else { return }
        calibrationOffset = known - rawHeight
        calibratedAt = Date()
        saveCalibration()
        applyCalibration()
        dataUpdated?()
    }

    func clearCalibration() {
        calibrationOffset = 0
        calibratedAt = nil
        saveCalibration()
        applyCalibration()
        dataUpdated?()
    }

    /// Recompute the published `height` / `everest` from the raw value and
    /// the (decayed) offset. Called on every sensor tick and on calibrate/clear.
    private func applyCalibration() {
        let h = rawHeight + effectiveOffset
        height = h
        everest = h / Atmosphere.everestHeightM
    }

    private func loadCalibration() {
        guard let ud = UserDefaults(suiteName: SharedSnapshotStore.appGroupID),
              let at = ud.object(forKey: Self.calAtKey) as? Date else { return }
        calibratedAt = at
        calibrationOffset = ud.double(forKey: Self.calOffsetKey)
    }

    private func saveCalibration() {
        guard let ud = UserDefaults(suiteName: SharedSnapshotStore.appGroupID) else { return }
        if let calibratedAt {
            ud.set(calibrationOffset, forKey: Self.calOffsetKey)
            ud.set(calibratedAt, forKey: Self.calAtKey)
        } else {
            ud.removeObject(forKey: Self.calOffsetKey)
            ud.removeObject(forKey: Self.calAtKey)
        }
    }

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
        loadCalibration()
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
        loadCalibration()
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
        loadCalibration()
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
        // Clamp the live pressure sample to a sane window (Improvement
        // #11: 300–1100 hPa = 30–110 kPa) so a single bad sensor reading
        // can't produce NaN or wildly out-of-range derived values.
        self.pressure = min(max(data.pressure.doubleValue, 30.0), 110.0)
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
            // Lapse-rate (international barometric) altitude from the
            // raw pressure sample, assuming standard sea-level pressure
            // (Improvements #10/#11). The reading is already clamped to
            // a sane window above; `Atmosphere.altitude` clamps again
            // for safety.
            self.rawHeight = Atmosphere.altitude(pressureKPa: self.pressure)
            self.hasRawAltitude = true
        }
        // Re-apply the (decaying) manual calibration every tick so `height`
        // stays current as the offset ages.
        self.applyCalibration()

        self.dataUpdated?()
    }

    /// Absolute-altitude callback (iOS 15+). Delivers Apple's
    /// calibrated MSL altitude. Runs on `OperationQueue.main`, same
    /// as `Handler`, so no synchronisation needed against the relative
    /// stream.
    @available(iOS 15.0, *)
    func AbsoluteHandler(_ data: CMAbsoluteAltitudeData?, _ error: Error?) {
        guard let data = data else { return }
        self.rawHeight = data.altitude
        self.hasRawAltitude = true
        self.heightAccuracy = data.accuracy
        self.hasAbsoluteFix = true
        self.applyCalibration()
        // No `dataUpdated?()` here on purpose — the relative stream
        // fires at ~1 Hz and will pick up the new `height` on its
        // next tick. Avoids doubling the notification rate for
        // downstream MainActor consumers (widget refresh, etc.).
    }
}
