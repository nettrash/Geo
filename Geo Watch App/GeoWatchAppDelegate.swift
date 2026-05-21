//
//  GeoWatchAppDelegate.swift
//  Geo
//
//  Created by Ivan Alekseev on 25/04/2025.
//

import WatchKit
import CoreMotion
import WidgetKit

@MainActor
class GeoWatchAppDelegate: NSObject, WKApplicationDelegate {

    // Legacy keys kept so older `Geo_Watch_Widget` builds — and any
    // first-party complications people may still have on their faces —
    // continue to read sensible values during the transition. New
    // readers should go through `SharedSnapshotStore`.
    static let appGroupID = SharedSnapshotStore.appGroupID
    static let pressureKey = "WatchBarometerPressure"
    static let altitudeKey = "WatchBarometerAltitude"
    static let deltaKey = "WatchBarometerDelta"
    static let everestKey = "WatchBarometerEverest"
    static let timestampKey = "WatchBarometerTimestamp"

    // Calibration reference inherited from the paired iPhone. The
    // iPhone's `barAltitude` is the Apple-calibrated MSL altitude
    // (`CMAbsoluteAltitudeData`), and `barPreassure` is the pressure
    // it observed at that altitude. Together they let the Watch
    // convert its own pressure readings into calibrated altitude
    // using the relative-pressure formula — which is what the
    // barometer is actually good at — without needing location
    // permission on the Watch.
    static let calibPressureKey = "iPhoneCalibPressure"
    static let calibAltitudeKey = "iPhoneCalibAltitude"
    static let calibTimestampKey = "iPhoneCalibTimestamp"

    private let barometer = CMAltimeter()
    var barometerInformationPressure: Double = 0
    var barometerInformationDelta: Double = 0
    var barometerInformationHeight: Double = 0
    var barometerInformationEverest: Double = 0
    /// Pressure (kPa) the iPhone last reported alongside its
    /// calibrated altitude. Zero means no calibration available yet.
    var iphoneCalibPressure: Double = 0
    /// Calibrated MSL altitude (m) the iPhone last reported.
    var iphoneCalibAltitude: Double = 0
    /// When `iphoneCalibPressure` / `iphoneCalibAltitude` were
    /// observed by the iPhone. Used by callers that care about
    /// staleness; the formula itself works as long as the weather
    /// hasn't shifted dramatically since.
    var iphoneCalibTimestamp: Date = .distantPast
    /// Most recent GPS context received from the iPhone (latitude /
    /// longitude / altitude / speed). The Watch has no GPS of its own
    /// in this app, so this comes from the paired iPhone via WCSession.
    var iphoneGPSAltitude: Double = 0
    var iphoneGPSSpeed: Double = 0
    var iphoneGPSLatitude: Double = 0
    var iphoneGPSLongitude: Double = 0

    private var delegates: [(_ vPressure: Double, _ vDelta: Double, _ vHeight: Double, _ vEverest: Double) -> Void] = []
    var isUpdating: Bool = false
    private var lastWidgetReloadDate: Date = .distantPast

    /// WatchConnectivity bridge to the paired iPhone.
    private var connectivity: WatchConnectivityManager?

    func applicationDidFinishLaunching() {
        // Rehydrate from the shared store before we start the live sensor so the
        // UI shows the last persisted reading immediately instead of zero.
        restoreFromSharedStorage()

        // Wire WCSession early so the iPhone can deliver context as soon
        // as it's launched.
        connectivity = WatchConnectivityManager()
        connectivity?.appDelegate = self

        // Start barometer immediately on app launch — don't wait for ContentView
        startUpdating()
    }

    /// Read both the unified `InformationToken` (preferred) and the
    /// legacy per-key state. The unified token wins when present.
    /// Also restores the iPhone calibration reference, which lets
    /// `startUpdating` compute calibrated altitude on the very first
    /// barometer tick instead of waiting for a fresh WCSession push.
    func restoreFromSharedStorage() {
        if let token = SharedSnapshotStore.readCurrent(), token.barPreassure > 0 {
            self.barometerInformationPressure = token.barPreassure
            self.barometerInformationHeight = token.barAltitude
            self.barometerInformationEverest = token.barAltitude / 8848
            self.iphoneGPSAltitude = token.gpsAltitude
            self.iphoneGPSSpeed = token.gpsSpeed
            self.iphoneGPSLatitude = token.gpsLatitude
            self.iphoneGPSLongitude = token.gpsLongitude
        }
        if let userDefaults = UserDefaults(suiteName: GeoWatchAppDelegate.appGroupID) {
            // Per-key legacy state.
            let pressure = userDefaults.double(forKey: GeoWatchAppDelegate.pressureKey)
            let altitude = userDefaults.double(forKey: GeoWatchAppDelegate.altitudeKey)
            let delta = userDefaults.double(forKey: GeoWatchAppDelegate.deltaKey)
            let everest = userDefaults.double(forKey: GeoWatchAppDelegate.everestKey)
            if self.barometerInformationPressure == 0 && pressure > 0 {
                self.barometerInformationPressure = pressure
                self.barometerInformationHeight = altitude
                self.barometerInformationDelta = delta
                self.barometerInformationEverest = everest > 0 ? everest : altitude / 8848
            }
            // iPhone calibration reference.
            let calibPressure = userDefaults.double(forKey: GeoWatchAppDelegate.calibPressureKey)
            let calibAltitude = userDefaults.double(forKey: GeoWatchAppDelegate.calibAltitudeKey)
            let calibTimestamp = userDefaults.double(forKey: GeoWatchAppDelegate.calibTimestampKey)
            if calibPressure > 0 {
                self.iphoneCalibPressure = calibPressure
                self.iphoneCalibAltitude = calibAltitude
                self.iphoneCalibTimestamp = calibTimestamp > 0
                    ? Date(timeIntervalSince1970: calibTimestamp)
                    : .distantPast
            }
        }
    }

    /// Called by `WatchConnectivityManager` when the paired iPhone
    /// pushes its latest snapshot. Updates GPS context (the Watch keeps
    /// using its own barometer for altitude/pressure) and refreshes
    /// the iPhone calibration reference so subsequent Watch readings
    /// inherit the iPhone's weather-corrected absolute altitude.
    func applyInbound(_ token: InformationToken) {
        self.iphoneGPSAltitude = token.gpsAltitude
        self.iphoneGPSSpeed = token.gpsSpeed
        self.iphoneGPSLatitude = token.gpsLatitude
        self.iphoneGPSLongitude = token.gpsLongitude

        // Always refresh the iPhone calibration reference when the
        // inbound snapshot contains a barometer reading — even if the
        // Watch already has its own. The Watch's altitude is derived
        // from this reference by the formula
        //   watchAlt = refAlt + log(refP / nowP) / 0.00012
        // so a fresher reference (closer in time to "now") tracks the
        // real atmosphere better.
        if token.barPreassure > 0 {
            self.iphoneCalibPressure = token.barPreassure
            self.iphoneCalibAltitude = token.barAltitude
            self.iphoneCalibTimestamp = token.recordDate
            if let ud = UserDefaults(suiteName: GeoWatchAppDelegate.appGroupID) {
                ud.set(token.barPreassure, forKey: GeoWatchAppDelegate.calibPressureKey)
                ud.set(token.barAltitude, forKey: GeoWatchAppDelegate.calibAltitudeKey)
                ud.set(token.recordDate.timeIntervalSince1970,
                       forKey: GeoWatchAppDelegate.calibTimestampKey)
            }
        }

        // If the iPhone has a fresher barometer reading and we have
        // none of our own, adopt it.
        if self.barometerInformationPressure == 0 && token.barPreassure > 0 {
            self.barometerInformationPressure = token.barPreassure
            self.barometerInformationHeight = token.barAltitude
            self.barometerInformationEverest = token.barAltitude / 8848
        }

        AppLog.watch.debug("Received iPhone snapshot")
    }

    func registerCallback(_ delegate: @escaping (_ vPressure: Double, _ vDelta: Double, _ vHeight: Double, _ vEverest: Double) -> Void) {
        self.delegates.append(delegate)
    }

    func startUpdating() {
        guard !isUpdating else { return }
        let altimeter = self.barometer
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let data = data else { return }

            let pressure = data.pressure.doubleValue
            let delta = data.relativeAltitude.doubleValue

            Task { @MainActor in
                guard let self = self else { return }

                // Compute altitude. Prefer the iPhone's calibrated
                // reference if we have one — `iphoneCalibAltitude` is
                // the Apple-calibrated MSL value, so anchoring off it
                // removes the weather bias inherent in the raw
                // barometric formula. Falls back to the biased formula
                // when no calibration has arrived yet (Watch run
                // standalone, or paired iPhone never opened).
                let h: Double
                if self.iphoneCalibPressure > 0 {
                    // Same scale-height constant as the fallback
                    // formula; the difference is anchoring against a
                    // known calibrated point instead of standard sea
                    // level.
                    h = self.iphoneCalibAltitude
                        + log(self.iphoneCalibPressure / pressure) / 0.00012
                } else {
                    //Ph = P0 * exp(-0.00012 * h)
                    //ln(P0 / Ph) = 0.00012 * h
                    // h = ln(P0 / Ph) / 0.00012
                    // P0 = 101.325
                    let P0: Double = 101.325
                    h = log(P0 / pressure) / 0.00012
                }
                let everest: Double = h / 8848

                self.barometerInformationPressure = pressure
                self.barometerInformationDelta = delta
                self.barometerInformationHeight = h
                self.barometerInformationEverest = everest

                self.shareDataWithWidget()

                // Push to the iPhone as well, so the iPhone main app /
                // widget can pick up Watch-captured samples.
                let token = self.currentSnapshot()
                self.connectivity?.sendCurrentSnapshot(token)

                for delegate in self.delegates {
                    delegate(pressure, delta, h, everest)
                }
            }
        }
        self.isUpdating = true
    }

    /// Build the unified snapshot from current Watch state + last known
    /// iPhone GPS context.
    private func currentSnapshot() -> InformationToken {
        InformationToken(
            recordDate: Date(),
            gpsAltitude: self.iphoneGPSAltitude,
            gpsSpeed: self.iphoneGPSSpeed,
            barPreassure: self.barometerInformationPressure,
            barAltitude: self.barometerInformationHeight,
            gpsLatitude: self.iphoneGPSLatitude,
            gpsLongitude: self.iphoneGPSLongitude
        )
    }

    private func shareDataWithWidget() {
        // Write both the unified snapshot (new readers) and the legacy
        // keys (old readers) so existing watch faces don't break.
        let token = currentSnapshot()
        SharedSnapshotStore.write(token)

        if let userDefaults = UserDefaults(suiteName: GeoWatchAppDelegate.appGroupID) {
            userDefaults.set(self.barometerInformationPressure, forKey: GeoWatchAppDelegate.pressureKey)
            userDefaults.set(self.barometerInformationHeight, forKey: GeoWatchAppDelegate.altitudeKey)
            userDefaults.set(self.barometerInformationDelta, forKey: GeoWatchAppDelegate.deltaKey)
            userDefaults.set(self.barometerInformationEverest, forKey: GeoWatchAppDelegate.everestKey)
            userDefaults.set(Date().timeIntervalSince1970, forKey: GeoWatchAppDelegate.timestampKey)
        }

        // Throttle widget reloads to every 30 seconds — barometer fires ~1Hz
        if lastWidgetReloadDate.addingTimeInterval(30) < Date() {
            lastWidgetReloadDate = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
