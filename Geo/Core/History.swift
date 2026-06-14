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
    
    func addTrackingInformation(_ location: CLLocation, _ barometer: Barometer?) {
        
        if self.trackingAltitudeDataSet.count == 0 {
            while self.trackingAltitudeDataSet.count < amountOfValuesToShow {
                self.trackingAltitudeDataSet.append(DataPoint(Value: [0, 0], Legend: trackingDateFormatter.string(from:Date())))
            }
        }
        
        let barometerHeight = barometer?.height ?? 0
        let dataItem = DataPoint(Value: [barometerHeight, location.altitude], Legend: trackingDateFormatter.string(from:Date()))
        self.trackingAltitudeDataSet.append(dataItem)
        
        while self.trackingAltitudeDataSet.count > amountOfValuesToShow {
            self.trackingAltitudeDataSet.removeFirst()
        }
        
        self.trackingAltitudeDataSetMin = altitudeMinDefault
        self.trackingAltitudeDataSetMax = altitudeMaxDefault
        
        guard let minDataItem = trackingAltitudeDataSet.min(by: { $0.Value[0] < $1.Value[0] }),
              let maxDataItem = trackingAltitudeDataSet.max(by: { $0.Value[0] < $1.Value[0] }),
              minDataItem.Value.count >= 2,
              maxDataItem.Value.count >= 2 else { return }
        
        let minValue = min(minDataItem.Value[0], minDataItem.Value[1])
        let maxValue = max(maxDataItem.Value[0], maxDataItem.Value[1])

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
    static let severeDropHPaOver3h = 6.0
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
