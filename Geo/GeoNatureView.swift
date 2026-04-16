//
//  GeoNatureView.swift
//  Geo
//
//  Created by nettrash on 18/06/2024.
//

import SwiftUI
import AVFoundation
import ARKit
import CoreLocation
import simd

struct GeoNatureView: View {
    var app: GeoAppDelegate?
    
    @StateObject private var peakFinder = PeakFinder()
    @StateObject private var motionManager = DeviceMotionManager()
    @StateObject private var occlusionManager = AROcclusionManager()
    @StateObject private var sessionManager = ARSessionManager()
    @State private var cameraPermissionGranted = false
    @State private var showPermissionAlert = false
    @State private var historyPoints: [ARHistoryPoint] = []
    
    /// Stable location snapshot passed to the overlay.
    /// Only updated when the user moves more than 5 m, preventing GPS jitter
    /// from causing PeakOverlayView to re-render and toggle edge-case markers.
    @State private var overlayLocation: CLLocation?
    
    /// Timer that fires every 5 seconds to refresh peak/history data
    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    
    /// Timer that fires every 0.5 seconds to run occlusion checks
    private let occlusionTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    
    /// The best available distance (meters) to the surface the camera is pointing at.
    /// Priority: LiDAR depth → ARKit raycast → plane intersection.
    private var distanceToWall: Float? {
        sessionManager.centerDepth ?? sessionManager.raycastDistance ?? occlusionManager.wallDistance
    }
    
    /// Label for the active distance source (shown in the top bar for debugging)
    private var distanceSource: String? {
        if sessionManager.centerDepth != nil { return "LiDAR" }
        if sessionManager.raycastDistance != nil { return "Raycast" }
        if occlusionManager.wallDistance != nil { return "Plane" }
        return nil
    }
    
    var body: some View {
        ZStack {
            if cameraPermissionGranted {
                // AR Camera background
                ARCameraView(occlusionManager: occlusionManager, sessionManager: sessionManager)
                    .ignoresSafeArea()
                
                // Peak & history point markers positioned via GPS→ENU→ARKit projection
                PeakOverlayView(
                    peaks: peakFinder.peaks,
                    historyPoints: historyPoints,
                    userLocation: overlayLocation,
                    sessionManager: sessionManager,
                    occlusionManager: occlusionManager
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
                
                // Center crosshair + wall distance
                VStack(spacing: 6) {
                    Spacer()
                    
                    // Crosshair
                    Image(systemName: "plus")
                        .font(.system(size: 28, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.7))
                    
                    // Distance label
                    if let dist = distanceToWall {
                        Text(formatDistance(dist))
                            .font(.system(size: 20, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.55))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Text("--")
                            .font(.system(size: 20, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.35))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    
                    Spacer()
                }
                
                // Top info bar
                VStack {
                    HStack {
                        Image(systemName: "mountain.2.fill")
                            .foregroundStyle(.orange)
                        Text(verbatim: "\(peakFinder.peaks.count)")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.white)
                        
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(.cyan)
                        Text(verbatim: "\(historyPoints.count)")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.white)
                        
                        if occlusionManager.isSupported {
                            Image(systemName: "cube.transparent")
                                .foregroundStyle(.green)
                                .font(.system(size: 12))
                            Text(verbatim: "LiDAR")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.green)
                        }
                        
                        if let source = distanceSource {
                            Image(systemName: "sensor.tag.radiowaves.forward")
                                .foregroundStyle(.cyan)
                                .font(.system(size: 12))
                            Text(verbatim: source)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.cyan)
                        }
                        
                        // Scene initialization indicator
                        if !occlusionManager.isSceneReady {
                            Image(systemName: "rays")
                                .foregroundStyle(.yellow)
                                .font(.system(size: 12))
                                .symbolEffect(.pulse)
                            Text("Scanning")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.yellow)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "location.north.fill")
                            .rotationEffect(.degrees(motionManager.heading))
                            .foregroundStyle(.orange)
                        Text(verbatim: String(format: "%.0f°", motionManager.heading))
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.5))
                    
                    Spacer()
                }
            } else {
                // Camera permission not granted
                VStack(spacing: 20) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.secondary)
                    
                    Text("Camera Access Required")
                        .font(.title2.bold())
                    
                    Text("The Nature AR view needs camera access to show peaks around you in augmented reality.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    
                    Button("Allow Camera Access") {
                        requestCameraPermission()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            }
        }
        .onAppear {
            checkCameraPermission()
        }
        .onDisappear {
            motionManager.stop()
        }
        .onChange(of: cameraPermissionGranted) { _, granted in
            if granted {
                startAR()
            }
        }
        .alert("Camera Access", isPresented: $showPermissionAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Please enable camera access in Settings to use the Nature AR view.")
        }
        .onReceive(refreshTimer) { _ in
            if cameraPermissionGranted {
                refreshOverlayLocationIfNeeded()
                searchForPeaks()
                loadHistoryPoints()
            }
        }
    }
    
    // MARK: - Helpers
    
    private func formatDistance(_ meters: Float) -> String {
        if meters < 1.0 {
            return String(format: "%.0f cm", meters * 100)
        } else if meters < 10.0 {
            return String(format: "%.2f m", meters)
        } else {
            return String(format: "%.1f m", meters)
        }
    }
    
    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraPermissionGranted = true
        case .notDetermined:
            break
        case .denied, .restricted:
            cameraPermissionGranted = false
        @unknown default:
            break
        }
    }
    
    private func requestCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    cameraPermissionGranted = granted
                    if !granted {
                        showPermissionAlert = true
                    }
                }
            }
        case .denied, .restricted:
            showPermissionAlert = true
        case .authorized:
            cameraPermissionGranted = true
        @unknown default:
            break
        }
    }
    
    private func startAR() {
        motionManager.start()
        refreshOverlayLocationIfNeeded()
        searchForPeaks()
        loadHistoryPoints()
        occlusionManager.isSupported = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        occlusionManager.sessionDidStart()
    }
    
    /// Update the overlay location only when the user has moved more than 5 m.
    /// This prevents GPS jitter from re-triggering PeakOverlayView renders
    /// and causing edge-case markers to toggle visibility.
    private func refreshOverlayLocationIfNeeded() {
        guard let newLoc = app?.location?.location else { return }
        if let current = overlayLocation, newLoc.distance(from: current) < 5.0 { return }
        overlayLocation = newLoc
    }
    
    private func searchForPeaks() {
        guard let location = app?.location?.location else {
            Task {
                try? await Task.sleep(for: .seconds(2))
                searchForPeaks()
            }
            return
        }
        Task {
            await peakFinder.searchPeaks(near: location, mountainsData: app?.mountainsData)
        }
    }
    
    private func loadHistoryPoints() {
        guard let location = app?.location?.location,
              let history = app?.history else {
            Task {
                try? await Task.sleep(for: .seconds(2))
                loadHistoryPoints()
            }
            return
        }
        
        history.Refresh()
        
        let maxDistance: CLLocationDistance = 1000
        
        historyPoints = history.historyItems
            .suffix(200)
            .compactMap { item -> ARHistoryPoint? in
                let itemLocation = CLLocation(latitude: item.gpsLatitude, longitude: item.gpsLongitude)
                let distance = location.distance(from: itemLocation)
                guard distance <= maxDistance, distance > 1 else { return nil }
                
                let itemBearing = bearing(
                    from: location.coordinate,
                    to: CLLocationCoordinate2D(latitude: item.gpsLatitude, longitude: item.gpsLongitude)
                )
                return ARHistoryPoint(
                    date: item.recordDate ?? Date(),
                    coordinate: CLLocationCoordinate2D(latitude: item.gpsLatitude, longitude: item.gpsLongitude),
                    gpsAltitude: item.gpsAltitude,
                    barometerAltitude: item.barometerAltitude,
                    pressure: item.barometerPressure,
                    speed: item.gpsVelocity,
                    distance: distance,
                    bearing: itemBearing
                )
            }
    }
    
    private func runOcclusionCheck() {
        guard let userLoc = app?.location?.location else { return }
        
        var targets: [AROcclusionManager.OcclusionTarget] = []
        
        // Build ENU world positions for peaks
        for peak in peakFinder.peaks {
            let enu = gpsToENU(from: userLoc, to: peak.coordinate, toAlt: peak.altitude)
            targets.append(.init(id: peak.id, worldPosition: enu))
        }
        
        // Build ENU world positions for history points
        for point in historyPoints {
            let enu = gpsToENU(from: userLoc, to: point.coordinate, toAlt: point.gpsAltitude)
            targets.append(.init(id: point.id, worldPosition: enu))
        }
        
        occlusionManager.checkOcclusion(targets: targets)
    }
    
    /// Convert GPS coordinate + altitude to ARKit world space (ENU) relative to user.
    /// Includes Earth curvature compensation for distant points (>5km).
    private func gpsToENU(from userLoc: CLLocation, to coord: CLLocationCoordinate2D, toAlt: Double) -> simd_float3 {
        let latRef = userLoc.coordinate.latitude * .pi / 180
        let metersPerDegreeLat = 111_320.0
        let metersPerDegreeLon = 111_320.0 * cos(latRef)
        
        let dLat = coord.latitude - userLoc.coordinate.latitude
        let dLon = coord.longitude - userLoc.coordinate.longitude
        
        let north = dLat * metersPerDegreeLat
        let east = dLon * metersPerDegreeLon
        
        // Earth curvature correction for distant points
        let horizontalDist = sqrt(north * north + east * east)
        let earthRadius = 6_371_000.0 // meters
        let curvatureDrop = (horizontalDist * horizontalDist) / (2.0 * earthRadius)
        
        // Apply curvature correction for points >5km away
        let up = (toAlt - userLoc.altitude) - (horizontalDist > 5000 ? curvatureDrop : 0)
        
        // ARKit gravityAndHeading: +X = East, +Y = Up, −Z = North
        return simd_float3(Float(east), Float(up), Float(-north))
    }
    
    private func bearing(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> Double {
        let lat1 = start.latitude * .pi / 180
        let lat2 = end.latitude * .pi / 180
        let dLon = (end.longitude - start.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        var b = atan2(y, x) * 180 / .pi
        if b < 0 { b += 360 }
        return b
    }
}

#Preview {
    GeoNatureView()
}
