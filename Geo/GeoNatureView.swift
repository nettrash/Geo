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

/// The Nature tab does exactly one thing: **identify the peaks you can see
/// through the camera**.
///
/// On screen that means three layers, and nothing else:
///
/// 1. `ARCameraView` — the live camera, world-tracked with `.gravityAndHeading`
///    so we know which way is north and which way is down.
/// 2. `HorizonOverlayView` — the geometric horizon line with N/NE/E/SE/S/SW/W/NW
///    markers welded to true compass bearings, for orientation.
/// 3. `PeakOverlayView` — one marker per nearby named peak, projected from its
///    real GPS position. Tap a marker to identify it.
///
/// Plus one affordance that exists *because* the goal is real-world alignment: a
/// horizontal swipe nudges the compass offset (`headingAlignmentDeg`), because a
/// phone magnetometer is realistically 5–15° out and that error is the
/// difference between a marker sitting on the summit and sitting on the wrong
/// mountain.
struct GeoNatureView: View {
    var app: GeoAppDelegate?

    @StateObject private var peakFinder = PeakFinder()
    @StateObject private var motionManager = DeviceMotionManager()
    @StateObject private var sessionManager = ARSessionManager()
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

    /// Tracks whether this view is the user's currently visible tab AND
    /// the app is in the foreground. Drives `ARCameraView.isActive` and
    /// gates the AR-related work loops so we don't burn battery while
    /// the Nature tab is off-screen.
    @State private var isOnScreen: Bool = false
    @Environment(\.scenePhase) private var scenePhase

    private var isARActive: Bool {
        cameraPermissionGranted && isOnScreen && scenePhase == .active
    }

    /// Stable location snapshot passed to the overlays.
    /// Only updated when the user moves more than 5 m, preventing GPS jitter
    /// from causing PeakOverlayView to re-render and toggle edge-case markers.
    @State private var overlayLocation: CLLocation?

    /// Timer that fires every 5 seconds to refresh peak data.
    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    /// ONE observer altitude for every AR consumer (the horizon line, the marker
    /// projection and the tap hit-test), so none of them can vertically detach
    /// from the others. The barometer is preferred because it's far more
    /// accurate vertically than GPS — but it reads exactly 0 until its first
    /// sample lands (and permanently on barometer-less devices), so a
    /// non-positive value is treated as absent rather than clamping the observer
    /// to sea level.
    private var effectiveObserverAltitude: Double? {
        (app?.barometer?.height).flatMap { $0 > 0 ? $0 : nil }
            ?? overlayLocation?.altitude
    }

    var body: some View {
        ZStack {
            if cameraPermissionGranted {
                // 1. AR camera background.
                ARCameraView(sessionManager: sessionManager, isActive: isARActive)
                    .ignoresSafeArea()

                // 2. Geometric horizon line + cardinal markers — drawn first so
                // peak markers sit on top of it.
                HorizonOverlayView(
                    userLocation: overlayLocation,
                    barometerAltitude: app?.barometer?.height,
                    sessionManager: sessionManager
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

                // 3. Peak markers, projected GPS→ENU→ARKit. This is the point of
                // the tab.
                PeakOverlayView(
                    peaks: peakFinder.peaks,
                    userLocation: overlayLocation,
                    observerAltitude: effectiveObserverAltitude,
                    sessionManager: sessionManager
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

                // Transparent tap/pan-catch layer: a tap runs a screen-space
                // nearest-marker hit-test against the projected peak positions
                // and opens the detail sheet; a horizontal PAN adjusts the
                // manual compass alignment live. Sits above the
                // (non-interactive) markers.
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

                // Minimal top bar: how many peaks we found, and where we're
                // pointing. Nothing else — the diagnostic chips (LiDAR, depth
                // source, scan/skyline progress) were noise on a tab whose job
                // is to name mountains.
                VStack {
                    HStack {
                        Image(systemName: "mountain.2.fill")
                            .foregroundStyle(.orange)
                        Text(verbatim: "\(peakFinder.peaks.count)")
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
        .sheet(item: $selectedMarker) { marker in
            MarkerDetailSheet(selection: marker)
        }
    }

    // MARK: - Helpers

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
        guard let location = app?.location?.location else { return }
        Task {
            await peakFinder.searchPeaks(near: location, mountainsData: app?.mountainsData,
                                         offlinePeaks: app?.offlinePack?.combinedPeaks ?? [])
        }
    }

    // MARK: - Tap-to-identify

    /// Project a GPS marker to screen points using the SAME path as
    /// `PeakOverlayView` (Geometry.gpsToENU → sessionManager.worldPoint →
    /// projectToScreen), so the hit-test agrees with what's drawn.
    private func projectMarker(coordinate: CLLocationCoordinate2D, altitude: Double) -> CGPoint? {
        guard let userLoc = overlayLocation, sessionManager.isTracking else { return nil }
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
    /// never select a marker that isn't actually drawn.
    private func isMarkerOnScreen(_ screen: CGPoint) -> Bool {
        let vp = sessionManager.viewportSize
        let margin: CGFloat = 50
        return screen.x > -margin && screen.x < vp.width + margin
            && screen.y > -margin && screen.y < vp.height + margin
    }

    /// Nearest peak marker within the hit radius of `point`.
    private func nearestMarker(to point: CGPoint) -> ARMarkerSelection? {
        guard sessionManager.isTracking else { return nil }
        let hitRadius: CGFloat = 60
        var best: (selection: ARMarkerSelection, dist: CGFloat)?

        for peak in peakFinder.peaks {
            guard let screen = projectMarker(coordinate: peak.coordinate, altitude: peak.altitude) else { continue }
            let d = hypot(screen.x - point.x, screen.y - point.y)
            if d <= hitRadius, best == nil || d < best!.dist { best = (.peak(peak), d) }
        }
        return best?.selection
    }
}

// MARK: - Manual compass alignment (pure pan→degrees conversion)

/// Points of horizontal pan per degree of manual compass alignment.
/// ~8 pt/° feels right at arm's length: nudging a 5–15° compass error takes
/// a comfortable 40–120 pt swipe, precise enough to line a distant summit
/// up with its real position without overshooting.
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
