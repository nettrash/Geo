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
            ZStack {
                // Leaders + summit dots — one Canvas for all of them.
                Canvas { ctx, _ in
                    for p in projected {
                        var line = Path()
                        line.move(to: p.summit)
                        line.addLine(to: p.anchor)
                        ctx.stroke(line, with: .color(.orange.opacity(0.9 * p.opacity)),
                                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        let r: CGFloat = 2.5
                        ctx.fill(Path(ellipseIn: CGRect(x: p.summit.x - r, y: p.summit.y - r,
                                                        width: r * 2, height: r * 2)),
                                 with: .color(.orange.opacity(p.opacity)))
                    }
                }
                .allowsHitTesting(false)

                // Tilted name/altitude banners at the leader tops. No implicit
                // position animation: `frameTick` already re-projects every
                // frame, and the leader (drawn in the Canvas above) and the
                // banner share the same anchor — animating only the banner would
                // let it lag behind its own leader.
                ForEach(projected) { p in
                    PeakSummitBanner(peak: p.peak, anchor: p.anchor,
                                     tiltDegrees: bannerTiltDegrees,
                                     scale: p.scale, opacity: p.opacity)
                }
            }
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

/// A peak's floating name/altitude banner. Single-line so it reads cleanly as
/// one strip when stood up near-vertical. Pins its bottom-LEADING corner to the
/// leader top (`anchor`) and rotates/scales about that corner, so the banner
/// rises from the leader tip like a signpost regardless of tilt or distance
/// scaling. Parked invisible until measured so it can't flash at the wrong spot.
private struct PeakSummitBanner: View {
    let peak: NearbyPeak
    let anchor: CGPoint
    let tiltDegrees: Double
    let scale: CGFloat
    let opacity: Double
    @State private var size: CGSize = .zero

    var body: some View {
        content
            .fixedSize()
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { size = proxy.size }
                    .onChange(of: proxy.size) { _, newValue in size = newValue }
            })
            .rotationEffect(.degrees(tiltDegrees), anchor: .bottomLeading)
            .scaleEffect(scale, anchor: .bottomLeading)
            .opacity(opacity * (size == .zero ? 0 : 1))
            // `.position` centres the (unrotated) layout frame; place the centre
            // so the bottom-leading corner lands on the anchor. Rotation + scale
            // both pivot at `.bottomLeading`, i.e. exactly there.
            .position(x: anchor.x + size.width / 2, y: anchor.y - size.height / 2)
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
