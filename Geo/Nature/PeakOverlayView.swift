//
//  PeakOverlayView.swift
//  Geo
//
//  Created by nettrash on 24/03/2026.
//

import SwiftUI
import CoreLocation
import simd

/// Leader length (screen points) from a peak's projected summit up to its
/// floating name banner. Exposed so the tap hit-test in `GeoNatureView` can
/// target the banner (where the label is drawn), not the bare summit point.
let peakBannerLeaderLength: CGFloat = 46

/// Overlay that annotates each visible peak at its real summit position.
///
/// Instead of a label box sitting *on* the peak, each peak is drawn as:
///   • a small dot at the projected **summit** — the screen point where the
///     peak's top lands, computed from its GPS position + altitude and the
///     observer's altitude through the AR camera (so it tracks the real peak),
///   • a thin vertical **leader** rising from that dot, and
///   • a slightly **tilted banner** (name + altitude) at the leader's top.
///
/// The dot marks the exact summit; the banner floats clear of it so it never
/// hides the peak you're identifying. This is the Nature tab's whole point —
/// every peak the finder returns is annotated; there's no occlusion culling
/// (peaks are kilometres away).
///
/// Dot, leader and banner are ONE view per peak (`PeakMarkerView`) — not a
/// shared Canvas under separate banner views. During an interface rotation
/// SwiftUI animates layout, and a Canvas redraws instantly while banners glide,
/// visibly tearing each banner off its leader; a single united figure cannot
/// come apart, whatever animates.
struct PeakOverlayView: View {
    let peaks: [NearbyPeak]
    let userLocation: CLLocation?
    /// Observer altitude used as the ENU origin — the barometer-preferred
    /// sensor value, resolved by the caller. The raw GPS altitude can disagree
    /// with the barometric one by 10–30 m and visibly detach the markers.
    /// `nil` falls back to the raw GPS altitude.
    let observerAltitude: Double?
    @ObservedObject var sessionManager: ARSessionManager

    /// Counter-clockwise banner tilt (right edge lifted), so it stands up from
    /// the leader like a signpost, reading upward. At −75° it's near-vertical.
    private let bannerTiltDegrees: Double = -75

    private struct ProjectedPeak: Identifiable {
        let id: UUID
        let peak: NearbyPeak
        let summit: CGPoint       // projected peak top
        let opacity: Double
        let scale: CGFloat
        /// Leader top = banner anchor (summit lifted by the leader length).
        var anchor: CGPoint { CGPoint(x: summit.x, y: summit.y - peakBannerLeaderLength) }
    }

    var body: some View {
        // Read the per-frame tick so SwiftUI re-evaluates this body every frame;
        // the camera matrices are plain (non-@Published) properties, so this is
        // what keeps the annotations tracking as the device moves.
        _ = sessionManager.frameTick
        return GeometryReader { geometry in
            let projected = projectedPeaks(in: geometry.size)
            // One united marker per peak, each hung off a ZERO-SIZE anchor: the
            // dimensionless base is `.position`ed at the projected anchor and
            // the marker rides on it as an overlay, so the marker's own frame
            // never participates in layout. (Pinning the markers directly with
            // alignment guides let any pill overhanging the top/left screen
            // edge — routine, given the ±50 pt projection cull margin — grow
            // the stack's layout union and renormalise its origin, shifting
            // EVERY marker off its summit at once.) Overlay alignment and
            // `.position` both resolve synchronously, so this also renders in
            // the shutter's one-shot `ImageRenderer` pass.
            ZStack {
                ForEach(projected) { p in
                    Color.clear
                        .frame(width: 0, height: 0)
                        .overlay(alignment: .bottomLeading) {
                            PeakMarkerView(peak: p.peak, tiltDegrees: bannerTiltDegrees,
                                           scale: p.scale, opacity: p.opacity)
                        }
                        .position(x: p.anchor.x, y: p.anchor.y)
                }
            }
            // Strip any inherited implicit animation (an interface rotation
            // wraps its relayout in an animated transaction). The AR projection
            // snaps to the new pose every `frameTick`; letting layout animate
            // would only drag markers off their summits mid-rotation.
            .transaction { $0.animation = nil }
        }
    }

    private func projectedPeaks(in size: CGSize) -> [ProjectedPeak] {
        peaks.compactMap { peak in
            guard let summit = projectGPSPoint(coordinate: peak.coordinate, altitude: peak.altitude,
                                               screenWidth: size.width, screenHeight: size.height)
            else { return nil }
            return ProjectedPeak(
                id: peak.id, peak: peak, summit: summit,
                opacity: opacityForDistance(peak.distance, maxDistance: 50000),
                scale: scaleForDistance(peak.distance, maxDistance: 50000)
            )
        }
    }

    // MARK: - GPS → World → Screen Projection

    /// Project a GPS coordinate + altitude to screen coordinates using the AR
    /// camera. GPS→ENU (origin at the observer altitude) → ARKit world (offset
    /// by the camera's world position) → clip space → screen. `nil` when not
    /// tracking, behind the camera, or off-screen (with margin).
    private func projectGPSPoint(
        coordinate: CLLocationCoordinate2D,
        altitude: Double,
        screenWidth: Double,
        screenHeight: Double
    ) -> CGPoint? {
        guard let userLoc = userLocation, sessionManager.isTracking else { return nil }

        let enu = Geometry.gpsToENU(
            from: userLoc.coordinate, originAltitude: observerAltitude ?? userLoc.altitude,
            to: coordinate, targetAltitude: altitude
        )
        let worldPoint = sessionManager.worldPoint(east: enu.east, up: enu.up, north: enu.north)
        guard let screenPos = sessionManager.projectToScreen(worldPoint) else { return nil }

        let margin: CGFloat = 50
        guard screenPos.x > -margin && screenPos.x < screenWidth + margin &&
              screenPos.y > -margin && screenPos.y < screenHeight + margin else {
            return nil
        }
        return screenPos
    }

    /// Points further away are more transparent.
    private func opacityForDistance(_ distance: Double, maxDistance: Double) -> Double {
        max(0.5, min(1.0, 1.0 - (distance / maxDistance) * 0.5))
    }

    /// Points further away are slightly smaller.
    private func scaleForDistance(_ distance: Double, maxDistance: Double) -> CGFloat {
        max(0.6, min(1.0, 1.0 - (distance / maxDistance) * 0.4))
    }
}

/// A peak's complete marker — summit dot, leader and floating name/altitude
/// banner — rendered as ONE view, the single united figure. The banner is
/// single-line so it reads cleanly as one strip when stood up near-vertical;
/// it rotates/scales about its bottom-LEADING corner (the leader top), and the
/// leader + dot hang below that corner in a fixed-size background welded to the
/// pivot — so tilt and distance scaling never move them, and no animation or
/// layout pass can separate line, dot and banner.
///
/// The marker's own layout frame is the banner's un-rotated pill (visual
/// effects and the background don't change layout). The caller must attach it
/// to a zero-size anchor via `.overlay(alignment: .bottomLeading)` — aligning
/// the pill's bottom-leading corner (the transform pivot) onto the projected
/// anchor point — rather than measuring it through an async `@State` size:
/// overlay alignment resolves synchronously during layout, so the marker also
/// renders in the shutter's one-shot `ImageRenderer` pass — the old
/// `@State`-driven placement stayed at size `.zero` there, hiding every label
/// in the shared photo.
private struct PeakMarkerView: View {
    let peak: NearbyPeak
    let tiltDegrees: Double
    let scale: CGFloat
    let opacity: Double

    /// Summit dot radius (screen points).
    private let dotRadius: CGFloat = 2.5

    var body: some View {
        content
            .fixedSize()
            .opacity(opacity)
            .rotationEffect(.degrees(tiltDegrees), anchor: .bottomLeading)
            .scaleEffect(scale, anchor: .bottomLeading)
            // Leader + dot, in the SAME view as the banner. Attached after the
            // rotation/scale so they stay screen-vertical and unscaled, aligned
            // to the un-rotated layout frame's bottom-leading corner — the
            // transform pivot, the one point tilt and scale never move.
            .background(alignment: .bottomLeading) { leaderAndDot }
            // Internal geometry updates apply atomically with the marker's own
            // placement, so an animated ancestor can't shear the figure.
            .geometryGroup()
    }

    /// Thin vertical leader from the banner corner down to the summit dot. The
    /// overridden guides hang it fully below the pill (its `bottom` resolves to
    /// its top edge) with the line centred on the pivot corner's x.
    private var leaderAndDot: some View {
        Canvas { ctx, size in
            let x = size.width / 2
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: peakBannerLeaderLength))
            ctx.stroke(line, with: .color(.orange.opacity(0.9 * opacity)),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: x - dotRadius,
                                            y: peakBannerLeaderLength - dotRadius,
                                            width: dotRadius * 2, height: dotRadius * 2)),
                     with: .color(.orange.opacity(opacity)))
        }
        .frame(width: dotRadius * 2, height: peakBannerLeaderLength + dotRadius)
        .alignmentGuide(VerticalAlignment.bottom) { _ in 0 }
        .alignmentGuide(HorizontalAlignment.leading) { dims in dims.width / 2 }
    }

    private var content: some View {
        HStack(spacing: 5) {
            Text(verbatim: peak.name)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
            if peak.altitude > 0 {
                // Summit altitude in metres — the mountaineering convention
                // ("Mont Blanc 4808 m"), not kilometres.
                Text(verbatim: "\(Int(peak.altitude.rounded())) m")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(.black.opacity(0.6))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(.orange.opacity(0.8), lineWidth: 1))
        )
    }
}
