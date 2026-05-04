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

    private let barometer = CMAltimeter()
    var barometerInformationPressure: Double = 0
    var barometerInformationDelta: Double = 0
    var barometerInformationHeight: Double = 0
    var barometerInformationEverest: Double = 0
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
    func restoreFromSharedStorage() {
        if let token = SharedSnapshotStore.readCurrent(), token.barPreassure > 0 {
            self.barometerInformationPressure = token.barPreassure
            self.barometerInformationHeight = token.barAltitude
            self.barometerInformationEverest = token.barAltitude / 8848
            self.iphoneGPSAltitude = token.gpsAltitude
            self.iphoneGPSSpeed = token.gpsSpeed
            self.iphoneGPSLatitude = token.gpsLatitude
            self.iphoneGPSLongitude = token.gpsLongitude
            return
        }
        guard let userDefaults = UserDefaults(suiteName: GeoWatchAppDelegate.appGroupID) else { return }
        let pressure = userDefaults.double(forKey: GeoWatchAppDelegate.pressureKey)
        let altitude = userDefaults.double(forKey: GeoWatchAppDelegate.altitudeKey)
        let delta = userDefaults.double(forKey: GeoWatchAppDelegate.deltaKey)
        let everest = userDefaults.double(forKey: GeoWatchAppDelegate.everestKey)
        guard pressure > 0 else { return }
        self.barometerInformationPressure = pressure
        self.barometerInformationHeight = altitude
        self.barometerInformationDelta = delta
        self.barometerInformationEverest = everest > 0 ? everest : altitude / 8848
    }

    /// Called by `WatchConnectivityManager` when the paired iPhone
    /// pushes its latest snapshot. Updates GPS context (the Watch keeps
    /// using its own barometer for altitude/pressure).
    func applyInbound(_ token: InformationToken) {
        self.iphoneGPSAltitude = token.gpsAltitude
        self.iphoneGPSSpeed = token.gpsSpeed
        self.iphoneGPSLatitude = token.gpsLatitude
        self.iphoneGPSLongitude = token.gpsLongitude

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

            //Ph = P0 * exp(-0.00012 * h)
            //ln(P0 / Ph) = 0.00012 * h
            // h = ln(P0 / Ph) / 0.00012
            // P0 = 101.325
            let P0: Double = 101.325
            let Ph: Double = pressure
            let h: Double = log(P0 / Ph) / 0.00012
            let everest: Double = h / 8848

            Task { @MainActor in
                guard let self = self else { return }
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
