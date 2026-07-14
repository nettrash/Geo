//
//  SkylineCalculator.swift
//  Geo
//
//  Computes the **terrain-aware** horizon (skyline) visible from the
//  observer's location, using a digital elevation model fetched via
//  `TerrainElevationService`.
//
//  Algorithm
//  ---------
//  Around the observer we cast a fan of `bearingStepDeg` rays. Along
//  each ray we sample terrain elevation at a logarithmically-spaced
//  set of distances out to `maxRangeMeters`. The "skyline" point at
//  that bearing is the sample with the *largest apparent altitude
//  angle* — i.e. the silhouette feature that the observer would
//  actually see at that azimuth, accounting for Earth curvature
//  (`Geometry.apparentAltitudeAngle`).
//
//  The result is an array of `SkylineSample`s, sorted by bearing,
//  that `HorizonOverlayView` renders instead of the geometric
//  sea-level horizon.
//

import Foundation
import CoreLocation

/// One point on the visible terrain skyline.
struct SkylineSample: Equatable, Sendable {
    /// Compass bearing from the observer, degrees, 0 = N, clockwise.
    let bearing: Double
    /// Horizontal distance from the observer in metres at which the
    /// skyline feature lies.
    let distance: Double
    /// Absolute terrain elevation (metres above mean sea level) at the
    /// skyline feature.
    let altitude: Double
}

@MainActor
final class SkylineCalculator: ObservableObject {

    /// Latest computed skyline. Empty until the first successful
    /// computation. Sorted by `bearing`.
    @Published private(set) var samples: [SkylineSample] = []

    /// The observer altitude the current `samples` were computed with —
    /// the DEM-anchored value from `Geometry.effectiveObserverAltitude`.
    /// Published together with `samples` so every consumer that projects
    /// against the skyline (horizon overlay, welded pills, AR markers,
    /// occlusion targets, tap hit-tests) uses the SAME altitude the
    /// silhouette was picked with; a baro/GPS-vs-skyline mismatch
    /// vertically detaches those layers from each other. `nil` until the
    /// first successful pass — consumers then fall back to their existing
    /// baro-preferred / GPS expression.
    @Published private(set) var observerAltitudeUsed: Double?

    /// True while a calculation is in flight. Lets the UI show a hint
    /// (e.g. fade in the geometric horizon as a placeholder).
    @Published private(set) var isComputing: Bool = false

    /// Distance the observer must move before we re-run.
    private let recomputeDistance: CLLocationDistance = 500

    /// Maximum sky-line range. ~200 km matches what's actually visible
    /// from a high mountaintop on a clear day, and is well within the
    /// geometric horizon for any observer above ~3 km.
    nonisolated static let skylineMaxRangeMeters: Double = 200_000

    /// Bearings sampled — 2° spacing → 180 samples around the full circle.
    /// Finer than 6° so narrow cliff edges are captured rather than
    /// smoothed away by interpolation.
    nonisolated static let skylineBearingStepDeg: Double = 2

    /// Distance samples per bearing.
    ///
    /// Spacing matters: along a single bearing the silhouette is
    /// whichever sample has the largest apparent-altitude angle, so
    /// any peak that sits between two sample distances is invisible
    /// to the picker. The previous hand-written schedule still had
    /// 22–60 km holes past 48 km — wide enough to swallow entire
    /// mountain ranges, which is exactly how the drawn skyline drifts
    /// away from the real one.
    ///
    /// This schedule keeps the close-in metric step (~200 m), then
    /// grows geometrically with a ≤1.15× ratio out to `maxRange`, so
    /// the miss window is never worse than ±7 % of the distance at any
    /// range (the refinement round in `computeSkyline` then tightens
    /// the winner further). ~44 samples × 180 bearings ≈ 8 000
    /// elevation queries per full recompute; the persistent cache in
    /// `TerrainElevationService` amortises that to nearly zero on
    /// subsequent recomputes since the user has to move ≥500 m
    /// before we re-run.
    nonisolated static let skylineDistancesMeters: [Double] = {
        var ds: [Double] = [100, 200, 400, 600, 800, 1_000]
        let ratio = 1.15
        var d = 1_000.0
        while d < skylineMaxRangeMeters {
            d = min(d * ratio, skylineMaxRangeMeters)
            ds.append((d / 10).rounded() * 10)   // tidy to 10 m
        }
        ds[ds.count - 1] = skylineMaxRangeMeters
        return ds
    }()

    // Instance aliases so the existing `compute` call sites read unchanged.
    private let maxRangeMeters = SkylineCalculator.skylineMaxRangeMeters
    private let bearingStepDeg = SkylineCalculator.skylineBearingStepDeg
    private let distancesMeters = SkylineCalculator.skylineDistancesMeters

    private var lastObserver: CLLocation?
    private var fetchTask: Task<Void, Never>?

    /// Monotonic generation tag for in-flight passes. Each `compute`
    /// bumps it and captures the new value; a finishing pass only clears
    /// `isComputing` if it is still the latest generation, so a cancelled
    /// pass can't clear the flag for the pass that superseded it.
    private var computeGeneration: Int = 0

    /// Trigger a recompute if the observer has moved far enough since
    /// the last one. Cheap to call from a Timer / onReceive.
    func computeIfNeeded(observer: CLLocation, barometerAltitude: Double? = nil) {
        if let last = lastObserver,
           last.distance(from: observer) < recomputeDistance,
           !samples.isEmpty {
            return
        }
        compute(observer: observer, barometerAltitude: barometerAltitude)
    }

    /// Force a recompute regardless of distance moved.
    func compute(observer: CLLocation, barometerAltitude: Double? = nil) {
        fetchTask?.cancel()
        lastObserver = observer
        let captured = observer
        let altOverride = barometerAltitude
        computeGeneration &+= 1
        let generation = computeGeneration
        fetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isComputing = true
            // Only clear the flag if we're still the current pass. A
            // newer `compute` may have cancelled us and started its own
            // pass; clearing `isComputing` unconditionally here would
            // hide that in-flight pass's spinner. (`computeGeneration`
            // is only mutated on the main actor, so this is race-free.)
            defer {
                if self.computeGeneration == generation { self.isComputing = false }
            }
            let new = await Self.computeSkyline(
                observer: captured,
                observerAltitudeOverride: altOverride,
                bearingStepDeg: self.bearingStepDeg,
                distances: self.distancesMeters,
                maxRange: self.maxRangeMeters
            )
            // Cancellation may have raced us — only adopt if we're
            // still the current task.
            guard !Task.isCancelled else { return }
            // Keep the previous skyline visible if the new pass came
            // back empty (network failure, all-nil elevations); the
            // geometric fallback in HorizonOverlayView already covers
            // that case so we don't need to wipe. `observerAltitudeUsed`
            // is adopted together with `samples` so the two can never
            // describe different passes.
            if !new.samples.isEmpty {
                self.samples = new.samples
                self.observerAltitudeUsed = new.observerAltitude
            }
        }
    }

    /// Cancel any in-flight compute so the Open-Elevation batches stop.
    /// Called from the Nature view's `onDisappear` so the thousands of
    /// elevation queries a recompute spawns don't keep running once the
    /// user leaves the AR tab. The calculator is reused across AR
    /// teardown/rebuild, so a later `compute` can still launch a fresh
    /// pass. Mirrors the Android port's `SkylineCalculator.cancel()`.
    func cancel() {
        fetchTask?.cancel()
        fetchTask = nil
        isComputing = false
    }

    // MARK: - Offline prefetch grid

    /// Grid cell step in degrees — must equal the elevation cache's ~110 m
    /// quantisation (3 decimals, see `TerrainElevationService.gridKey`) so
    /// every prefetched node is a distinct cache cell and a live skyline
    /// lookup from ANY observer in the area hits a cached cell.
    nonisolated static let offlineCellStepDeg = 0.001

    /// Maximum DEM cells cached per offline pack. A full-resolution
    /// (~110 m) area grid over a large radius would be millions of cells
    /// (a 100 km pack ≈ 3.3 M), so this bounds the download size, the
    /// on-disk pack and the pinned-cell memory. When the requested radius
    /// would exceed it, the cached *square* shrinks (keeping full 110 m
    /// resolution within it) so any observer inside the cached core gets a
    /// hole-free skyline and the far edges of a very large pack degrade
    /// gracefully to the geometric horizon. ~40 k cells ≈ a ±11 km
    /// full-resolution core and an ~80 s prefetch.
    nonisolated static let offlineMaxDEMCells = 40_000

    /// Far-terrain ring layers: the skyline looks out to 200 km, but the
    /// full-resolution core above only reaches ~10 km before the cell
    /// budget bites. Rather than spending the whole budget on 110 m
    /// resolution nobody can see at range (the fan's own lateral
    /// resolution is 2° of bearing ≈ 3.5 % of distance), the pack adds
    /// two coarser rings around its centre — matching how the skyline
    /// actually consumes data, so distant ranges resolve offline too.
    nonisolated static let offlineMediumRangeKm = 50.0
    nonisolated static let offlineCoarseRangeKm = 200.0
    nonisolated static let offlineMaxRingCells = 50_000

    /// All DEM cells to prefetch for an offline pack's full-resolution
    /// core: a regular ~110 m lat/lon grid covering the pack's bounding
    /// box (centre ± `radiusKm`), snapped to the cache's milli-degree
    /// lattice and capped to `offlineMaxDEMCells`.
    ///
    /// This replaces the old single-observer *fan*, which only lined up
    /// with the live lookups when the observer stood exactly at the pack
    /// centre — off-centre observers' fans projected to different cells, so
    /// every offline lookup missed and the skyline went empty. An area grid
    /// covers the cells any observer in the area will look up. Order is not
    /// significant to callers.
    nonisolated static func offlinePrefetchCoordinates(center: CLLocationCoordinate2D,
                                                       radiusKm: Double) -> [CLLocationCoordinate2D] {
        areaGrid(center: center, radiusKm: radiusKm,
                 stepDeg: offlineCellStepDeg, maxCells: offlineMaxDEMCells)
    }

    /// The ~550 m ring out to `offlineMediumRangeKm` — mid-range terrain
    /// for the offline skyline. Keyed by `TerrainElevationService.gridKeyMedium`.
    nonisolated static func offlineMediumPrefetchCoordinates(center: CLLocationCoordinate2D)
        -> [CLLocationCoordinate2D] {
        areaGrid(center: center, radiusKm: offlineMediumRangeKm,
                 stepDeg: TerrainElevationService.mediumStepDeg, maxCells: offlineMaxRingCells)
    }

    /// The ~2.2 km ring out to `offlineCoarseRangeKm` (the skyline's full
    /// range) — distant ranges for the offline skyline. Keyed by
    /// `TerrainElevationService.gridKeyCoarse`.
    nonisolated static func offlineCoarsePrefetchCoordinates(center: CLLocationCoordinate2D)
        -> [CLLocationCoordinate2D] {
        areaGrid(center: center, radiusKm: offlineCoarseRangeKm,
                 stepDeg: TerrainElevationService.coarseStepDeg, maxCells: offlineMaxRingCells)
    }

    /// Shared area-grid builder: a regular `stepDeg` lat/lon grid over
    /// centre ± `radiusKm`, snapped to that step's lattice and capped to
    /// `maxCells` by shrinking the covered square (never the resolution),
    /// so a live lookup inside the covered core never lands in a gap.
    nonisolated private static func areaGrid(center: CLLocationCoordinate2D,
                                             radiusKm: Double,
                                             stepDeg step: Double,
                                             maxCells: Int) -> [CLLocationCoordinate2D] {
        let metersPerDegLat = 111_320.0
        let cosLat = max(0.01, cos(center.latitude * .pi / 180))
        var halfLatDeg = (radiusKm * 1000) / metersPerDegLat
        var halfLonDeg = (radiusKm * 1000) / (metersPerDegLat * cosLat)

        let latNodes = Int((2 * halfLatDeg) / step) + 1
        let lonNodes = Int((2 * halfLonDeg) / step) + 1
        let total = latNodes * lonNodes
        if total > maxCells {
            let scale = (Double(maxCells) / Double(total)).squareRoot()
            halfLatDeg *= scale
            halfLonDeg *= scale
        }

        // Snap the centre to the layer's lattice and step exactly one
        // cell at a time so every node maps to its own distinct cache cell
        // (no phase drift, no gaps, no duplicates vs the live lookups).
        let cLat = (center.latitude / step).rounded() * step
        let cLon = (center.longitude / step).rounded() * step
        let latSteps = Int(halfLatDeg / step)
        let lonSteps = Int(halfLonDeg / step)

        var coords: [CLLocationCoordinate2D] = []
        coords.reserveCapacity((2 * latSteps + 1) * (2 * lonSteps + 1))
        var i = -latSteps
        while i <= latSteps {
            let lat = cLat + Double(i) * step
            var j = -lonSteps
            while j <= lonSteps {
                coords.append(CLLocationCoordinate2D(latitude: lat, longitude: cLon + Double(j) * step))
                j += 1
            }
            i += 1
        }
        return coords
    }

    // MARK: - Adaptive bearing refinement (pure pair selection)

    /// Adjacent-pair thresholds for the adaptive bearing pass: a jump in
    /// winning apparent angle of more than ~0.8° between neighbouring
    /// bearings, OR winning distances differing by more than 1.5×, marks
    /// a silhouette discontinuity (cliff edge, near/far transition,
    /// narrow summit straddled by the lattice) worth one midpoint bearing.
    nonisolated static let adaptiveAngleJumpDeg = 0.8
    nonisolated static let adaptiveDistanceRatio = 1.5

    /// Budget cap on inserted midpoint bearings per pass. 120 extra
    /// bearings × ~44 schedule distances ≈ 5 300 worst-case elevation
    /// queries on top of the base ~8 000 — still one amortised pass
    /// against the persistent cache, and in practice a real skyline has
    /// far fewer discontinuities than the cap. Worst pairs win the cap.
    nonisolated static let adaptiveMaxExtraBearings = 120

    /// Bearing gaps wider than this carry no adjacency information (e.g.
    /// the wrap pair of a sparse test set, or a fan with missing sectors)
    /// and are never subdivided.
    nonisolated static let adaptiveMaxPairGapDeg = 45.0

    /// A. Pure pair-selection for the adaptive bearing refinement: given
    /// the per-bearing winners (sorted ascending by bearing; `angleDeg`
    /// is the winning apparent-altitude angle in DEGREES), return the
    /// midpoint bearings to insert — one between each adjacent pair whose
    /// angles differ by more than `angleJumpDeg` or whose distances
    /// differ by more than `distanceRatio`×. Wrap-aware: the last↔first
    /// pair (e.g. 358°↔0°) is examined too, and a midpoint of ≥360°
    /// wraps back into [0, 360). Capped at `maxExtra`, keeping the most
    /// severe discontinuities (largest threshold overshoot) first.
    nonisolated static func adaptiveRefinementBearings(
        samples: [(bearing: Double, angleDeg: Double, distance: Double)],
        angleJumpDeg: Double = adaptiveAngleJumpDeg,
        distanceRatio: Double = adaptiveDistanceRatio,
        maxExtra: Int = adaptiveMaxExtraBearings
    ) -> [Double] {
        guard samples.count >= 2, maxExtra > 0 else { return [] }
        struct Split { let mid: Double; let severity: Double }
        var splits: [Split] = []
        for i in 0..<samples.count {
            let a = samples[i]
            let b = samples[(i + 1) % samples.count]   // last pairs with first
            var gap = b.bearing - a.bearing
            if gap < 0 { gap += 360 }                  // the 358°↔0° wrap pair
            guard gap > 0.01, gap < adaptiveMaxPairGapDeg else { continue }
            let angleJump = abs(a.angleDeg - b.angleDeg)
            let dLo = min(a.distance, b.distance)
            let dHi = max(a.distance, b.distance)
            let ratio = dLo > 0 ? dHi / dLo : Double.infinity
            guard angleJump > angleJumpDeg || ratio > distanceRatio else { continue }
            var mid = a.bearing + gap / 2
            if mid >= 360 { mid -= 360 }
            // Severity = how far past its threshold the worse criterion is,
            // so the cap keeps the most visible discontinuities.
            let severity = max(angleJump / angleJumpDeg, ratio / distanceRatio)
            splits.append(Split(mid: mid, severity: severity))
        }
        splits.sort { $0.severity == $1.severity ? $0.mid < $1.mid : $0.severity > $1.severity }
        return splits.prefix(maxExtra).map { $0.mid }
    }

    /// F. Number of distance-refinement (bracket-tightening) rounds run
    /// per bearing. Each round costs ≤2 elevation queries per bearing
    /// (≤2×360 ≈ 720 extra for both rounds over the full fan), almost
    /// all cache hits on recomputes, and quarters the distance
    /// uncertainty around the winner.
    nonisolated static let distanceRefinementRounds = 2

    // MARK: - Pure computation

    /// Static + nonisolated so the whole pass can run off the main
    /// actor — there are thousands of trig calls per pass.
    ///
    /// Pipeline (query budget per full recompute, before caching):
    ///   1. observer DEM anchor — 1 query (B);
    ///   2. base fan: 180 bearings × ~44 distances ≈ 8 000 queries;
    ///   3. distance refinement × `distanceRefinementRounds` — ≤2 per
    ///      bearing per round ≈ 720 (F);
    ///   4. adaptive bearings: ≤`adaptiveMaxExtraBearings` midpoint
    ///      bearings, each a full distance scan + its own refinement —
    ///      ≤120 × (44 + 4) ≈ 5 800 worst case, usually far fewer (A).
    ///
    /// Returns the bearing-sorted samples plus the observer altitude the
    /// pass was computed with, so the calculator can publish the two
    /// together. NOTE: with the adaptive pass the samples are no longer a
    /// uniform `bearingStepDeg` lattice — renderers must walk the actual
    /// samples, not reconstruct the grid.
    nonisolated static func computeSkyline(observer: CLLocation,
                                           observerAltitudeOverride: Double? = nil,
                                           bearingStepDeg: Double,
                                           distances: [Double],
                                           maxRange: Double) async
        -> (samples: [SkylineSample], observerAltitude: Double) {
        let ds = distances.filter { $0 <= maxRange }

        // B. DEM-anchored observer altitude. Defence in depth on the
        // sensor side first: a barometer override is an absolute altitude
        // that is exactly 0 before its first sample (and on barometer-less
        // devices), so a non-positive override falls back to GPS altitude.
        // Then reconcile that sensor value with the DEM elevation of the
        // observer's own cell (one query, cached): the silhouette is drawn
        // FROM this DEM, so anchoring the eye to it keeps the whole near
        // silhouette level even when GPS/baro drift by 10–30 m.
        let sensorAlt = (observerAltitudeOverride.flatMap { $0 > 0 ? $0 : nil }) ?? observer.altitude
        let demGround = (await TerrainElevationService.shared
            .elevations(at: [observer.coordinate]).first ?? nil)
        let observerAlt = Geometry.effectiveObserverAltitude(sensor: sensorAlt,
                                                             demGround: demGround)

        func angle(_ distance: Double, _ elevation: Double) -> Double {
            Geometry.apparentAltitudeAngle(observerAltitude: observerAlt,
                                           targetAltitude: elevation,
                                           distance: distance,
                                           radius: Geometry.effectiveEarthRadius)
        }

        /// Winner along one bearing, with the distance bracket around it
        /// (`loD`/`hiD` = the nearest already-sampled distances below/above
        /// the winner) so refinement rounds know where to bisect next.
        struct Winner {
            var sample: SkylineSample
            var angle: Double
            var loD: Double
            var hiD: Double
        }

        /// Full distance scan along each given bearing: pick the sample
        /// with the maximum apparent-altitude angle — with refraction, so
        /// distant ranges that ARE visible in reality don't lose the pick
        /// to an un-refracted curvature drop. That's the skyline.
        func scanBearings(_ bearings: [Double]) async -> [Double: Winner] {
            guard !bearings.isEmpty, !ds.isEmpty else { return [:] }
            struct GridPoint {
                let bearing: Double
                let dIndex: Int
                let coord: CLLocationCoordinate2D
            }
            var grid: [GridPoint] = []
            grid.reserveCapacity(bearings.count * ds.count)
            for bearing in bearings {
                for (i, d) in ds.enumerated() {
                    grid.append(GridPoint(bearing: bearing, dIndex: i,
                                          coord: Geometry.project(from: observer.coordinate,
                                                                  bearing: bearing,
                                                                  distance: d)))
                }
            }
            let elevations = await TerrainElevationService.shared.elevations(
                at: grid.map { $0.coord }
            )
            var best: [Double: Winner] = [:]
            for (i, gp) in grid.enumerated() {
                guard let elev = elevations[i] else { continue }
                let d = ds[gp.dIndex]
                let a = angle(d, elev)
                if let prev = best[gp.bearing], prev.angle >= a { continue }
                best[gp.bearing] = Winner(
                    sample: SkylineSample(bearing: gp.bearing, distance: d, altitude: elev),
                    angle: a,
                    loD: gp.dIndex > 0 ? ds[gp.dIndex - 1] : d,
                    hiD: gp.dIndex + 1 < ds.count ? ds[gp.dIndex + 1] : d)
            }
            return best
        }

        /// F. Distance refinement, `rounds` bracket-tightening passes.
        /// Even a dense schedule can straddle a summit — the coarse winner
        /// is then a flank sample and the silhouette renders low and
        /// lumpy. Each round samples the midpoints between the winner and
        /// its bracket edges, re-picks, and tightens the bracket around
        /// the (possibly moved) winner, so round 2 refines around the
        /// UPDATED winner rather than re-testing the same midpoints.
        func refineDistances(_ best: inout [Double: Winner], rounds: Int) async {
            for _ in 0..<rounds {
                struct RefinePoint {
                    let bearing: Double
                    let distance: Double
                    let isLowSide: Bool
                    let coord: CLLocationCoordinate2D
                }
                var refine: [RefinePoint] = []
                refine.reserveCapacity(best.count * 2)
                for (bearing, w) in best {
                    let win = w.sample.distance
                    let mids: [(m: Double, low: Bool)] = [((w.loD + win) / 2, true),
                                                          ((win + w.hiD) / 2, false)]
                    for (m, low) in mids where m > 0 && abs(m - win) >= 5 {
                        refine.append(RefinePoint(
                            bearing: bearing, distance: m, isLowSide: low,
                            coord: Geometry.project(from: observer.coordinate,
                                                    bearing: bearing, distance: m)))
                    }
                }
                guard !refine.isEmpty else { break }
                let refined = await TerrainElevationService.shared.elevations(
                    at: refine.map { $0.coord }
                )
                var lows: [Double: (d: Double, elev: Double, a: Double)] = [:]
                var highs: [Double: (d: Double, elev: Double, a: Double)] = [:]
                for (i, rp) in refine.enumerated() {
                    guard let elev = refined[i] else { continue }
                    let a = angle(rp.distance, elev)
                    if rp.isLowSide { lows[rp.bearing] = (rp.distance, elev, a) }
                    else { highs[rp.bearing] = (rp.distance, elev, a) }
                }
                for bearing in best.keys {
                    guard var w = best[bearing] else { continue }
                    let lo = lows[bearing]
                    let hi = highs[bearing]
                    let oldWin = w.sample.distance
                    if let hi, hi.a > w.angle, hi.a >= (lo?.a ?? -.infinity) {
                        w = Winner(sample: SkylineSample(bearing: bearing,
                                                         distance: hi.d, altitude: hi.elev),
                                   angle: hi.a, loD: oldWin, hiD: w.hiD)
                    } else if let lo, lo.a > w.angle {
                        w = Winner(sample: SkylineSample(bearing: bearing,
                                                         distance: lo.d, altitude: lo.elev),
                                   angle: lo.a, loD: w.loD, hiD: oldWin)
                    } else {
                        if let lo { w.loD = lo.d }
                        if let hi { w.hiD = hi.d }
                    }
                    best[bearing] = w
                }
            }
        }

        // 1–3. Base fan: uniform `bearingStepDeg` lattice around the circle.
        var bearings: [Double] = []
        var b = 0.0
        while b < 360 {
            bearings.append(b)
            b += bearingStepDeg
        }
        var best = await scanBearings(bearings)
        guard !best.isEmpty else { return ([], observerAlt) }

        // 4/F. Two bracket-tightening distance-refinement rounds.
        await refineDistances(&best, rounds: distanceRefinementRounds)

        // 5/A. Adaptive bearing refinement: subdivide silhouette
        // discontinuities (cliff edges, near/far transitions, narrow
        // summits) with ONE midpoint bearing each — full distance scan
        // plus its own refinement — so the drawn line hugs the real
        // silhouette where it changes fastest. The result is deliberately
        // NOT a uniform lattice any more.
        let sorted = best.values.sorted { $0.sample.bearing < $1.sample.bearing }
        let extraBearings = adaptiveRefinementBearings(
            samples: sorted.map { ($0.sample.bearing, $0.angle * 180 / .pi, $0.sample.distance) }
        )
        if !extraBearings.isEmpty {
            var extraBest = await scanBearings(extraBearings)
            await refineDistances(&extraBest, rounds: distanceRefinementRounds)
            for (bearing, w) in extraBest { best[bearing] = w }
        }

        return (best.values.map { $0.sample }.sorted { $0.bearing < $1.bearing },
                observerAlt)
    }
}
