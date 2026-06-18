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
    /// to the picker. The previous schedule doubled every step after
    /// 500 m (8 → 16 → 32 → 64 km), which produced ~8 km mid-range
    /// gaps capable of swallowing entire ridges.
    ///
    /// This schedule keeps the close-in metric step (~200 m), then
    /// closes every octave above 1 km with a midpoint so no
    /// consecutive ratio exceeds ~1.5×. ~20 samples × 180 bearings ≈
    /// 3 600 elevation queries per full recompute; the cache in
    /// `TerrainElevationService` amortises that to nearly zero on
    /// subsequent recomputes since the user has to move ≥500 m
    /// before we re-run.
    nonisolated static let skylineDistancesMeters: [Double] = [
        100, 200, 400, 600, 800, 1_000,
        1_500, 2_000, 3_000, 5_000, 7_000, 10_000,
        15_000, 22_000, 32_000, 48_000,
        70_000, 100_000, 140_000, 200_000
    ]

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
            // that case so we don't need to wipe.
            if !new.isEmpty {
                self.samples = new
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

    /// All DEM cells to prefetch for an offline pack: a regular ~110 m
    /// lat/lon grid covering the pack's bounding box (centre ± `radiusKm`),
    /// snapped to the cache's milli-degree lattice and capped to
    /// `offlineMaxDEMCells`.
    ///
    /// This replaces the old single-observer *fan*, which only lined up
    /// with the live lookups when the observer stood exactly at the pack
    /// centre — off-centre observers' fans projected to different cells, so
    /// every offline lookup missed and the skyline went empty. An area grid
    /// covers the cells any observer in the area will look up. Order is not
    /// significant to callers.
    nonisolated static func offlinePrefetchCoordinates(center: CLLocationCoordinate2D,
                                                       radiusKm: Double) -> [CLLocationCoordinate2D] {
        let step = offlineCellStepDeg
        let metersPerDegLat = 111_320.0
        let cosLat = max(0.01, cos(center.latitude * .pi / 180))
        var halfLatDeg = (radiusKm * 1000) / metersPerDegLat
        var halfLonDeg = (radiusKm * 1000) / (metersPerDegLat * cosLat)

        // Shrink the covered square (NOT the resolution) if a full-res grid
        // would blow the cell budget, so a live lookup never lands in a gap.
        let latNodes = Int((2 * halfLatDeg) / step) + 1
        let lonNodes = Int((2 * halfLonDeg) / step) + 1
        let total = latNodes * lonNodes
        if total > offlineMaxDEMCells {
            let scale = (Double(offlineMaxDEMCells) / Double(total)).squareRoot()
            halfLatDeg *= scale
            halfLonDeg *= scale
        }

        // Snap the centre to the milli-degree lattice and step exactly one
        // cell at a time so every node maps to its own distinct cache cell
        // (no phase drift, no gaps, no duplicates vs the live lookups).
        let cLat = (center.latitude * 1000).rounded() / 1000
        let cLon = (center.longitude * 1000).rounded() / 1000
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

    // MARK: - Pure computation

    /// Static + nonisolated so the whole pass can run off the main
    /// actor — there are thousands of trig calls per pass.
    nonisolated static func computeSkyline(observer: CLLocation,
                                           observerAltitudeOverride: Double? = nil,
                                           bearingStepDeg: Double,
                                           distances: [Double],
                                           maxRange: Double) async -> [SkylineSample] {
        // 1. Build the (bearing, distance, lat, lon) sample grid.
        var bearings: [Double] = []
        var b = 0.0
        while b < 360 {
            bearings.append(b)
            b += bearingStepDeg
        }
        struct GridPoint {
            let bearing: Double
            let distance: Double
            let coord: CLLocationCoordinate2D
        }
        var grid: [GridPoint] = []
        grid.reserveCapacity(bearings.count * distances.count)
        for bearing in bearings {
            for d in distances where d <= maxRange {
                let coord = Geometry.project(from: observer.coordinate,
                                             bearing: bearing,
                                             distance: d)
                grid.append(GridPoint(bearing: bearing, distance: d, coord: coord))
            }
        }

        // 2. Resolve elevations in batched HTTP calls.
        let elevations = await TerrainElevationService.shared.elevations(
            at: grid.map { $0.coord }
        )

        // 3. For each bearing, pick the sample with the maximum
        //    apparent-altitude angle. That's the skyline.
        // Defence in depth: a barometer override is an absolute altitude
        // that is exactly 0 before its first sample (and on barometer-less
        // devices), so ignore a non-positive override and fall back to GPS
        // altitude rather than computing the skyline at sea level.
        let observerAlt = (observerAltitudeOverride.flatMap { $0 > 0 ? $0 : nil }) ?? observer.altitude
        var bestPerBearing: [Double: (sample: SkylineSample, angle: Double)] = [:]
        for (i, gp) in grid.enumerated() {
            guard let elev = elevations[i] else { continue }
            let angle = Geometry.apparentAltitudeAngle(
                observerAltitude: observerAlt,
                targetAltitude: elev,
                distance: gp.distance
            )
            if let prev = bestPerBearing[gp.bearing], prev.angle >= angle { continue }
            bestPerBearing[gp.bearing] = (
                sample: SkylineSample(bearing: gp.bearing,
                                      distance: gp.distance,
                                      altitude: elev),
                angle: angle
            )
        }

        return bestPerBearing.values
            .map { $0.sample }
            .sorted { $0.bearing < $1.bearing }
    }
}
