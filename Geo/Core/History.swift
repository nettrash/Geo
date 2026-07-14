//
//  History.swift
//  Geo
//
//  Created by nettrash on 06/09/2024.
//

import Foundation
import CoreData
import CoreLocation
import WidgetKit

/// `@unchecked Sendable` — `History` is mutated exclusively on the
/// main thread (every `Refresh`, `markDirty`, and dataset rebuild
/// runs on `viewContext`'s queue, i.e. main). Marking it explicitly
/// lets us hand the instance to background dispatch closures (e.g.
/// the buffered-sample backfill in `GeoAppDelegate`) that hop back
/// to main before touching it, without strict-concurrency
/// diagnostics firing.
@Observable
final class History: NSObject, ObservableObject, @unchecked Sendable {
    
    var historyItems: [HistoryItem] = []
    
    var pressureDataSet: [DataItem] = []
    var pressureDataSetMin: CGFloat = 0
    var pressureDataSetMax: CGFloat = 0

    var altitudeBarometerDataSet: [DataItem] = []
    var altitudeBarometerDataSetMin: CGFloat = 0
    var altitudeBarometerDataSetMax: CGFloat = 0

    var altitudeGPSDataSet: [DataItem] = []
    var altitudeGPSDataSetMin: CGFloat = 0
    var altitudeGPSDataSetMax: CGFloat = 0

    var trackingAltitudeDataSet: [DataPoint] = []
    var trackingAltitudeDataSetMin: CGFloat = 0
    var trackingAltitudeDataSetMax: CGFloat = 0

    /// Latest de-trended pressure tendency (M5a), recomputed on every
    /// `Refresh()`. Drives the in-app barometer-card trend chip; the
    /// authoritative storm alerting runs off the BGTask in
    /// `GeoAppDelegate` over the freshest merged sample set.
    var latestPressureTrend: PressureTrend = .unknown

    private let amountOfValuesToShow: Int = 30
    let pressureDataSetMinDefault: CGFloat = 0
    let pressureDataSetMaxDefault: CGFloat = 1000
    let altitudeMinDefault: CGFloat = 0
    let altitudeMaxDefault: CGFloat = 10000

    private let numberOfDays: Int = 30

    /// How long a `HistoryItem` is kept before retention pruning removes
    /// it. ~366 days so a full year (including a leap day) of history is
    /// always available to the statistics views.
    private let retentionDays: Int = 366

    /// Ensures the launch-time retention prune runs only once per
    /// `History` lifetime, on the first `Refresh()`.
    private var didPrune: Bool = false

    /// Set to `true` whenever a new HistoryItem is inserted. Cleared by
    /// `Refresh()`. Lets callers (e.g. the AR Nature view) skip the
    /// expensive CoreData fetch when nothing has changed since the last
    /// pass.
    private var isDirty: Bool = true

    /// Mark the cache stale. Called from anywhere that adds/edits a
    /// `HistoryItem` outside of `Refresh()` itself (e.g. inbound Watch
    /// samples or widget backfill).
    func markDirty() {
        self.isDirty = true
    }

    /// True when no fetch has happened yet, or when `markDirty()` has
    /// been called since the last fetch.
    var needsRefresh: Bool { isDirty }

    /// Refresh only when actually needed; cheap no-op otherwise.
    func refreshIfNeeded() {
        guard isDirty else { return }
        Refresh()
    }

    private let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter
        }()

    private let trackingDateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return formatter
        }()

    func Refresh() {
        // Retention prune, once per launch: drop items older than the
        // retention window before the first fetch so stale rows never
        // accumulate. Failure-tolerant — logged and ignored on error.
        if !self.didPrune {
            self.didPrune = true
            self.prune()
        }

        do {
            let controller = PersistenceController.shared
            let fetchRequest: NSFetchRequest<HistoryItem> = HistoryItem.fetchRequest()
            guard let cutoffDate = Calendar.current.date(byAdding: .day, value: -self.numberOfDays, to: Date()) else { return }
            fetchRequest.predicate = NSPredicate(
                format: "recordDate >= %@ and barometerPressure > 0", cutoffDate as CVarArg
            )

            fetchRequest.sortDescriptors = [
                NSSortDescriptor(keyPath: \HistoryItem.recordDate, ascending: true)
                ]

            self.historyItems = try controller.container.viewContext.fetch(fetchRequest)
        }
        catch let error {
            switch error {
            default:
                self.historyItems = []
                AppLog.history.error("Error fetching HistoryItems: \(String(describing: error))")
            }
        }
        self.pressureDataSetRefresh()
        self.barometerDataSetRefresh()
        self.gpsDataSetRefresh()
        self.latestPressureTrend = self.pressureTrend(now: Date())

        // Successful refresh clears the dirty flag.
        self.isDirty = false

        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Retention prune: delete `HistoryItem`s older than `retentionDays`.
    /// Uses a fetch-and-delete on `viewContext` (rather than a batch
    /// delete) so the deletions are tracked for CloudKit sync and merged
    /// into the live context. Failure-tolerant: any error is logged and
    /// swallowed so a prune failure never blocks a refresh.
    func prune() {
        let context = PersistenceController.shared.container.viewContext
        guard let cutoffDate = Calendar.current.date(byAdding: .day, value: -self.retentionDays, to: Date()) else { return }
        let fetchRequest: NSFetchRequest<HistoryItem> = HistoryItem.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "recordDate < %@", cutoffDate as CVarArg)
        do {
            let stale = try context.fetch(fetchRequest)
            guard !stale.isEmpty else { return }
            for item in stale {
                context.delete(item)
            }
            if context.hasChanges {
                try context.save()
            }
        } catch {
            AppLog.history.error("Error pruning HistoryItems: \(String(describing: error))")
        }
    }

    /// Delete every `HistoryItem` and reset the in-memory datasets.
    /// Destructive — callers must gate this behind a user confirmation.
    /// Failure-tolerant: any error is logged and swallowed.
    func clearAll() {
        let context = PersistenceController.shared.container.viewContext
        let fetchRequest: NSFetchRequest<HistoryItem> = HistoryItem.fetchRequest()
        do {
            let all = try context.fetch(fetchRequest)
            for item in all {
                context.delete(item)
            }
            if context.hasChanges {
                try context.save()
            }
        } catch {
            AppLog.history.error("Error clearing HistoryItems: \(String(describing: error))")
        }

        // Reset the in-memory state regardless of the delete outcome so
        // the views reflect an empty store immediately.
        self.historyItems = []
        self.pressureDataSet = []
        self.altitudeBarometerDataSet = []
        self.altitudeGPSDataSet = []
        self.markDirty()

        WidgetCenter.shared.reloadAllTimelines()
    }

    func pressureDataSetRefresh() {
        self.pressureDataSet.removeAll()

        if self.historyItems.count < 1 {
            return
        }
        
        guard let minDate: Date = Calendar.current.date(byAdding: .day, value: -(self.numberOfDays - 1), to: Calendar.current.startOfDay(for: Date())) else { return }

        for idx in 0..<amountOfValuesToShow {
            // Calendar arithmetic on a Gregorian calendar, adding a
            // small positive integer of days, will not return nil in
            // practice — but unwrap defensively rather than force-
            // unwrap, since static analysers (App Store Review uses
            // them) flag the `!` form.
            guard let currentDate = Calendar.current.date(byAdding: .day, value: idx, to: minDate) else { continue }
            let minPreassure: CGFloat = self.historyItems
                .filter { guard let rd = $0.recordDate else { return false }; return Calendar.current.startOfDay(for: rd) == currentDate }
                .min(by: { $0.barometerPressure < $1.barometerPressure })?.barometerPressure ?? 0
            self.pressureDataSet.append(DataItem(Value: minPreassure * 7.50062, Legend: dateFormatter.string(from:currentDate)))
        }

        while self.pressureDataSet.count < amountOfValuesToShow {
            self.pressureDataSet.append(DataItem(Value: 0, Legend: dateFormatter.string(from:Calendar.current.startOfDay(for: Date()))))
        }

        self.pressureDataSetMin = pressureDataSetMinDefault
        self.pressureDataSetMax = pressureDataSetMaxDefault
        
        guard let minDataItem = self.pressureDataSet.min(by: { $0.Value < $1.Value }),
              let maxDataItem = self.pressureDataSet.max(by: { $0.Value < $1.Value }) else { return }
        
        if (minDataItem.Value - 50 > pressureDataSetMinDefault) {
            self.pressureDataSetMin = minDataItem.Value - 50
        }

        if (maxDataItem.Value + 50 < pressureDataSetMaxDefault) {
            self.pressureDataSetMax = maxDataItem.Value + 50
        }
    }
    
    func barometerDataSetRefresh() {
        self.altitudeBarometerDataSet.removeAll()

        if self.historyItems.count < 1 {
            return
        }
        
        guard let minDate: Date = Calendar.current.date(byAdding: .day, value: -(self.numberOfDays - 1), to: Calendar.current.startOfDay(for: Date())) else { return }

        for idx in 0..<amountOfValuesToShow {
            guard let currentDate = Calendar.current.date(byAdding: .day, value: idx, to: minDate) else { continue }
            let maxBarometerAltitude: CGFloat = self.historyItems
                .filter { guard let rd = $0.recordDate else { return false }; return Calendar.current.startOfDay(for: rd) == currentDate }
                .max(by: { $0.barometerAltitude < $1.barometerAltitude })?.barometerAltitude ?? 0
            self.altitudeBarometerDataSet.append(DataItem(Value: maxBarometerAltitude, Legend: dateFormatter.string(from:currentDate)))
        }

        while self.altitudeBarometerDataSet.count < amountOfValuesToShow {
            self.altitudeBarometerDataSet.append(DataItem(Value: 0, Legend: dateFormatter.string(from:Calendar.current.startOfDay(for: Date()))))
        }
        
        self.altitudeBarometerDataSetMin = altitudeMinDefault
        self.altitudeBarometerDataSetMax = altitudeMaxDefault
        
        guard let minDataItem = self.altitudeBarometerDataSet.min(by: { $0.Value < $1.Value }),
              let maxDataItem = self.altitudeBarometerDataSet.max(by: { $0.Value < $1.Value }) else { return }
        
        if (minDataItem.Value - 50 > altitudeMinDefault) {
            self.altitudeBarometerDataSetMin = minDataItem.Value - 50
        } else {
            if (minDataItem.Value < altitudeMinDefault) {
                self.altitudeBarometerDataSetMin = minDataItem.Value
            }
        }

        if (maxDataItem.Value + 50 < altitudeMaxDefault) {
            self.altitudeBarometerDataSetMax = maxDataItem.Value + 50
        } else {
            if (maxDataItem.Value > altitudeMaxDefault) {
                self.altitudeBarometerDataSetMax = maxDataItem.Value
            }
        }
    }
    
    func gpsDataSetRefresh() {
        self.altitudeGPSDataSet.removeAll()

        if self.historyItems.count < 1 {
            return
        }
        
        guard let minDate: Date = Calendar.current.date(byAdding: .day, value: -(self.numberOfDays - 1), to: Calendar.current.startOfDay(for: Date())) else { return }

        for idx in 0..<amountOfValuesToShow {
            guard let currentDate = Calendar.current.date(byAdding: .day, value: idx, to: minDate) else { continue }
            let maxGPSAltitude: CGFloat = self.historyItems
                .filter { guard let rd = $0.recordDate else { return false }; return Calendar.current.startOfDay(for: rd) == currentDate }
                .max(by: { $0.gpsAltitude < $1.gpsAltitude })?.gpsAltitude ?? 0
            self.altitudeGPSDataSet.append(DataItem(Value: maxGPSAltitude, Legend: dateFormatter.string(from:currentDate)))
        }

        while self.altitudeGPSDataSet.count < amountOfValuesToShow {
            self.altitudeGPSDataSet.append(DataItem(Value: 0, Legend: dateFormatter.string(from:Calendar.current.startOfDay(for: Date()))))
        }

        self.altitudeGPSDataSetMin = altitudeMinDefault
        self.altitudeGPSDataSetMax = altitudeMaxDefault
        
        guard let minDataItem = self.altitudeGPSDataSet.min(by: { $0.Value < $1.Value }),
              let maxDataItem = self.altitudeGPSDataSet.max(by: { $0.Value < $1.Value }) else { return }
        
        if (minDataItem.Value - 50 > altitudeMinDefault) {
            self.altitudeGPSDataSetMin = minDataItem.Value - 50
        } else {
            if (minDataItem.Value < altitudeMinDefault) {
                self.altitudeGPSDataSetMin = minDataItem.Value
            }
        }

        if (maxDataItem.Value + 50 < altitudeMaxDefault) {
            self.altitudeGPSDataSetMax = maxDataItem.Value + 50
        } else {
            if maxDataItem.Value > altitudeMaxDefault {
                self.altitudeGPSDataSetMax = maxDataItem.Value
            }
        }
    }
    
    /// Append one real-time tracking sample to the tracking graph. Both
    /// series values are optional and independent: passing `nil` records a
    /// `.nan` gap for that series, so its line breaks (and auto-scaling
    /// ignores it) rather than collapsing to sea level. This is what keeps
    /// the barometer (white) line live when GPS is unavailable — the caller
    /// passes `gpsAltitude: nil` and only the barometer series is drawn;
    /// likewise a device with no barometer draws only the GPS (orange) line.
    /// The caller (`Location`) owns "what counts as usable" for each sensor.
    func addTrackingInformation(barometerHeight: CGFloat?, gpsAltitude: CGFloat?) {

        // Seed the ring buffer with NaN placeholders so the graph starts
        // empty (nothing drawn) and fills from the right as real samples
        // arrive, instead of showing a misleading flat line at sea level
        // until the first ~30 real samples scroll the zeros out.
        if self.trackingAltitudeDataSet.count == 0 {
            while self.trackingAltitudeDataSet.count < amountOfValuesToShow {
                self.trackingAltitudeDataSet.append(DataPoint(Value: [.nan, .nan], Legend: trackingDateFormatter.string(from:Date())))
            }
        }

        let dataItem = DataPoint(Value: [barometerHeight ?? .nan, gpsAltitude ?? .nan],
                                 Legend: trackingDateFormatter.string(from:Date()))
        self.trackingAltitudeDataSet.append(dataItem)

        while self.trackingAltitudeDataSet.count > amountOfValuesToShow {
            self.trackingAltitudeDataSet.removeFirst()
        }

        // Auto-scale over every finite sample across both series; NaN gaps
        // are ignored so a missing GPS/barometer series never skews the
        // window. With nothing finite yet, keep the default altitude range.
        self.trackingAltitudeDataSetMin = altitudeMinDefault
        self.trackingAltitudeDataSetMax = altitudeMaxDefault

        let finite = trackingAltitudeDataSet.flatMap { $0.Value }.filter { $0.isFinite }
        guard let minValue = finite.min(), let maxValue = finite.max() else { return }

        if (minValue - 250 > altitudeMinDefault) {
            self.trackingAltitudeDataSetMin = minValue - 50
        } else {
            if minValue < altitudeMinDefault {
                self.trackingAltitudeDataSetMin = minValue
            }
        }

        if (maxValue + 250 < altitudeMaxDefault) {
            self.trackingAltitudeDataSetMax = maxValue + 50
        } else {
            if maxValue > altitudeMaxDefault {
                self.trackingAltitudeDataSetMax = maxValue
            }
        }
    }

    // MARK: - Pressure-trend storm warning (M5a)

    /// De-trended 3-hour barometric tendency built from this `History`'s
    /// in-memory `historyItems` (foreground use). The alerting path runs
    /// off the BGTask in `GeoAppDelegate`, which feeds the fit a merged
    /// CoreData + buffered-snapshot sample set; this convenience exists
    /// for any in-app readout that wants the same classification.
    func pressureTrend(now: Date = Date()) -> PressureTrend {
        let samples = self.historyItems.compactMap { item -> PressureSample? in
            guard let rd = item.recordDate else { return nil }
            return PressureSample(date: rd,
                                  pressureKPa: item.barometerPressure,
                                  altitudeM: item.gpsAltitude)
        }
        return StormWarning.tendency(samples, now: now)
    }
}

// MARK: - Storm-warning model (shared with Android `StormWarning`)

/// One barometric sample for the storm-warning tendency fit. Carries the
/// RAW station pressure (kPa, already clamped 30–110 upstream) and the GPS
/// altitude (m) so the fit can remove the altitude-driven pressure change
/// before classifying the weather tendency.
struct PressureSample: Sendable {
    let date: Date
    let pressureKPa: Double
    let altitudeM: Double
}

/// Coarse classification of the de-trended 3-hour barometric tendency.
enum PressureTrendClass {
    case unknown      // not enough data to classify — never alerts
    case rising
    case steady
    case falling      // a real but sub-threshold fall — no alert
    case fallingFast  // crosses the storm threshold — alert-worthy
}

/// Result of a tendency fit: the class plus the signed de-trended change
/// in hectopascals over the 3-hour window (negative = falling).
struct PressureTrend: Equatable {
    let classification: PressureTrendClass
    let changeHPaOver3h: Double
    var isAlert: Bool { classification == .fallingFast }
    static let unknown = PressureTrend(classification: .unknown, changeHPaOver3h: 0)
}

/// Pure, dependency-free storm-warning math. Kept byte-identical to the
/// Android `me.nettrash.geo.sensor.StormWarning` so both platforms
/// classify a given history the same way (the cross-platform parity
/// invariant). The fit lives here in `History` per the v1.1 plan; the
/// BGTask path in `GeoAppDelegate` feeds it the merged CoreData +
/// buffered samples and turns an alert into a local notification.
enum StormWarning {
    // ── Shared constants — MUST match Android StormWarning ──────────
    static let windowHours = 3.0
    static let minSamples = 4
    static let minSpanHours = 1.5
    static let steadyBandHPaOver3h = 1.0
    static let alertDropHPaOver3h = 3.0
    static let notificationCooldownHours = 3.0
    static let altClampLow = -500.0
    static let altClampHigh = 9000.0
    private static let barometricScale = 44330.0
    private static let barometricExponent = 5.255

    /// Standard-atmosphere pressure ratio P(alt)/P(0) at `altM`, with the
    /// altitude clamped to the app's plausible domain so a noisy GPS
    /// reading can't blow up the correction factor.
    private static func pressureRatio(_ altM: Double) -> Double {
        let a = min(max(altM, altClampLow), altClampHigh)
        return pow(1.0 - a / barometricScale, barometricExponent)
    }

    /// De-trended 3-hour barometric tendency for `samples` evaluated at
    /// `now`. Reads RAW station pressure and removes the GPS-altitude-
    /// driven pressure component (correcting every sample to the most
    /// recent sample's altitude) before a least-squares slope, so a climb
    /// doesn't read as a falling barometer. Returns `.unknown` when the
    /// window is too thin to classify.
    static func tendency(_ samples: [PressureSample], now: Date) -> PressureTrend {
        let windowStart = now.addingTimeInterval(-windowHours * 3600)
        let win = samples
            .filter { $0.date >= windowStart && $0.date <= now && $0.pressureKPa > 0 && $0.pressureKPa.isFinite }
            .sorted { $0.date < $1.date }

        guard win.count >= minSamples, let first = win.first, let last = win.last else {
            return .unknown
        }
        let spanHours = last.date.timeIntervalSince(first.date) / 3600
        guard spanHours >= minSpanHours else { return .unknown }

        // Correct each raw station pressure to the most-recent sample's
        // altitude so the fitted slope reflects weather, not climbing.
        let refRatio = pressureRatio(last.altitudeM)
        let n = Double(win.count)
        let t0 = first.date
        var sumT = 0.0, sumY = 0.0, sumTT = 0.0, sumTY = 0.0
        for s in win {
            let t = s.date.timeIntervalSince(t0) / 3600                       // hours
            let y = s.pressureKPa * 10.0 * (refRatio / pressureRatio(s.altitudeM)) // hPa
            sumT += t; sumY += y; sumTT += t * t; sumTY += t * y
        }
        let meanT = sumT / n, meanY = sumY / n
        let den = sumTT - n * meanT * meanT
        guard den > 0 else { return .unknown }
        let slope = (sumTY - n * meanT * meanY) / den                         // hPa per hour
        let change3h = slope * 3.0                                            // signed hPa / 3 h

        let cls: PressureTrendClass
        if change3h <= -alertDropHPaOver3h {
            cls = .fallingFast
        } else if change3h <= -steadyBandHPaOver3h {
            cls = .falling
        } else if change3h >= steadyBandHPaOver3h {
            cls = .rising
        } else {
            cls = .steady
        }
        return PressureTrend(classification: cls, changeHPaOver3h: change3h)
    }
}

// MARK: - Trip Recorder (M5c)

/// One sample fed to the trip-summary math. Neutral value type so the stat
/// functions stay pure + testable without Core Data, and byte-identical to
/// Android `me.nettrash.geo.util.TripSample`.
struct TripSample: Sendable {
    let timeMs: Int64
    let altitude: Double   // barometric altitude (m) — precise relative change
    let latitude: Double
    let longitude: Double
    let speed: Double      // m/s
}

/// Computed summary of an outing. All distances in metres, times in seconds.
struct TripSummary: Equatable, Sendable {
    var totalAscent: Double = 0
    var totalDescent: Double = 0
    var maxAltitude: Double = 0
    var minAltitude: Double = 0
    var distance: Double = 0
    var movingTime: Double = 0
}

/// Pure trip-summary math. Byte-identical to Android `TripStats`.
enum TripStats {
    /// Altitude deltas below this are treated as sensor noise and don't
    /// count toward ascent/descent — without it jitter inflates elevation
    /// gain wildly.
    static let ascentSmoothingMeters = 3.0
    /// Below this speed the user is considered stopped (excluded from moving time).
    static let movingSpeedMps = 0.5
    /// Cap a single inter-sample gap so a long pause / background gap can't
    /// inflate moving time.
    static let maxSegmentSeconds = 60.0

    /// Summarise a time-ascending list of samples. Ascent/descent use a
    /// moving-reference hysteresis so slow real climbs still count while
    /// sub-3 m noise is dropped; distance is the haversine path over valid
    /// GPS points; moving time sums only segments above the speed floor.
    static func summary(_ samples: [TripSample]) -> TripSummary {
        guard let first = samples.first else { return TripSummary() }

        var maxAlt = first.altitude
        var minAlt = first.altitude
        for sample in samples {
            maxAlt = max(maxAlt, sample.altitude)
            minAlt = min(minAlt, sample.altitude)
        }

        var ref = first.altitude
        var ascent = 0.0
        var descent = 0.0
        var distance = 0.0
        var movingTime = 0.0

        for i in 1..<samples.count {
            let prev = samples[i - 1]
            let cur = samples[i]

            let delta = cur.altitude - ref
            if delta >= ascentSmoothingMeters {
                ascent += delta
                ref = cur.altitude
            } else if delta <= -ascentSmoothingMeters {
                descent += -delta
                ref = cur.altitude
            }

            if !(prev.latitude == 0 && prev.longitude == 0),
               !(cur.latitude == 0 && cur.longitude == 0) {
                distance += Geometry.distanceBetween(lat1: prev.latitude, lon1: prev.longitude,
                                                     lat2: cur.latitude, lon2: cur.longitude)
            }

            let dtSec = Double(cur.timeMs - prev.timeMs) / 1000.0
            if dtSec > 0, cur.speed >= movingSpeedMps {
                movingTime += min(dtSec, maxSegmentSeconds)
            }
        }

        return TripSummary(totalAscent: ascent, totalDescent: descent,
                           maxAltitude: maxAlt, minAltitude: minAlt,
                           distance: distance, movingTime: movingTime)
    }
}

extension History {

    /// Recorded samples in `[start, end]`, recordDate-ascending (uses the
    /// recordDate index). Excludes garbage zero-pressure rows.
    func getItemsBetween(start: Date, end: Date) -> [HistoryItem] {
        let context = PersistenceController.shared.container.viewContext
        let request: NSFetchRequest<HistoryItem> = HistoryItem.fetchRequest()
        request.predicate = NSPredicate(format: "recordDate >= %@ AND recordDate <= %@ AND barometerPressure > 0",
                                        start as NSDate, end as NSDate)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \HistoryItem.recordDate, ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    /// History rows in `[start, end]` mapped to neutral stat samples
    /// (barometric altitude for precise relative change).
    func tripSamples(start: Date, end: Date) -> [TripSample] {
        getItemsBetween(start: start, end: end).compactMap { item in
            guard let date = item.recordDate else { return nil }
            return TripSample(timeMs: Int64(date.timeIntervalSince1970 * 1000),
                              altitude: item.barometerAltitude,
                              latitude: item.gpsLatitude,
                              longitude: item.gpsLongitude,
                              speed: item.gpsVelocity)
        }
    }

    /// Barometric-altitude elevation profile for `[start, end]`, downsampled
    /// to at most `maxPoints` points for charting.
    func tripElevationProfile(start: Date, end: Date, maxPoints: Int = 120) -> [Double] {
        guard maxPoints > 0 else { return [] }   // "at most maxPoints" — 0 means none
        let altitudes = getItemsBetween(start: start, end: end).map { $0.barometerAltitude }
        guard altitudes.count > maxPoints else { return altitudes }
        let stride = Double(altitudes.count) / Double(maxPoints)
        return (0..<maxPoints).map { altitudes[Int(Double($0) * stride)] }
    }

    /// Create + persist a `Trip` whose summary is computed once from the
    /// samples in `[start, end]` and denormalised so it survives history
    /// pruning. Returns the saved trip, or `nil` on failure.
    @discardableResult
    func saveTrip(name: String, start: Date, end: Date) -> Trip? {
        let context = PersistenceController.shared.container.viewContext
        let summary = TripStats.summary(tripSamples(start: start, end: end))

        let trip = Trip(context: context)
        trip.id = UUID()
        trip.name = name
        trip.startDate = start
        trip.endDate = end
        trip.totalAscent = summary.totalAscent
        trip.totalDescent = summary.totalDescent
        trip.maxAltitude = summary.maxAltitude
        trip.minAltitude = summary.minAltitude
        trip.distance = summary.distance
        trip.movingTime = summary.movingTime
        do {
            try context.save()
            return trip
        } catch {
            AppLog.history.error("Failed to save trip: \(String(describing: error))")
            context.rollback()
            return nil
        }
    }

    /// All saved trips, newest first.
    func fetchTrips() -> [Trip] {
        let context = PersistenceController.shared.container.viewContext
        let request: NSFetchRequest<Trip> = Trip.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Trip.startDate, ascending: false)]
        return (try? context.fetch(request)) ?? []
    }

    func deleteTrip(_ trip: Trip) {
        let context = PersistenceController.shared.container.viewContext
        context.delete(trip)
        try? context.save()
    }

    // MARK: - Summit log (auto-detect arrival at a known peak)

    /// Persist a logged ascent. Peak fields are denormalised (public
    /// bundled-list data) so the trophy entry survives list changes; the
    /// user's own `measuredAltitude` is the on-device barometric reading at
    /// log time. CloudKit-synced like `Trip`.
    @discardableResult
    func saveSummit(peakName: String, peakIdentifier: String, peakSet: String,
                    peakHeight: Double, latitude: Double, longitude: Double,
                    measuredAltitude: Double, note: String, date: Date = Date()) -> SummitLog? {
        let context = PersistenceController.shared.container.viewContext
        let log = SummitLog(context: context)
        log.id = UUID()
        log.peakName = peakName
        log.peakIdentifier = peakIdentifier
        log.peakSet = peakSet
        log.peakHeight = peakHeight
        log.peakLatitude = latitude
        log.peakLongitude = longitude
        log.measuredAltitude = measuredAltitude
        log.note = note
        log.loggedDate = date
        do {
            try context.save()
            return log
        } catch {
            AppLog.history.error("Failed to save summit log: \(String(describing: error))")
            context.rollback()
            return nil
        }
    }

    func fetchSummits() -> [SummitLog] {
        let context = PersistenceController.shared.container.viewContext
        let request: NSFetchRequest<SummitLog> = SummitLog.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \SummitLog.loggedDate, ascending: false)]
        return (try? context.fetch(request)) ?? []
    }

    func deleteSummit(_ log: SummitLog) {
        let context = PersistenceController.shared.container.viewContext
        context.delete(log)
        try? context.save()
    }

    func updateSummitNote(_ log: SummitLog, note: String) {
        let context = PersistenceController.shared.container.viewContext
        log.note = note
        try? context.save()
    }

    /// Whether `peakIdentifier` was logged within the last `hours` — used to
    /// suppress re-prompting while the user lingers on a summit.
    func hasRecentSummit(peakIdentifier: String, withinHours hours: Double) -> Bool {
        let context = PersistenceController.shared.container.viewContext
        let request: NSFetchRequest<SummitLog> = SummitLog.fetchRequest()
        let cutoff = Date().addingTimeInterval(-hours * 3600)
        request.predicate = NSPredicate(format: "peakIdentifier == %@ AND loggedDate >= %@",
                                        peakIdentifier, cutoff as NSDate)
        request.fetchLimit = 1
        return ((try? context.count(for: request)) ?? 0) > 0
    }
}

// `Trip` already conforms to `Identifiable` via Core Data codegen (it has
// an `id` attribute), so no manual conformance is needed.

/// Observable wrapper around in-progress trip recording plus the saved trip
/// list. The in-progress start time is persisted (UserDefaults) so a
/// recording survives an app restart; saving denormalises the summary via
/// `History.saveTrip`. Owned by `GeoAppDelegate`, consumed by the Stat tab.
@Observable
final class TripRecorder {
    private let startKey = "TripRecordingStartedAt"
    private let history: History

    /// Non-nil while a trip is being recorded.
    var startedAt: Date?
    /// Saved trips, newest first.
    var trips: [Trip] = []

    init(history: History) {
        self.history = history
        self.startedAt = UserDefaults.standard.object(forKey: startKey) as? Date
        reload()
    }

    var isRecording: Bool { startedAt != nil }

    func start() {
        let now = Date()
        startedAt = now
        UserDefaults.standard.set(now, forKey: startKey)
    }

    @discardableResult
    func stop(name: String) -> Trip? {
        guard let start = startedAt else { return nil }
        // Keep the in-progress recording if the save fails (e.g. a transient
        // Core Data / CloudKit error) so the user can retry rather than lose it.
        guard let trip = history.saveTrip(name: name, start: start, end: Date()) else {
            return nil
        }
        cancel()
        reload()
        return trip
    }

    /// Abandon the in-progress recording without saving a trip.
    func cancel() {
        startedAt = nil
        UserDefaults.standard.removeObject(forKey: startKey)
    }

    func reload() { trips = history.fetchTrips() }

    func delete(_ trip: Trip) {
        history.deleteTrip(trip)
        reload()
    }

    func elevationProfile(for trip: Trip) -> [Double] {
        guard let start = trip.startDate, let end = trip.endDate else { return [] }
        return history.tripElevationProfile(start: start, end: end)
    }
}
