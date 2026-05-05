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

    private let amountOfValuesToShow: Int = 30
    let pressureDataSetMinDefault: CGFloat = 0
    let pressureDataSetMaxDefault: CGFloat = 1000
    let altitudeMinDefault: CGFloat = 0
    let altitudeMaxDefault: CGFloat = 10000

    private let numberOfDays: Int = 30

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

        // Successful refresh clears the dirty flag.
        self.isDirty = false

        WidgetCenter.shared.reloadAllTimelines()
    }
    
    func pressureDataSetRefresh() {
        self.pressureDataSet.removeAll()

        if self.historyItems.count < 1 {
            return
        }
        
        guard let earliestItem = self.historyItems.min(by: { ($0.recordDate ?? .distantPast) < ($1.recordDate ?? .distantPast) }),
              let earliestDate = earliestItem.recordDate else { return }
        let minDate: Date = Calendar.current.startOfDay(for: earliestDate)
        
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
        
        guard let earliestItem = self.historyItems.min(by: { ($0.recordDate ?? .distantPast) < ($1.recordDate ?? .distantPast) }),
              let earliestDate = earliestItem.recordDate else { return }
        let minDate: Date = Calendar.current.startOfDay(for: earliestDate)
        
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
        
        if (minDataItem.Value - 250 > altitudeMinDefault) {
            self.altitudeBarometerDataSetMin = minDataItem.Value - 50
        } else {
            if (minDataItem.Value < altitudeMinDefault) {
                self.altitudeBarometerDataSetMin = minDataItem.Value
            }
        }

        if (maxDataItem.Value + 250 < altitudeMaxDefault) {
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
        
        guard let earliestItem = self.historyItems.min(by: { ($0.recordDate ?? .distantPast) < ($1.recordDate ?? .distantPast) }),
              let earliestDate = earliestItem.recordDate else { return }
        let minDate: Date = Calendar.current.startOfDay(for: earliestDate)
        
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
        
        if (minDataItem.Value - 250 > altitudeMinDefault) {
            self.altitudeGPSDataSetMin = minDataItem.Value - 50
        } else {
            if (minDataItem.Value < altitudeMinDefault) {
                self.altitudeGPSDataSetMin = minDataItem.Value
            }
        }

        if (maxDataItem.Value + 250 < altitudeMaxDefault) {
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
    
    private class func weekAggregateFetchRequest(_ nMaxCount: Int) -> NSFetchRequest<NSFetchRequestResult> {
        let keypathExpAltitudeBar = NSExpression(forKeyPath: "altitudeBAR")
        let expressionMaxAltitudeBAR = NSExpression(forFunction: "max:", arguments: [keypathExpAltitudeBar])
        
        let descMaxAltitudeBar = NSExpressionDescription()
        descMaxAltitudeBar.expression = expressionMaxAltitudeBAR
        descMaxAltitudeBar.name = "maxAltitudeBAR"
        descMaxAltitudeBar.expressionResultType = .doubleAttributeType

        let keypathExpPressure = NSExpression(forKeyPath: "pressure")
        let expressionMinPressure = NSExpression(forFunction: "min:", arguments: [keypathExpPressure])
        
        let descMinPressure = NSExpressionDescription()
        descMinPressure.expression = expressionMinPressure
        descMinPressure.name = "minPressure"
        descMinPressure.expressionResultType = .doubleAttributeType

        let keypathExpEverest = NSExpression(forKeyPath: "everest")
        let expressionMaxEverest = NSExpression(forFunction: "max:", arguments: [keypathExpEverest])
        
        let descMaxEverest = NSExpressionDescription()
        descMaxEverest.expression = expressionMaxEverest
        descMaxEverest.name = "maxEverest"
        descMaxEverest.expressionResultType = .doubleAttributeType

        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "HistoryItem")
        request.returnsObjectsAsFaults = false
        request.propertiesToGroupBy = ["day"]
        request.propertiesToFetch = ["day", descMaxAltitudeBar, descMinPressure, descMaxEverest]
        request.resultType = .dictionaryResultType
        request.fetchLimit = nMaxCount
        let sortDay = NSSortDescriptor(key: "day", ascending: false)
        request.sortDescriptors = [sortDay]
        request.predicate = NSPredicate(format: "pressure > 0")
        return request
    }

}
