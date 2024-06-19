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
    
    let available: Bool
    
    var pressure: Double
    var delta: Double
    var height: Double
    var everest: Double
    
    var dataUpdated: (() -> Void)?
    
    init() {
        barometerManager = CMAltimeter()
        pressure = 0
        delta = 0
        height = 0
        everest = 0
        available = CMAltimeter.isRelativeAltitudeAvailable()
    }
    
    init(autoStart: Bool) {
        barometerManager = CMAltimeter()
        pressure = 0
        delta = 0
        height = 0
        everest = 0
        available = CMAltimeter.isRelativeAltitudeAvailable()
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
        available = CMAltimeter.isRelativeAltitudeAvailable()
        dataUpdated = handler
    }
    
    func Start() {
        if available {
            barometerManager.startRelativeAltitudeUpdates(to: OperationQueue.main, withHandler: self.Handler(_:_:))
        }
    }
    
    func Stop() {
        barometerManager.stopRelativeAltitudeUpdates()
    }
    
    func Handler(_ data: CMAltitudeData?, _ error: Error?) {
        if data != nil {
            self.pressure = data!.pressure.doubleValue
            self.delta = data!.relativeAltitude.doubleValue
            
            //Ph = P0 * exp(-0.00012 * h)
            //exp(-0.00012 * h) = Ph / P0
            //-0.00012 * h = ln( Ph / P0 )
            //ln( P0 / Ph ) = 0.00012 * h
            // h = ln ( P0 / Ph ) / 0.00012
            // P0 = 101.325
            
            let P0: Double = 101.325
            let Ph: Double = data!.pressure.doubleValue
            let h: Double = log(P0 / Ph) / 0.00012
            
            self.height = h
            self.everest = h / 8848
            
            self.dataUpdated?()
        }
    }
}
