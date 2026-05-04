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
    /// Builds the terrain-aware skyline that `HorizonOverlayView`
    /// renders instead of the geometric horizon when data is available.
    @StateObject private var skylineCalculator = SkylineCalculator()
    @State private var cameraPermissionGranted = false
    @State private var showPermissionAlert = false
    @State private var historyPoints: [ARHistoryPoint] = []

    /// Tracks whether this view is the user's currently visible tab AND
    /// the app is in the foreground. Drives `ARCameraView.isActive` and
    /// gates the AR-related work loops so we don't burn battery while
    /// the Nature tab is off-screen.
    @State private var isOnScreen: Bool = false
    @Environment(\.scenePhase) private var scenePhase

    private var isARActive: Bool {
        cameraPermissionGranted && isOnScreen && scenePhase == .active
    }
    
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
                ARCameraView(occlusionManager: occlusionManager,
                             sessionManager: sessionManager,
                             isActive: isARActive)
                    .ignoresSafeArea()

                // Geographic horizon / terrain skyline line — drawn
                // first so peak/history markers sit on top of it.
                HorizonOverlayView(
                    userLocation: overlayLocation,
                    barometerAltitude: app?.barometer?.height,
                    skylineSamples: skylineCalculator.samples,
                    sessionManager: sessionManager
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

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
            isOnScreen = true
            if cameraPermissionGranted {
                startAR()
            }
        }
        .onDisappear {
            isOnScreen = false
            motionManager.stop()
        }
        .onChange(of: cameraPermissionGranted) { _, granted in
            if granted {
                startAR()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                motionManager.stop()
            } else if isOnScreen && cameraPermissionGranted {
                motionManager.start()
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
            // Skip the periodic work entirely when the AR view isn't on
            // screen — keeps battery from being drained on background tabs.
            guard isARActive else { return }
            refreshOverlayLocationIfNeeded()
            searchForPeaks()
            loadHistoryPoints()
        }
        .onReceive(occlusionTimer) { _ in
            guard isARActive else { return }
            runOcclusionCheck()
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
        // Skyline recompute is internally throttled (≥500 m). It runs
        // off the main actor and only mutates `samples` if it gets
        // back a non-empty result, so calling it here on every
        // location refresh is safe.
        skylineCalculator.computeIfNeeded(observer: newLoc)
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

        // Only re-query CoreData if a new sample has been recorded since
        // the last refresh — saves an expensive fetch on every tick.
        history.refreshIfNeeded()

        let maxDistance: CLLocationDistance = 1000
        // Hysteresis: keep an already-displayed point in the scene until the
        // user has moved noticeably further away. This prevents the AR scene
        // from periodically wiping all history markers when CoreData is briefly
        // empty or the user wanders right at the boundary of `maxDistance`.
        let dropDistance: CLLocationDistance = maxDistance * 1.5

        let newPoints = history.historyItems
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

        // Merge with the previous set rather than replacing it. Once a marker
        // has been added to the AR scene we only remove it when it is clearly
        // out of range (`dropDistance`); a transient empty refresh — for
        // example because the CoreData fetch was retried — must not destroy
        // every marker the user is currently looking at.
        var byID: [UUID: ARHistoryPoint] = [:]
        for p in historyPoints { byID[p.id] = p }
        for p in newPoints { byID[p.id] = p }

        historyPoints = byID.values
            .filter { point in
                let pl = CLLocation(latitude: point.coordinate.latitude,
                                    longitude: point.coordinate.longitude)
                return location.distance(from: pl) <= dropDistance
            }
            .sorted { $0.date < $1.date }
    }
    
    private func runOcclusionCheck() {
        guard let userLoc = app?.location?.location else { return }

        // Heuristic: we treat the user as outdoors when GPS reports a
        // wide horizontal accuracy window (typically only achievable
        // outside) OR when the peak finder turned up several distant
        // peaks. Either condition is a strong signal that the local
        // "vertical planes" detected by ARKit are noise rather than
        // real walls.
        let distantPeakCount = peakFinder.peaks.filter { $0.distance > 500 }.count
        let outdoorByAccuracy = userLoc.horizontalAccuracy > 25
        let outdoorByPeaks = distantPeakCount >= 3
        occlusionManager.isOutdoor = outdoorByAccuracy || outdoorByPeaks

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
