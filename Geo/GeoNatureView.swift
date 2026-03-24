//
//  GeoNatureView.swift
//  Geo
//
//  Created by nettrash on 18/06/2024.
//

import SwiftUI
import AVFoundation
import CoreLocation
import Combine

struct GeoNatureView: View {
    var app: GeoAppDelegate?
    
    @StateObject private var peakFinder = PeakFinder()
    @StateObject private var motionManager = DeviceMotionManager()
    @State private var cameraPermissionGranted = false
    @State private var showPermissionAlert = false
    @State private var historyPoints: [ARHistoryPoint] = []
    
    /// Timer that fires every 5 seconds to refresh data
    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ZStack {
            if cameraPermissionGranted {
                // AR Camera background
                ARCameraView()
                    .ignoresSafeArea()
                
                // Peak and history markers overlay
                PeakOverlayView(
                    peaks: peakFinder.peaks,
                    historyPoints: historyPoints,
                    userLocation: app?.location?.location,
                    heading: motionManager.heading,
                    pitch: motionManager.pitch
                )
                .ignoresSafeArea()
                
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
                searchForPeaks()
                loadHistoryPoints()
            }
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
        searchForPeaks()
        loadHistoryPoints()
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
            await peakFinder.searchPeaks(
                near: location,
                mountainsData: app?.mountainsData
            )
        }
    }
    
    private func loadHistoryPoints() {
        guard let location = app?.location?.location,
              let history = app?.history else {
            // Retry if data isn't ready yet
            Task {
                try? await Task.sleep(for: .seconds(2))
                loadHistoryPoints()
            }
            return
        }
        
        // Refresh history data
        history.Refresh()
        
        // Convert HistoryItem to ARHistoryPoint, filtering to those within 1km
        let maxDistance: CLLocationDistance = 1000
        
        historyPoints = history.historyItems
            .suffix(50) // last 50 history items at most
            .compactMap { item -> ARHistoryPoint? in
                let itemLocation = CLLocation(latitude: item.gpsLatitude, longitude: item.gpsLongitude)
                let distance = location.distance(from: itemLocation)
                
                guard distance <= maxDistance else { return nil }
                // Skip items too close (< 1m) — they'd overlap with current position
                guard distance > 1 else { return nil }
                
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
    
    /// Calculate bearing (in degrees) from one coordinate to another
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
