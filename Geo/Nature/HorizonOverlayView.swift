//
//  HorizonOverlayView.swift
//  Geo
//
//  Created by nettrash on 03/05/2026.
//

import SwiftUI
import CoreLocation
import simd

/// Draws the geometric horizon visible from the observer's location on top of
/// the AR camera feed, with cardinal-direction markers welded to true compass
/// bearings.
///
/// The line assumes a smooth sea-level Earth: every point sits at altitude 0 at
/// the geometric horizon distance `d = sqrt(2·R·h + h²)`, dropped by the
/// Earth-curvature term so it lands *h* metres below eye level. That makes it
/// purely a function of the observer's altitude — no digital-elevation model, no
/// network, nothing that can drift out of agreement with the real world. (An
/// earlier version rendered a DEM-derived terrain silhouette with peak names
/// welded onto the ridge; it was removed because the modelled ridge rarely lined
/// up with the real one on camera. Peaks are now identified by their own AR
/// markers — see `PeakOverlayView`.)
///
/// Every point is projected through the AR camera matrices via the shared
/// `sessionManager.worldPoint(...)` / `projectToScreen(...)` path, so the line
/// and its labels stay welded to the world as the device moves — and pick up the
/// user's manual compass alignment offset for free.
struct HorizonOverlayView: View {
    let userLocation: CLLocation?
    /// Optional barometer altitude. Used in preference to GPS altitude when
    /// available because it tends to be much more accurate vertically. It reads
    /// exactly 0 until the first altimeter sample lands (and permanently on
    /// barometer-less devices), so a non-positive value is treated as absent and
    /// we fall back to GPS rather than clamping the observer to sea level.
    let barometerAltitude: Double?
    @ObservedObject var sessionManager: ARSessionManager

    /// Effective Earth radius with standard refraction folded in.
    private let earthRadius: Double = Geometry.effectiveEarthRadius

    /// One horizon vertex every `sampleStepDeg` degrees of bearing.
    private let sampleStepDeg: Double = 1.0

    /// Half-width (in degrees) of the bearing window sampled around the camera's
    /// current heading. 110° gives generous head-room outside the ~60° device
    /// FOV so the line doesn't visibly truncate as the user swings the camera.
    private let headingHalfWindowDeg: Double = 110.0

    /// Maximum gap (in screen points) between consecutive samples that we'll
    /// connect with a straight line.
    private let maxSegmentGap: CGFloat = 600

    var body: some View {
        // Read the per-frame tick so SwiftUI re-evaluates this body every frame.
        // The camera matrices are plain (non-@Published) properties on
        // `sessionManager`, so this is the only signal that keeps the projected
        // horizon line live as the device moves.
        _ = sessionManager.frameTick
        return GeometryReader { geometry in
            let layout = horizonLayout(in: geometry.size)

            ZStack {
                HorizonPathView(segments: layout.segments)
                HorizonLabelsView(labels: layout.labels)
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Geometry

    private struct HorizonLayout {
        var segments: [[CGPoint]]
        var labels: [HorizonLabel]
    }

    private func horizonLayout(in size: CGSize) -> HorizonLayout {
        guard let userLoc = userLocation, sessionManager.isTracking else {
            return HorizonLayout(segments: [], labels: [])
        }

        // Effective observer height above sea level, in metres.
        let observerAltitude = barometerAltitude.flatMap { $0 > 0 ? $0 : nil }
            ?? userLoc.altitude
        // Floor so very-low altitudes still produce a meaningful line.
        let h = max(observerAltitude, 1.5)

        let horizonDist = sqrt(2 * earthRadius * h + h * h)

        // Camera heading (degrees, 0 = N, 90 = E). The camera looks down its
        // local −Z axis; the −Z column of the world transform is the forward
        // vector in ARKit's gravityAndHeading frame.
        let camFwdEast = -sessionManager.cameraTransform.columns.2.x
        let camFwdNorth = sessionManager.cameraTransform.columns.2.z
        var headingDeg = atan2(Double(camFwdEast), Double(camFwdNorth)) * 180 / .pi
        if headingDeg < 0 { headingDeg += 360 }

        // Bearing-window centre, compensated for the manual compass alignment:
        // `worldPoint` rotates all drawn content by +offset (a point at true
        // bearing θ renders where θ + offset would), so the TRUE bearing now
        // facing the screen centre is (cameraHeading − offset). Windowing on the
        // raw camera heading would cull visible content on one screen edge and
        // waste the head-room on the other as the offset grows.
        let contentHeadingDeg = headingDeg - sessionManager.headingAlignmentDeg

        // Every horizon point sits at sea level (altitude 0) at `horizonDist`.
        // Its apparent height relative to the observer is therefore
        // (0 − observerAltitude), further dropped by the Earth-curvature term
        // over that distance. Together these produce the standard horizon dip
        // angle √(2h/R). Both terms are bearing-independent, so hoist them.
        let curvatureDrop = (horizonDist * horizonDist) / (2 * earthRadius)
        let up = -observerAltitude - curvatureDrop

        var segments: [[CGPoint]] = []
        var current: [CGPoint] = []

        var bearingDeg = contentHeadingDeg - headingHalfWindowDeg
        let upper = contentHeadingDeg + headingHalfWindowDeg
        while bearingDeg <= upper {
            let theta = bearingDeg * .pi / 180.0
            let east = horizonDist * sin(theta)
            let north = horizonDist * cos(theta)

            let world = sessionManager.worldPoint(east: east, up: up, north: north)

            if let screen = sessionManager.projectToScreen(world),
               screen.x.isFinite, screen.y.isFinite,
               isWithinExtendedBounds(screen, size: size) {
                if let last = current.last,
                   hypot(screen.x - last.x, screen.y - last.y) > maxSegmentGap {
                    if current.count >= 2 { segments.append(current) }
                    current = []
                }
                current.append(screen)
            } else if !current.isEmpty {
                if current.count >= 2 { segments.append(current) }
                current = []
            }
            bearingDeg += sampleStepDeg
        }
        if current.count >= 2 { segments.append(current) }

        // Cardinal + intercardinal markers, anchored to true compass bearings.
        let cardinalDirections: [(label: String, deg: Double)] = [
            ("N", 0),   ("NE", 45),  ("E", 90),  ("SE", 135),
            ("S", 180), ("SW", 225), ("W", 270), ("NW", 315)
        ]
        var labels: [HorizonLabel] = []
        for cd in cardinalDirections {
            guard abs(angleDelta(cd.deg, contentHeadingDeg)) <= headingHalfWindowDeg else { continue }

            let theta = cd.deg * .pi / 180.0
            let east = horizonDist * sin(theta)
            let north = horizonDist * cos(theta)
            let world = sessionManager.worldPoint(east: east, up: -h, north: north)
            guard let screen = sessionManager.projectToScreen(world),
                  screen.x.isFinite, screen.y.isFinite,
                  isWithinExtendedBounds(screen, size: size) else { continue }
            labels.append(HorizonLabel(text: cd.label, position: screen))
        }

        return HorizonLayout(segments: segments, labels: labels)
    }

    /// Smallest signed difference between two angles on a 360° circle, in
    /// degrees. Result is in (-180, 180].
    private func angleDelta(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    /// Allow points slightly off-screen so the line continues smoothly across
    /// the frame edges instead of stopping right at the boundary.
    private func isWithinExtendedBounds(_ p: CGPoint, size: CGSize) -> Bool {
        let margin: CGFloat = 200
        return p.x > -margin && p.x < size.width + margin
            && p.y > -margin && p.y < size.height + margin
    }
}

/// One cardinal-direction marker positioned on the horizon line.
struct HorizonLabel: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let position: CGPoint

    static func == (lhs: HorizonLabel, rhs: HorizonLabel) -> Bool {
        lhs.text == rhs.text && lhs.position == rhs.position
    }
}

/// The horizon line itself: a soft white casing under a thin cyan core so it
/// stays legible against both bright sky and dark ground.
private struct HorizonPathView: View {
    let segments: [[CGPoint]]

    var body: some View {
        ZStack {
            horizonPath
                .stroke(Color.white.opacity(0.25),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            horizonPath
                .stroke(Color.cyan.opacity(0.85),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }

    private var horizonPath: Path {
        var path = Path()
        for segment in segments where segment.count >= 2 {
            path.move(to: segment[0])
            for point in segment.dropFirst() {
                path.addLine(to: point)
            }
        }
        return path
    }
}

/// Cardinal-direction labels rendered on top of the horizon line.
private struct HorizonLabelsView: View {
    let labels: [HorizonLabel]

    var body: some View {
        ForEach(labels) { label in
            Text(label.text)
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
                .position(label.position)
        }
    }
}
