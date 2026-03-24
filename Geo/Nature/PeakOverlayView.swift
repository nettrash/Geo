//
//  PeakOverlayView.swift
//  Geo
//
//  Created by nettrash on 24/03/2026.
//

import SwiftUI
import CoreLocation
import CoreMotion

/// Overlay view that positions peak markers and history points on screen based on
/// device heading/pitch and their bearing/elevation angle
struct PeakOverlayView: View {
    let peaks: [NearbyPeak]
    let historyPoints: [ARHistoryPoint]
    let userLocation: CLLocation?
    let heading: Double      // device compass heading in degrees (0-360)
    let pitch: Double        // device pitch in radians (0 = flat, -π/2 = pointing up)
    
    /// Horizontal field of view of the camera in degrees
    private let hFOV: Double = 60.0
    /// Vertical field of view of the camera in degrees
    private let vFOV: Double = 80.0
    
    var body: some View {
        GeometryReader { geometry in
            let screenWidth = geometry.size.width
            let screenHeight = geometry.size.height
            
            // History points (rendered first, behind peaks)
            ForEach(historyPoints) { point in
                let position = screenPositionForPoint(
                    bearing: point.bearing,
                    altitude: point.gpsAltitude,
                    distance: point.distance,
                    screenWidth: screenWidth,
                    screenHeight: screenHeight
                )
                
                if position.isVisible {
                    HistoryPointMarkerView(point: point)
                        .position(x: position.x, y: position.y)
                        .opacity(opacityForDistance(point.distance, maxDistance: 50000) * 0.85)
                        .scaleEffect(scaleForDistance(point.distance, maxDistance: 50000))
                }
            }
            
            // Peaks (rendered on top)
            ForEach(peaks) { peak in
                let position = screenPositionForPoint(
                    bearing: peak.bearing,
                    altitude: peak.altitude,
                    distance: peak.distance,
                    screenWidth: screenWidth,
                    screenHeight: screenHeight
                )
                
                if position.isVisible {
                    PeakMarkerView(peak: peak)
                        .position(x: position.x, y: position.y)
                        .opacity(opacityForDistance(peak.distance, maxDistance: 50000))
                        .scaleEffect(scaleForDistance(peak.distance, maxDistance: 50000))
                }
            }
        }
    }
    
    /// Project a point's GPS position onto screen coordinates
    private func screenPositionForPoint(
        bearing: Double,
        altitude: Double,
        distance: Double,
        screenWidth: Double,
        screenHeight: Double
    ) -> (x: Double, y: Double, isVisible: Bool) {
        
        // 1. Calculate horizontal angle difference between device heading and point bearing
        var angleDiff = bearing - heading
        // Normalize to [-180, 180]
        while angleDiff > 180 { angleDiff -= 360 }
        while angleDiff < -180 { angleDiff += 360 }
        
        // Check if within horizontal FOV
        guard abs(angleDiff) <= hFOV / 2 + 5 else {
            return (0, 0, false)
        }
        
        // 2. Calculate horizontal screen position
        let x = screenWidth / 2 + (angleDiff / (hFOV / 2)) * (screenWidth / 2)
        
        // 3. Calculate vertical position based on elevation angle
        let elevationAngle = calculateElevationAngle(altitude: altitude, distance: distance)
        
        // Convert device pitch to a "look direction" angle in degrees.
        // CMMotionManager attitude.pitch: 0 = flat on table, π/2 = upright/portrait.
        // When user holds phone upright looking at horizon, pitch ≈ π/2 (≈90°).
        // We want pitchDegrees = 0 when looking at the horizon.
        let pitchDegrees = pitch * 180 / .pi - 90
        
        let verticalAngleDiff = elevationAngle - pitchDegrees
        let y = screenHeight / 2 - (verticalAngleDiff / (vFOV / 2)) * (screenHeight / 2)
        
        // Check if within vertical FOV (with some margin)
        let isVisible = y > -50 && y < screenHeight + 50
        
        return (x, y, isVisible)
    }
    
    /// Calculate the elevation angle (in degrees) from the user to a point
    private func calculateElevationAngle(altitude: Double, distance: Double) -> Double {
        guard let userLoc = userLocation, distance > 0 else { return 0 }
        
        let altitudeDiff = altitude - userLoc.altitude
        let angle = atan2(altitudeDiff, distance) * 180 / .pi
        return angle
    }
    
    /// Points further away are more transparent
    private func opacityForDistance(_ distance: Double, maxDistance: Double) -> Double {
        let opacity = 1.0 - (distance / maxDistance) * 0.5
        return max(0.5, min(1.0, opacity))
    }
    
    /// Points further away are slightly smaller
    private func scaleForDistance(_ distance: Double, maxDistance: Double) -> Double {
        let scale = 1.0 - (distance / maxDistance) * 0.4
        return max(0.6, min(1.0, scale))
    }
}
