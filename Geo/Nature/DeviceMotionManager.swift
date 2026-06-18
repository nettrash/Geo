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
    /// Maximum deviation (degrees) between reported and true heading, as
    /// reported by Core Location. `< 0` means the heading is invalid /
    /// the magnetometer needs calibration; larger values mean worse
    /// accuracy. Drives the "calibrate compass" hint. Starts optimistic
    /// (0) so the hint isn't shown before the first heading callback —
    /// mirrors Android's `SENSOR_STATUS_ACCURACY_HIGH` initial value.
    @Published var headingAccuracy: Double = 0
    
    private let motionManager = CMMotionManager()
    private let headingManager = CLLocationManager()
    
    override init() {
        super.init()
        headingManager.delegate = self
    }
    
    /// Begin delivering heading (and, when `includeAttitude` is true, pitch/roll).
    ///
    /// - Parameter includeAttitude: pass `false` to start ONLY the cheap,
    ///   event-driven compass-heading stream and skip the 30 Hz device-motion
    ///   attitude stream. The Info-tab peak-bearing arrow consumes only
    ///   `heading`, so it opts out — otherwise a 30 Hz `CMDeviceMotion` stream
    ///   (and the sensor fusion behind it) runs the whole time the Info tab is
    ///   on screen just to compute pitch/roll nothing reads. The AR Nature view
    ///   needs attitude and keeps the default `true`.
    func start(includeAttitude: Bool = true) {
        // Start compass heading updates
        if CLLocationManager.headingAvailable() {
            headingManager.headingFilter = 1 // update every 1 degree change
            headingManager.startUpdatingHeading()
        }

        guard includeAttitude else { return }

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
        let accuracy = newHeading.headingAccuracy
        // Publish accuracy regardless so the calibrate hint can react; only
        // accept the heading value itself when it's valid.
        if accuracy >= 0 {
            // `trueHeading` is in [0, 360); only the `-1` sentinel means it
            // couldn't be computed. Use `>= 0` so a valid due-true-north
            // (0.0) reading isn't discarded for the magnetic fallback.
            let h = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
            Task { @MainActor [weak self] in
                self?.heading = h
                self?.headingAccuracy = accuracy
            }
        } else {
            Task { @MainActor [weak self] in
                self?.headingAccuracy = accuracy
            }
        }
    }
}
