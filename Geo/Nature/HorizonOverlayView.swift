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
    /// Named peaks for the area (from `PeakFinder`). Any peak whose tip sits on
    /// the computed skyline silhouette gets its name + altitude welded to the
    /// ridge line. Empty when peaks haven't loaded yet.
    let peaks: [NearbyPeak]
    @ObservedObject var sessionManager: ARSessionManager

    /// Minimum horizontal spacing (points) between kept peak labels — wide
    /// enough that adjacent pills (long peak names) don't visually overlap.
    private let minPeakLabelSpacing: CGFloat = 104
    /// Cap on simultaneously shown peak labels (keeps the panorama legible).
    private let maxPeakLabels: Int = 10

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
                PeakHorizonLabelsView(labels: layout.peakLabels)
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Geometry

    private struct HorizonLayout {
        var segments: [[CGPoint]]
        var labels: [HorizonLabel]
        var peakLabels: [PeakHorizonLabel]
    }

    private func horizonLayout(in size: CGSize) -> HorizonLayout {
        guard let userLoc = userLocation, sessionManager.isTracking else {
            return HorizonLayout(segments: [], labels: [], peakLabels: [])
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

        // Peak labels welded to the silhouette — only when we have a real
        // skyline to match against (the geometric fallback has no terrain).
        let peakLabels = useSkyline
            ? weldPeakLabels(observerAltitude: observerAltitude,
                             headingDeg: headingDeg, skyline: skyline, size: size)
            : []

        return HorizonLayout(segments: segments, labels: labels, peakLabels: peakLabels)
    }

    /// Match each named peak to the skyline silhouette at its bearing and, when
    /// the peak sits on/above that silhouette (i.e. it's the visible ridge
    /// feature, not occluded behind nearer terrain), float its label on the
    /// ridge. Nearer peaks win when labels would overlap.
    private func weldPeakLabels(observerAltitude: Double, headingDeg: Double,
                                skyline: [SkylineSample], size: CGSize) -> [PeakHorizonLabel] {
        struct Candidate { let label: PeakHorizonLabel; let x: CGFloat; let distance: Double }
        var candidates: [Candidate] = []

        // `peakOnSilhouette` (camera-independent) decides which peaks are on the
        // ridge; the same predicate suppresses their duplicate AR markers in
        // GeoNatureView, so a peak shows EITHER a ridge label OR a marker.
        for peak in peaks where peakOnSilhouette(peak, skyline: skyline, observerAltitude: observerAltitude) {
            guard abs(angleDelta(peak.bearing, headingDeg)) <= headingHalfWindowDeg else { continue }

            let sky = interpolateSkyline(at: wrap(peak.bearing), samples: skyline)
            // Position the label on the ridge silhouette at the peak's bearing.
            let theta = peak.bearing * .pi / 180.0
            let east = sky.distance * sin(theta)
            let north = sky.distance * cos(theta)
            let up = (sky.altitude - observerAltitude) - (sky.distance * sky.distance) / (2 * earthRadius)
            let world = sessionManager.worldPoint(east: east, up: up, north: north)
            guard let screen = sessionManager.projectToScreen(world),
                  screen.x.isFinite, screen.y.isFinite,
                  isWithinExtendedBounds(screen, size: size) else { continue }

            candidates.append(Candidate(
                label: PeakHorizonLabel(name: peak.name, altitude: peak.altitude, position: screen),
                x: screen.x, distance: peak.distance))
        }

        // Nearer (more prominent) peaks first; keep those at least
        // `minPeakLabelSpacing` apart horizontally, up to `maxPeakLabels`.
        candidates.sort { $0.distance < $1.distance }
        var kept: [PeakHorizonLabel] = []
        for c in candidates {
            if kept.allSatisfy({ abs($0.position.x - c.x) >= minPeakLabelSpacing }) {
                kept.append(c.label)
                if kept.count >= maxPeakLabels { break }
            }
        }
        return kept
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

/// A named peak welded to the skyline silhouette at its ridge position.
struct PeakHorizonLabel: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let altitude: Double
    let position: CGPoint

    static func == (lhs: PeakHorizonLabel, rhs: PeakHorizonLabel) -> Bool {
        lhs.name == rhs.name && lhs.position == rhs.position
    }
}

/// Camera-INDEPENDENT test: does this named peak form the visible skyline
/// silhouette — its tip on/above the ridge, not occluded behind nearer, higher
/// terrain? Drives both the welded ridge label (HorizonOverlayView) and the
/// suppression of the peak's duplicate AR marker (GeoNatureView), so a peak is
/// shown EITHER as a ridge label OR as a marker, never both. Mirrors the
/// Android `peakOnSilhouette`.
func peakOnSilhouette(_ peak: NearbyPeak, skyline: [SkylineSample],
                      observerAltitude: Double) -> Bool {
    guard !peak.name.isEmpty, peak.distance >= 1_000, !skyline.isEmpty else { return false }
    let earthRadius = 6_371_000.0
    func angle(_ d: Double, _ alt: Double) -> Double {
        atan2((alt - observerAltitude) - (d * d) / (2 * earthRadius), max(d, 1))
    }
    let sky = horizonSkylineValue(at: peak.bearing, samples: skyline)
    let tol = 1.5 * Double.pi / 180.0
    return angle(peak.distance, peak.altitude) >= angle(sky.distance, sky.altitude) - tol
}

/// Free skyline interpolation `(distance, altitude)` at a bearing — same math as
/// `HorizonOverlayView.interpolateSkyline`, usable outside the view (e.g. by the
/// marker-suppression filter). Samples are pre-sorted by bearing.
func horizonSkylineValue(at bearing: Double, samples: [SkylineSample])
    -> (distance: Double, altitude: Double) {
    guard !samples.isEmpty else { return (0, 0) }
    if samples.count == 1 { return (samples[0].distance, samples[0].altitude) }
    func wrap(_ deg: Double) -> Double {
        let d = deg.truncatingRemainder(dividingBy: 360); return d < 0 ? d + 360 : d
    }
    let b = wrap(bearing)
    var hiIdx = samples.firstIndex(where: { $0.bearing > b }) ?? samples.count
    var loIdx: Int
    if hiIdx == 0 { loIdx = samples.count - 1; hiIdx = 0 }
    else if hiIdx == samples.count { loIdx = samples.count - 1; hiIdx = 0 }
    else { loIdx = hiIdx - 1 }
    let lo = samples[loIdx], hi = samples[hiIdx]
    let span = wrap(hi.bearing - lo.bearing), pos = wrap(b - lo.bearing)
    let t = span == 0 ? 0 : min(max(pos / span, 0), 1)
    return (lo.distance + (hi.distance - lo.distance) * t,
            lo.altitude + (hi.altitude - lo.altitude) * t)
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

/// Named-peak labels floated just above their ridge silhouette position —
/// turns the abstract green line into an identified panorama.
private struct PeakHorizonLabelsView: View {
    let labels: [PeakHorizonLabel]

    var body: some View {
        ForEach(labels) { label in
            HStack(spacing: 3) {
                Image(systemName: "triangle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.orange)
                Text(label.name)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if label.altitude > 0 {
                    Text("\(Int(label.altitude)) m")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.6), in: Capsule())
            .overlay(Capsule().strokeBorder(.orange.opacity(0.7), lineWidth: 0.75))
            .fixedSize()
            // Float just above the ridge so the pill doesn't sit on the line.
            .position(x: label.position.x, y: label.position.y - 20)
        }
    }
}
