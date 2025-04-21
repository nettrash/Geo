//
//  History.swift
//  Geo
//
//  Created by nettrash on 06/09/2024.
//

import Foundation
import CoreData
import CoreLocation

@Observable
class History: NSObject, ObservableObject {
    
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

    var trackingAltitudeDataSet: [PairDataItem] = []
    var trackingAltitudeDataSetMin: CGFloat = 0
    var trackingAltitudeDataSetMax: CGFloat = 0

    private let amountOfValuesToShow: Int = 30
    let pressureDataSetMinDefault: CGFloat = 0
    let pressureDataSetMaxDefault: CGFloat = 1000
    let altitudeMinDefault: CGFloat = 0
    let altitudeMaxDefault: CGFloat = 10000
    
    private let numberOfDays: Int = 30

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
            fetchRequest.predicate = NSPredicate(
                format: "recordDate >= %@ and barometerPressure > 0", Calendar.current.date(byAdding: .day, value: -self.numberOfDays, to: Date())! as CVarArg
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
                NSLog("Error fetching HistoryItems")
            }
        }
        self.pressureDataSetRefresh()
        self.barometerDataSetRefresh()
        self.gpsDataSetRefresh()
    }
    
    func pressureDataSetRefresh() {
        self.pressureDataSet.removeAll()

        if self.historyItems.count < 1 {
            return
        }
        
        let minDate: Date = Calendar.current.startOfDay(for: self.historyItems.min(by: { $0.recordDate! < $1.recordDate! })!.recordDate!)
        
        for idx in 0..<amountOfValuesToShow {
            let currentDate: Date = Calendar.current.date(byAdding: Calendar.Component.day, value: idx, to: minDate)!
            let minPreassure: CGFloat = self.historyItems
                .filter { Calendar.current.startOfDay(for: $0.recordDate!) == currentDate }
                .min(by: { $0.barometerPressure < $1.barometerPressure })?.barometerPressure ?? 0
            self.pressureDataSet.append(DataItem(Value: minPreassure * 7.50062, Legend: dateFormatter.string(from:currentDate)))
        }

        while self.pressureDataSet.count < amountOfValuesToShow {
            self.pressureDataSet.append(DataItem(Value: 0, Legend: dateFormatter.string(from:Calendar.current.startOfDay(for: Date()))))
        }

        self.pressureDataSetMin = pressureDataSetMinDefault
        self.pressureDataSetMax = pressureDataSetMaxDefault
        
        let minDataItem = self.pressureDataSet.min(by: { $0.Value < $1.Value })
        let maxDataItem = self.pressureDataSet.max(by: { $0.Value < $1.Value })
        
        if (minDataItem!.Value - 50 > pressureDataSetMinDefault) {
            self.pressureDataSetMin = minDataItem!.Value - 50
        }

        if (maxDataItem!.Value + 50 < pressureDataSetMaxDefault) {
            self.pressureDataSetMax = maxDataItem!.Value + 50
        }
    }
    
    func barometerDataSetRefresh() {
        self.altitudeBarometerDataSet.removeAll()

        if self.historyItems.count < 1 {
            return
        }
        
        let minDate: Date = Calendar.current.startOfDay(for: self.historyItems.min(by: { $0.recordDate! < $1.recordDate! })!.recordDate!)
        
        for idx in 0..<amountOfValuesToShow {
            let currentDate: Date = Calendar.current.date(byAdding: Calendar.Component.day, value: idx, to: minDate)!
            let maxBarometerAltitude: CGFloat = self.historyItems
                .filter { Calendar.current.startOfDay(for: $0.recordDate!) == currentDate }
                .max(by: { $0.barometerAltitude < $1.barometerAltitude })?.barometerAltitude ?? 0
            self.altitudeBarometerDataSet.append(DataItem(Value: maxBarometerAltitude, Legend: dateFormatter.string(from:currentDate)))
        }

        while self.altitudeBarometerDataSet.count < amountOfValuesToShow {
            self.altitudeBarometerDataSet.append(DataItem(Value: 0, Legend: dateFormatter.string(from:Calendar.current.startOfDay(for: Date()))))
        }
        
        self.altitudeBarometerDataSetMin = altitudeMinDefault
        self.altitudeBarometerDataSetMax = altitudeMaxDefault
        
        let minDataItem = self.altitudeBarometerDataSet.min(by: { $0.Value < $1.Value })
        let maxDataItem = self.altitudeBarometerDataSet.max(by: { $0.Value < $1.Value })
        
        if (minDataItem!.Value - 250 > altitudeMinDefault) {
            self.altitudeBarometerDataSetMin = minDataItem!.Value - 50
        }

        if (maxDataItem!.Value + 250 < altitudeMaxDefault) {
            self.altitudeBarometerDataSetMax = maxDataItem!.Value + 50
        }
    }
    
    func gpsDataSetRefresh() {
        self.altitudeGPSDataSet.removeAll()

        if self.historyItems.count < 1 {
            return
        }
        
        let minDate: Date = Calendar.current.startOfDay(for: self.historyItems.min(by: { $0.recordDate! < $1.recordDate! })!.recordDate!)
        
        for idx in 0..<amountOfValuesToShow {
            let currentDate: Date = Calendar.current.date(byAdding: Calendar.Component.day, value: idx, to: minDate)!
            let maxGPSAltitude: CGFloat = self.historyItems
                .filter { Calendar.current.startOfDay(for: $0.recordDate!) == currentDate }
                .max(by: { $0.gpsAltitude < $1.gpsAltitude })?.gpsAltitude ?? 0
            self.altitudeGPSDataSet.append(DataItem(Value: maxGPSAltitude, Legend: dateFormatter.string(from:currentDate)))
        }

        while self.altitudeGPSDataSet.count < amountOfValuesToShow {
            self.altitudeGPSDataSet.append(DataItem(Value: 0, Legend: dateFormatter.string(from:Calendar.current.startOfDay(for: Date()))))
        }

        self.altitudeGPSDataSetMin = altitudeMinDefault
        self.altitudeGPSDataSetMax = altitudeMaxDefault
        
        let minDataItem = self.altitudeGPSDataSet.min(by: { $0.Value < $1.Value })
        let maxDataItem = self.altitudeGPSDataSet.max(by: { $0.Value < $1.Value })
        
        if (minDataItem!.Value - 250 > altitudeMinDefault) {
            self.altitudeGPSDataSetMin = minDataItem!.Value - 50
        }

        if (maxDataItem!.Value + 250 < altitudeMaxDefault) {
            self.altitudeGPSDataSetMax = maxDataItem!.Value + 50
        }
    }
    
    func addTrackingInformation(_ location: CLLocation, _ barometer: Barometer) {
        
        let dataItem = PairDataItem(Value0: barometer.height, Value1: location.altitude, Legend: trackingDateFormatter.string(from:Date()))
        self.trackingAltitudeDataSet.append(dataItem)
        
        while self.trackingAltitudeDataSet.count > amountOfValuesToShow {
            self.trackingAltitudeDataSet.removeFirst()
        }
        
        self.trackingAltitudeDataSetMin = altitudeMinDefault
        self.trackingAltitudeDataSetMax = altitudeMaxDefault
        
        let minDataItem = trackingAltitudeDataSet.min(by: { $0.Value0 < $1.Value0 })
        let maxDataItem = trackingAltitudeDataSet.max(by: { $0.Value0 < $1.Value0 })
        
        if (minDataItem!.Value0 - 250 > altitudeMinDefault) {
            self.trackingAltitudeDataSetMin = minDataItem!.Value0 - 50
        }

        if (maxDataItem!.Value0 + 250 < altitudeMaxDefault) {
            self.trackingAltitudeDataSetMax = maxDataItem!.Value0 + 50
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
