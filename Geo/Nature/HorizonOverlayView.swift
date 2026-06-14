//
//  HorizonOverlayView.swift
//  Geo
//
//  Created by nettrash on 03/05/2026.
//

import SwiftUI
import CoreLocation
import simd

/// Draws the horizon visible from the observer's location on top of
/// the AR camera feed. Two render modes, both projected through the
/// AR camera matrices so they stay welded to the world as the device
/// moves:
///
/// 1. **Terrain-aware skyline** — when `SkylineCalculator` has
///    delivered samples, each visible compass bearing uses its real
///    `(distance, altitude)` from a digital elevation model. The line
///    rises over distant mountains and dips into valleys, matching
///    the real altitude map.
/// 2. **Geometric horizon** — fallback when no skyline data is
///    available (offline, mid-fetch, or first launch). Assumes a
///    smooth sea-level Earth: every point sits at altitude 0 at the
///    geometric horizon distance `d = sqrt(2·R·h + h²)`.
///
/// Cardinal direction labels are anchored to true compass bearings
/// regardless of which mode is in effect.
struct HorizonOverlayView: View {
    let userLocation: CLLocation?
    /// Optional barometer altitude. Used in preference to GPS altitude
    /// when available because it tends to be much more accurate
    /// vertically.
    let barometerAltitude: Double?
    /// Real-terrain skyline samples sorted by bearing. Empty array
    /// triggers the geometric-horizon fallback.
    let skylineSamples: [SkylineSample]
    @ObservedObject var sessionManager: ARSessionManager

    /// Earth radius (mean) in metres.
    private let earthRadius: Double = 6_371_000

    /// One sample every `sampleStepDeg` degrees of bearing.
    private let sampleStepDeg: Double = 1.0

    /// Half-width (in degrees) of the bearing window we sample around
    /// the camera's current heading. 110° gives generous head-room
    /// outside the ~60° device FOV so the line doesn't visibly
    /// truncate as the user swings the camera.
    private let headingHalfWindowDeg: Double = 110.0

    /// Maximum gap (in screen points) between consecutive samples that
    /// we'll connect with a straight line.
    private let maxSegmentGap: CGFloat = 600

    var body: some View {
        // Read the per-frame tick so SwiftUI re-evaluates this body every
        // frame. The camera matrices are plain (non-@Published) properties
        // on `sessionManager`, so this is the only signal that keeps the
        // projected horizon line live as the device moves.
        _ = sessionManager.frameTick
        return GeometryReader { geometry in
            let layout = horizonLayout(in: geometry.size)

            ZStack {
                HorizonPathView(segments: layout.segments,
                                isSkyline: !skylineSamples.isEmpty)
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

        // Effective observer height above sea level in metres. The
        // barometer reports an absolute altitude that stays exactly 0
        // until its first sample lands (and permanently on barometer-less
        // devices), so a non-positive value is treated as absent and we
        // fall back to GPS altitude rather than clamping the observer to
        // sea level.
        let observerAltitude = barometerAltitude.flatMap { $0 > 0 ? $0 : nil } ?? userLoc.altitude
        // Floor so very-low altitudes still produce a meaningful line.
        let h = max(observerAltitude, 1.5)

        // Geometric horizon distance — used by the fallback path AND
        // as a hard cap on the skyline ranges so projection never
        // explodes.
        let geometricHorizonDist = sqrt(2 * earthRadius * h + h * h)

        // World points below are built via `sessionManager.worldPoint(...)`,
        // which anchors them to the camera origin (not the AR session's
        // world origin, which can drift) — the same shared projection used
        // by the marker overlay and the occlusion-target builder.

        // Camera heading (degrees, 0 = N, 90 = E). Camera looks down
        // its local −Z axis; the −Z column of the world transform is
        // the forward vector in ARKit's gravityAndHeading frame.
        let camFwdEast = -sessionManager.cameraTransform.columns.2.x
        let camFwdNorth = sessionManager.cameraTransform.columns.2.z
        var headingDeg = atan2(Double(camFwdEast), Double(camFwdNorth)) * 180 / .pi
        if headingDeg < 0 { headingDeg += 360 }

        let lower = headingDeg - headingHalfWindowDeg
        let upper = headingDeg + headingHalfWindowDeg

        // Pre-sort the skyline once so we can do constant-time wrap
        // lookups. Samples are at coarse bearings (e.g. every 6°);
        // we linearly interpolate to the 1° grid we're rendering at.
        let skyline = skylineSamples
        let useSkyline = !skyline.isEmpty

        var segments: [[CGPoint]] = []
        var current: [CGPoint] = []

        var bearingDeg = lower
        while bearingDeg <= upper {
            // Resolve (distance, altitude) for this bearing.
            let (distance, altitude): (Double, Double) = {
                guard useSkyline else {
                    // Geometric: every horizon point is at sea level
                    // (alt 0) at the geometric distance.
                    return (geometricHorizonDist, 0)
                }
                let normalised = ((bearingDeg.truncatingRemainder(dividingBy: 360)) + 360)
                    .truncatingRemainder(dividingBy: 360)
                let interp = interpolateSkyline(at: normalised, samples: skyline)
                // Use the sample's actual distance. We must NOT clip
                // it to `geometricHorizonDist` — a peak whose
                // elevation lifts its tip above the observer's eye
                // line is visible past the sea-level geometric
                // horizon, and clipping the distance while keeping
                // the altitude would project it at the wrong
                // horizontal range and badly inflate its apparent
                // angle (a 5 km-tall peak at 150 km would render as
                // if it were at 35 km). Samples that genuinely sit
                // below the horizon get filtered later by
                // `isWithinExtendedBounds` — their projected screen
                // y falls off the bottom of the frame.
                return (interp.distance, interp.altitude)
            }()

            // World-space position of the skyline point.
            let theta = bearingDeg * .pi / 180.0
            let east  = distance * sin(theta)
            let north = distance * cos(theta)
            // Apparent rise relative to the observer, including the
            // Earth-curvature drop. For the geometric path this works
            // out to exactly `-h` — the skyline lies *h* metres below
            // eye level.
            let curvatureDrop = (distance * distance) / (2 * earthRadius)
            let up = (altitude - observerAltitude) - curvatureDrop

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

        // Cardinal labels — anchored to true compass bearings, with a
        // small visual lift above the line so they don't collide with
        // it.
        let cardinalDirections: [(label: String, deg: Double)] = [
            ("N", 0),   ("NE", 45),  ("E", 90),  ("SE", 135),
            ("S", 180), ("SW", 225), ("W", 270), ("NW", 315)
        ]
        var labels: [HorizonLabel] = []
        for cd in cardinalDirections {
            let angularDelta = abs(angleDelta(cd.deg, headingDeg))
            guard angularDelta <= headingHalfWindowDeg else { continue }

            // Place the label at the geometric horizon at this bearing,
            // which keeps the labels near the skyline regardless of
            // local terrain. (Using the skyline distance would shrink
            // / wobble them as elevation changes.)
            let theta = cd.deg * .pi / 180.0
            let east = geometricHorizonDist * sin(theta)
            let north = geometricHorizonDist * cos(theta)
            let up = -h
            let world = sessionManager.worldPoint(east: east, up: up, north: north)
            guard let screen = sessionManager.projectToScreen(world),
                  screen.x.isFinite, screen.y.isFinite,
                  isWithinExtendedBounds(screen, size: size) else { continue }
            labels.append(HorizonLabel(text: cd.label, position: screen))
        }

        return HorizonLayout(segments: segments, labels: labels)
    }

    /// Linear-interpolate the skyline `(distance, altitude)` at an
    /// arbitrary bearing in [0, 360). Uses circular wrap-around so a
    /// query at 358° interpolates between samples at 354° and 0°.
    private func interpolateSkyline(at bearing: Double,
                                    samples: [SkylineSample])
        -> (distance: Double, altitude: Double)
    {
        // Skyline samples are pre-sorted by bearing.
        guard !samples.isEmpty else { return (0, 0) }
        if samples.count == 1 {
            return (samples[0].distance, samples[0].altitude)
        }

        // Find the first sample with bearing > query.
        var hiIdx = samples.firstIndex(where: { $0.bearing > bearing })
            ?? samples.count
        var loIdx: Int
        if hiIdx == 0 {
            loIdx = samples.count - 1
            hiIdx = 0
        } else if hiIdx == samples.count {
            loIdx = samples.count - 1
            hiIdx = 0
        } else {
            loIdx = hiIdx - 1
        }
        let lo = samples[loIdx]
        let hi = samples[hiIdx]

        // Distance from `lo.bearing` to `bearing` and to `hi.bearing`,
        // wrapping around 360°.
        let span = wrap(hi.bearing - lo.bearing)
        let pos  = wrap(bearing - lo.bearing)
        let t = span == 0 ? 0 : min(max(pos / span, 0), 1)

        return (
            lo.distance + (hi.distance - lo.distance) * t,
            lo.altitude + (hi.altitude - lo.altitude) * t
        )
    }

    /// Map any angle to the half-open [0, 360) interval.
    private func wrap(_ deg: Double) -> Double {
        let d = deg.truncatingRemainder(dividingBy: 360)
        return d < 0 ? d + 360 : d
    }

    /// Smallest signed difference between two angles on a 360° circle,
    /// in degrees. Result is in (-180, 180].
    private func angleDelta(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    /// Allow points slightly off-screen so the line continues smoothly
    /// across the frame edges instead of stopping right at the boundary.
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

/// Pure rendering view: takes pre-computed screen-space line segments
/// and draws them. Splitting this out keeps the AR-session reads on
/// the main actor (in `HorizonOverlayView.body`) and the drawing code
/// completely concurrency-free.
private struct HorizonPathView: View {
    let segments: [[CGPoint]]
    /// True when we're rendering real terrain rather than the
    /// geometric fallback — used to colour the line subtly differently
    /// so debugging the skyline is easier.
    let isSkyline: Bool

    var body: some View {
        ZStack {
            horizonPath
                .stroke(Color.white.opacity(0.25),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            horizonPath
                .stroke(isSkyline ? Color.green.opacity(0.9) : Color.cyan.opacity(0.85),
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
