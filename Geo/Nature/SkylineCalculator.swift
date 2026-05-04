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
    private let maxRangeMeters: Double = 200_000

    /// Bearings sampled — 6° spacing → 60 samples around the full circle.
    private let bearingStepDeg: Double = 6

    /// Distance samples per bearing, log-spaced. More samples closer
    /// to the observer (where small hills matter) and a few far ones
    /// for true horizon ridges.
    private let distancesMeters: [Double] = [
        500, 1_000, 2_000, 4_000, 8_000,
        16_000, 32_000, 64_000, 128_000, 200_000
    ]

    private var lastObserver: CLLocation?
    private var fetchTask: Task<Void, Never>?

    /// Trigger a recompute if the observer has moved far enough since
    /// the last one. Cheap to call from a Timer / onReceive.
    func computeIfNeeded(observer: CLLocation) {
        if let last = lastObserver,
           last.distance(from: observer) < recomputeDistance,
           !samples.isEmpty {
            return
        }
        compute(observer: observer)
    }

    /// Force a recompute regardless of distance moved.
    func compute(observer: CLLocation) {
        fetchTask?.cancel()
        lastObserver = observer
        let captured = observer
        fetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isComputing = true
            defer { self.isComputing = false }
            let new = await Self.computeSkyline(
                observer: captured,
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

    // MARK: - Pure computation

    /// Static + nonisolated so the whole pass can run off the main
    /// actor — there are thousands of trig calls per pass.
    nonisolated static func computeSkyline(observer: CLLocation,
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
        let observerAlt = observer.altitude
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
