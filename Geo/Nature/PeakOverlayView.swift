//
//  PeakOverlayView.swift
//  Geo
//
//  Created by nettrash on 24/03/2026.
//

import SwiftUI
import CoreLocation
import simd

/// Overlay view that positions peak markers and history points on screen
/// using ARKit's camera view-projection matrix for pixel-perfect alignment
/// with the camera feed. Points are locked to their real-world GPS positions.
///
/// Points whose IDs appear in `occludedIDs` are hidden (behind real-world geometry).
struct PeakOverlayView: View {
    let peaks: [NearbyPeak]
    let historyPoints: [ARHistoryPoint]
    let userLocation: CLLocation?
    @ObservedObject var sessionManager: ARSessionManager
    let occludedIDs: Set<UUID> // IDs of points occluded by room geometry
    
    var body: some View {
        GeometryReader { geometry in
            let screenWidth = geometry.size.width
            let screenHeight = geometry.size.height
            
            // History points (rendered first, behind peaks)
            ForEach(historyPoints) { point in
                if !occludedIDs.contains(point.id) {
                    if let screenPos = projectGPSPoint(
                        coordinate: point.coordinate,
                        altitude: point.gpsAltitude,
                        screenWidth: screenWidth,
                        screenHeight: screenHeight
                    ) {
                        HistoryPointMarkerView(point: point)
                            .position(x: screenPos.x, y: screenPos.y)
                            .animation(.linear(duration: 1.0 / 30.0), value: screenPos)
                            .opacity(opacityForDistance(point.distance, maxDistance: 50000) * 0.85)
                            .scaleEffect(scaleForDistance(point.distance, maxDistance: 50000))
                    }
                }
            }
            
            // Peaks (rendered on top)
            ForEach(peaks) { peak in
                if !occludedIDs.contains(peak.id) {
                    if let screenPos = projectGPSPoint(
                        coordinate: peak.coordinate,
                        altitude: peak.altitude,
                        screenWidth: screenWidth,
                        screenHeight: screenHeight
                    ) {
                        PeakMarkerView(peak: peak)
                            .position(x: screenPos.x, y: screenPos.y)
                            .animation(.linear(duration: 1.0 / 30.0), value: screenPos)
                            .opacity(opacityForDistance(peak.distance, maxDistance: 50000))
                            .scaleEffect(scaleForDistance(peak.distance, maxDistance: 50000))
                    }
                }
            }
        }
    }
    
    // MARK: - GPS → World → Screen Projection
    
    /// Project a GPS coordinate + altitude to screen coordinates using the AR camera.
    ///
    /// Steps:
    /// 1. Convert GPS (lat/lon/alt) → local ENU (East-North-Up) offset in meters from user
    /// 2. Map ENU → ARKit world space (+X=East, +Y=Up, −Z=North per gravityAndHeading)
    /// 3. Multiply by AR camera view-projection matrix → clip space
    /// 4. Perspective divide → NDC → screen points
    private func projectGPSPoint(
        coordinate: CLLocationCoordinate2D,
        altitude: Double,
        screenWidth: Double,
        screenHeight: Double
    ) -> CGPoint? {
        guard let userLoc = userLocation, sessionManager.isTracking else { return nil }
        
        // 1. GPS → local ENU offset (meters)
        let enu = gpsToENU(
            from: userLoc.coordinate, fromAlt: userLoc.altitude,
            to: coordinate, toAlt: altitude
        )
        
        // 2. ENU → ARKit world space
        // ARKit gravityAndHeading: +X = East, +Y = Up, −Z = North
        let worldPoint = simd_float3(
            Float(enu.east),
            Float(enu.up),
            Float(-enu.north) // North maps to −Z
        )
        
        // 3. Project to screen via AR camera matrices
        guard let screenPos = sessionManager.projectToScreen(worldPoint) else {
            return nil
        }
        
        // 4. Visibility check — is the point on-screen (with margin)?
        let margin: CGFloat = 50
        guard screenPos.x > -margin && screenPos.x < screenWidth + margin &&
              screenPos.y > -margin && screenPos.y < screenHeight + margin else {
            return nil
        }
        
        return screenPos
    }
    
    /// Convert two GPS coordinates to a local East-North-Up (ENU) offset in meters.
    private func gpsToENU(
        from fromCoord: CLLocationCoordinate2D, fromAlt: Double,
        to toCoord: CLLocationCoordinate2D, toAlt: Double
    ) -> (east: Double, north: Double, up: Double) {
        let latRef = fromCoord.latitude * .pi / 180
        
        // Approximate meters per degree at this latitude
        let metersPerDegreeLat = 111_320.0
        let metersPerDegreeLon = 111_320.0 * cos(latRef)
        
        let dLat = toCoord.latitude - fromCoord.latitude
        let dLon = toCoord.longitude - fromCoord.longitude
        
        let north = dLat * metersPerDegreeLat
        let east = dLon * metersPerDegreeLon
        let up = toAlt - fromAlt
        
        return (east, north, up)
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
