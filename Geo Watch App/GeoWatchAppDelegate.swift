//
//  GeoWatchAppDelegate.swift
//  Geo
//
//  Created by Ivan Alekseev on 25/04/2025.
//

import WatchKit
import CoreMotion

@MainActor
class GeoWatchAppDelegate: NSObject, WKApplicationDelegate {
    
    static let appGroupID = "group.me.nettrash.Geo"
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
    private var delegates: [(_ vPressure: Double, _ vDelta: Double, _ vHeight: Double, _ vEverest: Double) -> Void] = []
    var isUpdating: Bool = false

    func registerCallback(_ delegate: @escaping (_ vPressure: Double, _ vDelta: Double, _ vHeight: Double, _ vEverest: Double) -> Void) {
        self.delegates.append(delegate)
    }
    
    func startUpdating() {
        barometer.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
            guard let data = data else { return }
            
            let pressure = data.pressure.doubleValue
            let delta = data.relativeAltitude.doubleValue
            
            //Ph = P0 * exp(-0.00012 * h)
            //exp(-0.00012 * h) = Ph / P0
            //-0.00012 * h = ln( Ph / P0 )
            //ln( P0 / Ph ) = 0.00012 * h
            // h = ln ( P0 / Ph ) / 0.00012
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
                
                // Share data with Widget via App Group UserDefaults
                self.shareDataWithWidget()
                
                for delegate in self.delegates {
                    delegate(pressure, delta, h, everest)
                }
            }
        }
        self.isUpdating = true
    }
    
    private func shareDataWithWidget() {
        if let userDefaults = UserDefaults(suiteName: GeoWatchAppDelegate.appGroupID) {
            userDefaults.set(self.barometerInformationPressure, forKey: GeoWatchAppDelegate.pressureKey)
            userDefaults.set(self.barometerInformationHeight, forKey: GeoWatchAppDelegate.altitudeKey)
            userDefaults.set(self.barometerInformationDelta, forKey: GeoWatchAppDelegate.deltaKey)
            userDefaults.set(self.barometerInformationEverest, forKey: GeoWatchAppDelegate.everestKey)
            userDefaults.set(Date().timeIntervalSince1970, forKey: GeoWatchAppDelegate.timestampKey)
        }
    }
}
