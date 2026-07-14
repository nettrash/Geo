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
    /// Tracks the current camera authorization state so the pre-prompt
    /// view can show non-coercive button wording. Apple rejected an
    /// earlier build (Guideline 5.1.1(iv)) for pre-pending an "Allow
    /// Camera Access" button before the system permission prompt;
    /// the fix is to use "Continue" for `.notDetermined` and to deep-link
    /// straight to Settings for `.denied` / `.restricted`.
    @State private var cameraAuthStatus: AVAuthorizationStatus = .notDetermined

    /// Tap-to-identify: the marker the user tapped (drives the detail sheet).
    @State private var selectedMarker: ARMarkerSelection?
    /// Manual compass alignment: the offset value at the start of the
    /// current pan, so the drag applies `base + translation` rather than
    /// compounding per-event deltas. `nil` when no pan is in flight.
    @State private var alignmentDragBaseDeg: Double?
    /// Freeze-frame share: the rendered annotated panorama (drives the share sheet).
    @State private var shareImage: ShareImage?
    /// Guards the shutter so a second tap can't start a second capture mid-render.
    @State private var isCapturing = false
    /// Render scale for the off-screen `ImageRenderer` capture.
    @Environment(\.displayScale) private var displayScale

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

    /// ONE source of truth for the observer altitude across every AR
    /// consumer: the DEM-anchored value the skyline was computed with
    /// (`SkylineCalculator.observerAltitudeUsed`), falling back to the
    /// baro-preferred / GPS sensor expression until the first skyline pass
    /// publishes it. Threaded into the welded-pill selection, the tap
    /// hit-tests, the AR marker projection and the occlusion targets so
    /// none of them can vertically detach from the drawn silhouette.
    private var effectiveObserverAltitude: Double? {
        skylineCalculator.observerAltitudeUsed
            ?? (app?.barometer?.height).flatMap { $0 > 0 ? $0 : nil }
            ?? overlayLocation?.altitude
    }

    /// Peaks whose name is welded to the skyline ridge (HorizonOverlayView).
    /// Their AR markers are suppressed so a silhouette peak shows EITHER a ridge
    /// pill OR nothing — never a flat AR marker. Camera-INDEPENDENT
    /// (`peakOnSilhouette`), so it's a stable superset of what the horizon
    /// overlay actually welds: every drawn pill is suppressed here, and a peak
    /// dropped from the welded labels (de-collision / heading window / cap) is
    /// hidden rather than falling back to a flat, unrotated, leaderless marker
    /// that would clutter the ridge and not match the welded pills.
    private var weldedPeakIDs: Set<UUID> {
        guard let loc = overlayLocation, !skylineCalculator.samples.isEmpty else { return [] }
        let obsAlt = effectiveObserverAltitude ?? loc.altitude
        return Set(peakFinder.peaks
            .filter { peakOnSilhouette($0, skyline: skylineCalculator.samples, observerAltitude: obsAlt) }
            .map { $0.id })
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
                    observerAltitudeUsed: skylineCalculator.observerAltitudeUsed,
                    skylineSamples: skylineCalculator.samples,
                    peaks: peakFinder.peaks,
                    sessionManager: sessionManager
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

                // Peak markers positioned via GPS→ENU→ARKit projection. History
                // points are intentionally NOT shown in the AR scene (they
                // cluttered the view); they remain on the Map and Stat tabs.
                PeakOverlayView(
                    // Peaks welded to the skyline ridge are labelled there
                    // instead of getting a duplicate AR marker.
                    peaks: peakFinder.peaks.filter { !weldedPeakIDs.contains($0.id) },
                    userLocation: overlayLocation,
                    observerAltitude: effectiveObserverAltitude,
                    sessionManager: sessionManager,
                    occlusionManager: occlusionManager
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

                // Transparent tap/pan-catch layer: a tap runs a screen-space
                // nearest-marker hit-test against the projected peak/history
                // positions and opens the detail sheet; a horizontal PAN
                // adjusts the manual compass alignment live. Sits above the
                // (non-interactive) markers but below the shutter button.
                //
                // Gesture composition: `onTapGesture` and a `DragGesture`
                // with `minimumDistance: 12` don't compete — a tap never
                // travels 12 pt so the drag stays inactive, and a pan
                // exceeds the tap recognizer's movement slop so the tap
                // fails. Tap-to-identify keeps working unchanged.
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture(coordinateSpace: .local) { location in
                        if let marker = nearestMarker(to: location) {
                            selectedMarker = marker
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 12)
                            .onChanged { value in
                                // Latch the offset at pan start; every event
                                // recomputes from base + TOTAL translation
                                // (pure, clamped ±30°). Drag right → offset
                                // up → overlay moves right, following the
                                // finger (see ARSessionManager doc).
                                let base = alignmentDragBaseDeg ?? sessionManager.headingAlignmentDeg
                                alignmentDragBaseDeg = base
                                sessionManager.headingAlignmentDeg = alignmentOffsetDegrees(
                                    base: base, panTranslationX: value.translation.width)
                            }
                            .onEnded { _ in alignmentDragBaseDeg = nil }
                    )

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
                .allowsHitTesting(false)

                // Top info bar
                VStack {
                    HStack {
                        Image(systemName: "mountain.2.fill")
                            .foregroundStyle(.orange)
                        Text(verbatim: "\(peakFinder.peaks.count)")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.white)

                        // History points are no longer shown in the AR scene.

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
                        
                        // Skyline loading indicator
                        if skylineCalculator.isComputing {
                            Image(systemName: "mountain.2")
                                .foregroundStyle(.green)
                                .font(.system(size: 12))
                                .symbolEffect(.pulse)
                            Text("Skyline")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.green)
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
                .allowsHitTesting(false)

                // Manual compass-alignment chip — visible while an alignment
                // offset is applied (≥0.5°, i.e. would display as ≥1°).
                // Unobtrusive, matches the view's pill styling; tapping it
                // (✕) resets the offset. Session-only state — deliberately
                // never persisted, compass error differs every session.
                if abs(sessionManager.headingAlignmentDeg) >= 0.5 {
                    VStack {
                        Button {
                            sessionManager.headingAlignmentDeg = 0
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.left.and.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.orange)
                                Text(verbatim: String(format: "Alignment %+.0f°",
                                                      sessionManager.headingAlignmentDeg))
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white)
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.55), in: Capsule())
                        }
                        .accessibilityLabel("Reset compass alignment")
                        Spacer()
                    }
                    .padding(.top, 44)
                }

                // Shutter — capture a frozen, annotated panorama to share.
                VStack {
                    Spacer()
                    Button {
                        captureShare()
                    } label: {
                        ZStack {
                            Circle()
                                .stroke(.white.opacity(0.9), lineWidth: 4)
                                .frame(width: 68, height: 68)
                            Circle()
                                .fill(.white)
                                .frame(width: 54, height: 54)
                            if isCapturing {
                                ProgressView()
                                    .tint(.black)
                            } else {
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(.black)
                            }
                        }
                    }
                    .disabled(!sessionManager.isTracking || isCapturing)
                    .opacity(sessionManager.isTracking ? 1 : 0.4)
                    .padding(.bottom, 28)
                    .accessibilityLabel("Capture panorama")
                }
            } else {
                // Camera permission not granted. We split this into two
                // states so the button never *asks* the user to "allow"
                // anything — Apple's review team flagged that wording
                // under Guideline 5.1.1(iv).
                //
                // • notDetermined → neutral "Continue" that proceeds to
                //   the system permission prompt. The system prompt is
                //   the only place where the user can grant access; we
                //   don't pre-empt its language.
                // • denied / restricted → "Open Settings" that deep-links
                //   into iOS Settings, which is the only path back from
                //   a previous denial.
                VStack(spacing: 20) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.secondary)

                    Text("About the Nature view")
                        .font(.title2.bold())

                    Text(natureExplanation)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)

                    if cameraAuthStatus == .notDetermined {
                        Button("Continue") {
                            requestCameraPermission()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    } else {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }
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
            // Stop the in-flight skyline pass so its thousands of
            // Open-Elevation batches don't keep running once the user
            // leaves the Nature tab. The calculator is reused, so a
            // later location refresh can launch a fresh recompute.
            skylineCalculator.cancel()
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
                // Heading only — the AR view derives attitude from ARKit's
                // camera transform and reads just `heading` for the top-bar
                // compass, so skip the 30 Hz CMDeviceMotion attitude stream.
                motionManager.start(includeAttitude: false)
            }
            // The user may have flipped the Geo camera switch in
            // Settings while we were inactive — re-read the
            // authorisation status so the gate UI updates without
            // needing a fresh `onAppear`.
            if phase == .active { checkCameraPermission() }
        }
        .onReceive(refreshTimer) { _ in
            // Skip the periodic work entirely when the AR view isn't on
            // screen — keeps battery from being drained on background tabs.
            guard isARActive else { return }
            refreshOverlayLocationIfNeeded()
            searchForPeaks()
        }
        .onReceive(occlusionTimer) { _ in
            guard isARActive else { return }
            runOcclusionCheck()
        }
        .sheet(item: $selectedMarker) { marker in
            MarkerDetailSheet(selection: marker)
        }
        .sheet(item: $shareImage) { share in
            ActivityView(items: [share.image])
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
    
    /// Description shown above the action button in the pre-AR view.
    /// Wording differs by state so a user who already denied access
    /// gets a Settings-aware sentence instead of being told (again)
    /// that the feature needs the camera.
    private var natureExplanation: LocalizedStringKey {
        switch cameraAuthStatus {
        case .denied, .restricted:
            return "The Nature view shows nearby mountain peaks overlaid on the camera. Camera access is currently turned off for Geo. You can re-enable it in iOS Settings and return to this tab."
        default:
            return "The Nature view shows nearby mountain peaks overlaid on the camera. Continue to choose whether to grant camera access."
        }
    }

    private func checkCameraPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        cameraAuthStatus = status
        switch status {
        case .authorized:
            cameraPermissionGranted = true
        case .notDetermined:
            cameraPermissionGranted = false
        case .denied, .restricted:
            cameraPermissionGranted = false
        @unknown default:
            cameraPermissionGranted = false
        }
    }

    private func requestCameraPermission() {
        // Only call into the system prompt while the status is still
        // `.notDetermined`. Once denied, the prompt no longer surfaces;
        // the user has to flip the switch in Settings.
        guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else {
            cameraAuthStatus = AVCaptureDevice.authorizationStatus(for: .video)
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor in
                cameraPermissionGranted = granted
                cameraAuthStatus = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }
    
    private func startAR() {
        // Heading only — see the scenePhase handler; the AR view never reads
        // pitch/roll, so the 30 Hz attitude stream would just drain battery.
        motionManager.start(includeAttitude: false)
        refreshOverlayLocationIfNeeded()
        searchForPeaks()
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
        // `Barometer.height` is an absolute altitude that stays exactly
        // 0 until the first altimeter sample lands (and permanently on
        // devices without a barometer). Treat a non-positive value as
        // absent so `SkylineCalculator` falls back to GPS altitude
        // instead of computing the skyline at sea level. Mirrors the
        // Android call site's `takeIf { it > 0 }`.
        skylineCalculator.computeIfNeeded(observer: newLoc,
                                          barometerAltitude: (app?.barometer?.height).flatMap { $0 > 0 ? $0 : nil })
    }
    
    private func searchForPeaks() {
        guard let location = app?.location?.location else { return }
        Task {
            await peakFinder.searchPeaks(near: location, mountainsData: app?.mountainsData,
                                         offlinePeaks: app?.offlinePack?.combinedPeaks ?? [])
        }
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

        // Anchor targets to the live camera world position, exactly as
        // PeakOverlayView/HorizonOverlayView do when rendering, via the
        // shared `sessionManager.worldPoint(east:up:north:)` projection.
        // ARKit's world origin is the session-start pose, so the camera
        // drifts away from it as the user moves; without this offset the
        // occlusion test (camera-relative) would be off by the full
        // camera translation and disagree with where the marker is drawn.

        // Build ENU world positions for peaks. Origin altitude is the SAME
        // effective observer altitude the skyline and the marker overlay
        // use, so the occlusion test agrees with where markers are drawn.
        let originAlt = effectiveObserverAltitude ?? userLoc.altitude
        for peak in peakFinder.peaks {
            let (east, north, up) = Geometry.gpsToENU(
                from: userLoc.coordinate, originAltitude: originAlt,
                to: peak.coordinate, targetAltitude: peak.altitude
            )
            targets.append(.init(id: peak.id, worldPosition: sessionManager.worldPoint(east: east, up: up, north: north)))
        }

        // History points are not shown in the AR scene, so they need no
        // occlusion targets.

        occlusionManager.checkOcclusion(targets: targets)
    }

    // MARK: - Tap-to-identify + freeze-frame capture

    /// Project a GPS marker to screen points using the SAME path as
    /// `PeakOverlayView` (Geometry.gpsToENU → sessionManager.worldPoint →
    /// projectToScreen), so the hit-test agrees with what's drawn.
    private func projectMarker(coordinate: CLLocationCoordinate2D, altitude: Double) -> CGPoint? {
        guard let userLoc = overlayLocation, sessionManager.isTracking else { return nil }
        // Same effective observer altitude as PeakOverlayView's projection,
        // so the hit-test agrees with what's drawn.
        let enu = Geometry.gpsToENU(
            from: userLoc.coordinate, originAltitude: effectiveObserverAltitude ?? userLoc.altitude,
            to: coordinate, targetAltitude: altitude
        )
        let world = sessionManager.worldPoint(east: enu.east, up: enu.up, north: enu.north)
        guard let screen = sessionManager.projectToScreen(world),
              isMarkerOnScreen(screen) else { return nil }
        return screen
    }

    /// The same on-screen margin cull `PeakOverlayView` uses, so the hit-test can
    /// never select a marker (or welded label) that isn't actually drawn.
    private func isMarkerOnScreen(_ screen: CGPoint) -> Bool {
        let vp = sessionManager.viewportSize
        let margin: CGFloat = 50
        return screen.x > -margin && screen.x < vp.width + margin
            && screen.y > -margin && screen.y < vp.height + margin
    }

    /// Whether a marker is currently visible — the same gate `PeakOverlayView`
    /// applies (not occluded, and either far enough or the mesh is ready) — so
    /// the user can't tap (or capture) an invisible marker.
    private func markerVisible(id: UUID, distance: Double) -> Bool {
        let nearbyThreshold = 100.0
        guard !occlusionManager.occludedIDs.contains(id) else { return false }
        return distance >= nearbyThreshold || occlusionManager.isSceneReady
    }

    /// Bearing-window centre for welded-label queries: the camera heading
    /// (degrees, 0 = N) from the AR camera transform, COMPENSATED by the
    /// manual alignment offset — the same formula and compensation
    /// `HorizonOverlayView` uses (`worldPoint` rotates drawn content by
    /// +offset, so the true bearing at the screen centre is
    /// cameraHeading − offset), so the hit-test welds against exactly the
    /// labels the overlay drew.
    private var contentHeadingDeg: Double {
        let east = -sessionManager.cameraTransform.columns.2.x
        let north = sessionManager.cameraTransform.columns.2.z
        var deg = atan2(Double(east), Double(north)) * 180 / .pi
        if deg < 0 { deg += 360 }
        return deg - sessionManager.headingAlignmentDeg
    }

    /// Nearest visible marker within the hit radius of `point`. Peaks (drawn on
    /// top) win near-ties, so a history point must be strictly closer to be picked.
    private func nearestMarker(to point: CGPoint) -> ARMarkerSelection? {
        guard sessionManager.isTracking else { return nil }
        let hitRadius: CGFloat = 60
        var best: (selection: ARMarkerSelection, dist: CGFloat)?

        // Same effective observer altitude the overlay welded its pills with.
        let obsAlt = effectiveObserverAltitude ?? 0

        // Welded peaks are drawn as floating ridge pills, not AR markers, so their
        // tap target is the pill. Test ONLY the labels actually drawn (the same
        // dedup'd/​capped selection the overlay renders) so a tap can't hit a
        // suppressed-pill peak or resolve to a nearer/farther mix-up; target the
        // pill centre (anchor lifted by `peakHorizonLabelLift`).
        let welded = weldedPeakIDs
        let drawnLabels = weldedPeakLabels(
            peaks: peakFinder.peaks, skyline: skylineCalculator.samples,
            observerAltitude: obsAlt, headingDeg: contentHeadingDeg,
            size: sessionManager.viewportSize, sessionManager: sessionManager)
        for label in drawnLabels {
            let target = CGPoint(x: label.position.x, y: label.position.y - peakHorizonLabelLift)
            let d = hypot(target.x - point.x, target.y - point.y)
            if d <= hitRadius, best == nil || d < best!.dist,
               let peak = peakFinder.peaks.first(where: { $0.id == label.peakID }) {
                best = (.peak(peak), d)
            }
        }
        // Non-welded peaks keep their AR marker (welded ones are suppressed there).
        for peak in peakFinder.peaks where !welded.contains(peak.id)
            && markerVisible(id: peak.id, distance: peak.distance) {
            guard let screen = projectMarker(coordinate: peak.coordinate, altitude: peak.altitude) else { continue }
            let d = hypot(screen.x - point.x, screen.y - point.y)
            if d <= hitRadius, best == nil || d < best!.dist { best = (.peak(peak), d) }
        }
        // History points are not shown in the AR scene, so they aren't tappable.
        return best?.selection
    }

    /// Capture the live camera frame + overlays into one annotated panorama and
    /// present the system share sheet. Fully on-device. The camera snapshot and
    /// the `ImageRenderer` pass run back-to-back on the main actor, so the AR
    /// matrices are frozen for both — the markers line up with the still frame.
    private func captureShare() {
        guard !isCapturing, sessionManager.isTracking else { return }
        isCapturing = true
        // Hop to the next main-actor turn so SwiftUI can render the shutter's
        // busy state before the snapshot + ImageRenderer pass (both main-actor-
        // bound) block. The snapshot and render still run back-to-back in this
        // task, so the frozen camera frame and the projected markers stay
        // consistent with each other.
        Task { @MainActor in
            defer { isCapturing = false }
            guard let cameraImage = sessionManager.snapshot() else { return }
            let size = sessionManager.viewportSize
            guard size.width > 0, size.height > 0 else { return }

            let visibleMarkers =
                peakFinder.peaks.filter { markerVisible(id: $0.id, distance: $0.distance) }.count

            let panorama = SharePanoramaView(
                cameraImage: cameraImage,
                size: size,
                peaks: peakFinder.peaks,
                userLocation: overlayLocation,
                barometerAltitude: (app?.barometer?.height).flatMap { $0 > 0 ? $0 : nil },
                observerAltitudeUsed: skylineCalculator.observerAltitudeUsed,
                skylineSamples: skylineCalculator.samples,
                sessionManager: sessionManager,
                occlusionManager: occlusionManager,
                markerCount: visibleMarkers
            )

            let renderer = ImageRenderer(content: panorama)
            renderer.scale = displayScale
            renderer.proposedSize = ProposedViewSize(size)
            if let image = renderer.uiImage {
                shareImage = ShareImage(image: image)
            }
        }
    }

}

// MARK: - Manual compass alignment (pure pan→degrees conversion)

/// Points of horizontal pan per degree of manual compass alignment.
/// ~8 pt/° feels right at arm's length: nudging a 5–15° compass error takes
/// a comfortable 40–120 pt swipe, precise enough to line a distant summit
/// up with its drawn silhouette without overshooting.
let alignmentPanPointsPerDegree: Double = 8

/// Hard clamp on the total manual alignment. Compass error is realistically
/// 5–15°; ±30° is generous headroom while preventing an accidental swipe
/// from spinning the panorama into nonsense.
let alignmentMaxOffsetDeg: Double = 30

/// Pure pan→alignment conversion: the new alignment offset (degrees)
/// produced by a pan whose TOTAL horizontal translation is
/// `panTranslationX` points, starting from `base` degrees.
///
/// SIGN: a drag RIGHT (positive translation) increases the offset, which
/// `ARSessionManager.worldPoint` turns into a clockwise bearing rotation of
/// all drawn content — i.e. the overlay moves RIGHT, following the finger
/// (see `ARSessionManager.headingAlignmentDeg` for the full derivation).
/// The result is clamped to ±`alignmentMaxOffsetDeg`.
func alignmentOffsetDegrees(base: Double, panTranslationX: Double) -> Double {
    min(max(base + panTranslationX / alignmentPanPointsPerDegree,
            -alignmentMaxOffsetDeg), alignmentMaxOffsetDeg)
}

#Preview {
    GeoNatureView()
}
