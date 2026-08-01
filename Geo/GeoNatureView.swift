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

    /// Minimum peak altitude (metres) to show, set by the on-screen slider
    /// (0…Everest). A live view filter that declutters the horizon by raising
    /// the floor — 0 shows everything. Persisted (`@AppStorage`) so the chosen
    /// floor is remembered across launches, unlike the compass offset.
    @AppStorage("natureMinPeakAltitude") private var minPeakAltitude: Double = 0

    /// Freeze-frame share: the rendered camera + peak overlay (drives the share
    /// sheet). `isCapturing` guards the shutter against a double-tap mid-render.
    @State private var shareImage: ShareImage?
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
        // `shareImage != nil` means the system share sheet is up. A SwiftUI
        // `.sheet` fires neither `onDisappear` on the presenter nor a
        // `scenePhase` change, and `ActivityView` sets no detents — so it covers
        // the screen completely while camera + VIO + the whole overlay loop kept
        // running fully occluded, for as long as the user takes to pick a target
        // app or wait on an upload.
        //
        // `captureShare()` finishes the snapshot AND the `ImageRenderer` pass
        // before it assigns `shareImage`, so the picture is already a rendered
        // `UIImage` by the time this gate closes. `MarkerDetailSheet` is
        // deliberately NOT included: it uses `.presentationDetents([.medium])`,
        // so the AR view stays half-visible behind it.
        cameraPermissionGranted && isOnScreen && scenePhase == .active && shareImage == nil
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

    /// Where the camera is pointing (degrees, 0 = N), from the ARKit camera
    /// transform. ARKit's `.gravityAndHeading` world alignment is true-north
    /// aligned, so this is the true bearing — and being camera-axis it does NOT
    /// gimbal-lock when the phone is held upright at the horizon the way the flat
    /// magnetometer heading (`DeviceMotionManager.heading`) does. Matches how the
    /// Android top bar reads its camera azimuth. Re-evaluates each frame via the
    /// session manager's `frameTick`.
    private var cameraFacingHeading: Double {
        _ = sessionManager.frameTick
        let east = -sessionManager.cameraTransform.columns.2.x
        let north = sessionManager.cameraTransform.columns.2.z
        var deg = atan2(Double(east), Double(north)) * 180 / .pi
        if deg < 0 { deg += 360 }
        return deg
    }

    /// Peaks that pass the on-screen min-altitude filter — the single set the
    /// markers, the tap hit-test and the top-bar count all read, so they always
    /// agree. `< 1` means "no filter" (avoids a pointless full pass at 0).
    private var visiblePeaks: [NearbyPeak] {
        minPeakAltitude < 1 ? peakFinder.peaks
            : peakFinder.peaks.filter { $0.altitude >= minPeakAltitude }
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
                    peaks: visiblePeaks,
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
                        Text(verbatim: "\(visiblePeaks.count)")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.white)

                        Spacer()

                        Image(systemName: "location.north.fill")
                            .rotationEffect(.degrees(cameraFacingHeading))
                            .foregroundStyle(.orange)
                        Text(verbatim: String(format: "%.0f°", cameraFacingHeading))
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

                // Min-altitude filter — a vertical bar on the right edge. Drag
                // the handle up to raise the floor and hide the smaller peaks;
                // the orange band is the altitude range being shown.
                HStack {
                    Spacer()
                    AltitudeFilterSlider(minAltitude: $minPeakAltitude)
                        .padding(.trailing, 10)
                }

                // Shutter — capture the camera frame + peak overlay as a photo to
                // share. Disabled until the AR session is tracking.
                VStack {
                    Spacer()
                    Button {
                        captureShare()
                    } label: {
                        ZStack {
                            Circle().stroke(.white.opacity(0.9), lineWidth: 4)
                                .frame(width: 68, height: 68)
                            Circle().fill(.white).frame(width: 54, height: 54)
                            if isCapturing {
                                ProgressView().tint(.black)
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
                    .accessibilityLabel("Capture photo")
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
        .sheet(item: $shareImage) { share in
            ActivityView(items: [share.image])
        }
    }

    // MARK: - Helpers

    /// Freeze the camera frame, composite the peak/horizon overlay over it, and
    /// present the system share sheet. Fully on-device. The camera snapshot and
    /// the `ImageRenderer` pass run back-to-back on the main actor, so the AR
    /// matrices are frozen for both — the markers line up with the still frame.
    private func captureShare() {
        guard !isCapturing, sessionManager.isTracking else { return }
        isCapturing = true
        // Hop to the next main-actor turn so SwiftUI can render the shutter's
        // busy state before the (main-actor-bound) snapshot + render pass runs.
        Task { @MainActor in
            defer { isCapturing = false }
            guard let cameraImage = sessionManager.snapshot() else { return }
            let size = sessionManager.viewportSize
            guard size.width > 0, size.height > 0 else { return }

            let panorama = NaturePanoramaView(
                cameraImage: cameraImage,
                size: size,
                userLocation: overlayLocation,
                barometerAltitude: app?.barometer?.height,
                observerAltitude: effectiveObserverAltitude,
                peaks: visiblePeaks,
                sessionManager: sessionManager
            )
            let renderer = ImageRenderer(content: panorama)
            renderer.scale = displayScale
            renderer.proposedSize = ProposedViewSize(size)
            if let image = renderer.uiImage {
                shareImage = ShareImage(image: image)
            }
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
                                         offlinePeaks: app?.offlinePack?.combinedPeaks ?? [],
                                         observerAltitude: effectiveObserverAltitude)
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

    /// Nearest peak within the hit radius of `point`. Targets the floating
    /// BANNER (summit lifted by `peakBannerLeaderLength`), i.e. where the label
    /// is actually drawn, so a tap lands on the visible name rather than the
    /// bare summit dot below it.
    private func nearestMarker(to point: CGPoint) -> ARMarkerSelection? {
        guard sessionManager.isTracking else { return nil }
        let hitRadius: CGFloat = 60
        var best: (selection: ARMarkerSelection, dist: CGFloat)?

        for peak in visiblePeaks {
            guard let screen = projectMarker(coordinate: peak.coordinate, altitude: peak.altitude) else { continue }
            let target = CGPoint(x: screen.x, y: screen.y - peakBannerLeaderLength)
            let d = hypot(target.x - point.x, target.y - point.y)
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

/// Everest — the top of the min-altitude filter's range.
private let maxFilterAltitude: Double = 8848

/// Vertical min-altitude filter for the Nature view. The handle's height on the
/// track maps to a minimum peak altitude (0 at the bottom → Everest at the top);
/// the orange band above the handle is the altitude range still shown. Tapping
/// or dragging anywhere on the track sets the value; the value label rounds to a
/// tidy 10 m. Session-only, unobtrusive, matching the view's pill styling.
private struct AltitudeFilterSlider: View {
    @Binding var minAltitude: Double
    private let trackHeight: CGFloat = 200
    private let knob: CGFloat = 18

    var body: some View {
        VStack(spacing: 6) {
            Text(minAltitude < 1 ? "All" : "≥ \(Int(minAltitude.rounded())) m")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())

            GeometryReader { geo in
                let h = geo.size.height
                let frac = CGFloat(min(max(minAltitude / maxFilterAltitude, 0), 1))
                ZStack(alignment: .bottom) {
                    // Track casing.
                    Capsule().fill(.white.opacity(0.18)).frame(width: 5)
                    // The shown band: from the handle up to the top (higher peaks).
                    Capsule().fill(.orange.opacity(0.55))
                        .frame(width: 5, height: h * (1 - frac))
                        .frame(maxHeight: .infinity, alignment: .top)
                    // Handle.
                    Circle()
                        .fill(.orange)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .frame(width: knob, height: knob)
                        .offset(y: -(h - knob) * frac)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // y grows downward; invert so the top of the track is
                            // the maximum altitude. Round to a tidy 10 m step.
                            let clampedY = min(max(0, value.location.y), h)
                            let raw = Double(1 - clampedY / h) * maxFilterAltitude
                            minAltitude = (raw / 10).rounded() * 10
                        }
                )
            }
            .frame(width: 44, height: trackHeight)
        }
        .accessibilityLabel("Minimum peak altitude")
        .accessibilityValue(minAltitude < 1 ? "All peaks" : "\(Int(minAltitude.rounded())) metres and up")
    }
}

/// Off-screen composite rendered by the shutter: the frozen camera frame with
/// the SAME horizon line and peak banners drawn over it. The overlays re-project
/// through the live `sessionManager` matrices, which — because the snapshot and
/// this render run back-to-back on the main actor — still match the frozen
/// frame, so the markers land on the right summits in the shared photo.
private struct NaturePanoramaView: View {
    let cameraImage: UIImage
    let size: CGSize
    let userLocation: CLLocation?
    let barometerAltitude: Double?
    let observerAltitude: Double?
    let peaks: [NearbyPeak]
    @ObservedObject var sessionManager: ARSessionManager

    var body: some View {
        ZStack {
            Image(uiImage: cameraImage)
                .resizable()
                .frame(width: size.width, height: size.height)

            HorizonOverlayView(
                userLocation: userLocation,
                barometerAltitude: barometerAltitude,
                sessionManager: sessionManager
            )

            PeakOverlayView(
                peaks: peaks,
                userLocation: userLocation,
                observerAltitude: observerAltitude,
                sessionManager: sessionManager
            )
        }
        .frame(width: size.width, height: size.height)
    }
}

#Preview {
    GeoNatureView()
}
