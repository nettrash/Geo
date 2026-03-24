//
//  DeviceMotionManager.swift
//  Geo
//
//  Created by nettrash on 24/03/2026.
//

import Foundation
import CoreMotion
import CoreLocation

/// Provides real-time device heading and pitch for AR overlay positioning
@MainActor
class DeviceMotionManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    
    @Published var heading: Double = 0       // compass heading in degrees (0-360)
    @Published var pitch: Double = 0         // device pitch in radians
    @Published var roll: Double = 0          // device roll in radians
    
    private let motionManager = CMMotionManager()
    private let headingManager = CLLocationManager()
    
    override init() {
        super.init()
        headingManager.delegate = self
    }
    
    func start() {
        // Start compass heading updates
        if CLLocationManager.headingAvailable() {
            headingManager.headingFilter = 1 // update every 1 degree change
            headingManager.startUpdatingHeading()
        }
        
        // Start device motion for pitch/roll
        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = 1.0 / 30.0 // 30 Hz
            motionManager.startDeviceMotionUpdates(
                using: .xArbitraryCorrectedZVertical,
                to: .main
            ) { [weak self] motion, error in
                guard let motion = motion, error == nil else { return }
                Task { @MainActor [weak self] in
                    self?.pitch = motion.attitude.pitch
                    self?.roll = motion.attitude.roll
                }
            }
        }
    }
    
    func stop() {
        headingManager.stopUpdatingHeading()
        motionManager.stopDeviceMotionUpdates()
    }
    
    // MARK: - CLLocationManagerDelegate
    
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        let h = newHeading.trueHeading > 0 ? newHeading.trueHeading : newHeading.magneticHeading
        Task { @MainActor [weak self] in
            self?.heading = h
        }
    }
}
