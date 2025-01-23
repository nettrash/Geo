//
//  History.swift
//  Geo
//
//  Created by nettrash on 06/09/2024.
//

import Foundation
import CoreData

@Observable
class History: NSObject, ObservableObject {
    
    var historyItems: [HistoryItem] = []
    
    var pressureDataSet: [DataItem] = []
    var pressureDataSetMin: Double = 0
    var pressureDataSetMax: Double = 0

    var altitudeBarometerDataSet: [DataItem] = []
    var altitudeBarometerDataSetMin: Double = 0
    var altitudeBarometerDataSetMax: Double = 0

    var altitudeGPSDataSet: [DataItem] = []
    var altitudeGPSDataSetMin: Double = 0
    var altitudeGPSDataSetMax: Double = 0
    
    private let amountOfValuesToShow: Int = 30
    let pressureDataSetMinDefault: Double = 0
    let pressureDataSetMaxDefault: Double = 1000
    let altitudeMinDefault: Double = 0
    let altitudeMaxDefault: Double = 10000
    
    private let numberOfDays: Int = 30

    private let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter
        }()

    func Refresh() {
        do {
            let controller = PersistenceController.shared
            let fetchRequest: NSFetchRequest<HistoryItem> = HistoryItem.fetchRequest()
            fetchRequest.predicate = NSPredicate(
                format: "recordDate >= %@", Calendar.current.date(byAdding: .day, value: -self.numberOfDays, to: Date())! as CVarArg
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
        pressureDataSet.removeAll()

        if self.historyItems.count < 1 {
            return
        }
        
        let minDate: Date = Calendar.current.startOfDay(for: self.historyItems.min(by: { $0.recordDate! < $1.recordDate! })!.recordDate!)
        
        for idx in 0..<amountOfValuesToShow {
            let currentDate: Date = Calendar.current.date(byAdding: Calendar.Component.day, value: idx, to: minDate)!
            let minPreassure: CGFloat = self.historyItems
                .filter { Calendar.current.startOfDay(for: $0.recordDate!) == currentDate }
                .min(by: { $0.barometerPressure < $1.barometerPressure })?.barometerPressure ?? 0
            pressureDataSet.append(DataItem(Value: minPreassure * 7.50062, Legend: dateFormatter.string(from:currentDate)))
        }

        while pressureDataSet.count < amountOfValuesToShow {
            pressureDataSet.append(DataItem(Value: 0, Legend: dateFormatter.string(from:Calendar.current.startOfDay(for: Date()))))
        }

        self.pressureDataSetMin = pressureDataSetMinDefault
        self.pressureDataSetMax = pressureDataSetMaxDefault
        
        let minDataItem = pressureDataSet.min(by: { $0.Value < $1.Value })
        let maxDataItem = pressureDataSet.max(by: { $0.Value < $1.Value })
        
        if (minDataItem!.Value - 50 > pressureDataSetMinDefault) {
            self.pressureDataSetMin = minDataItem!.Value - 50
        }

        if (maxDataItem!.Value + 50 < pressureDataSetMaxDefault) {
            self.pressureDataSetMax = maxDataItem!.Value + 50
        }
    }
    
    func barometerDataSetRefresh() {
        altitudeBarometerDataSet.removeAll()

        if self.historyItems.count < 1 {
            return
        }
        
        let minDate: Date = Calendar.current.startOfDay(for: self.historyItems.min(by: { $0.recordDate! < $1.recordDate! })!.recordDate!)
        
        for idx in 0..<amountOfValuesToShow {
            let currentDate: Date = Calendar.current.date(byAdding: Calendar.Component.day, value: idx, to: minDate)!
            let maxBarometerAltitude: CGFloat = self.historyItems
                .filter { Calendar.current.startOfDay(for: $0.recordDate!) == currentDate }
                .max(by: { $0.barometerAltitude < $1.barometerAltitude })?.barometerAltitude ?? 0
            altitudeBarometerDataSet.append(DataItem(Value: maxBarometerAltitude, Legend: dateFormatter.string(from:currentDate)))
        }

        while altitudeBarometerDataSet.count < amountOfValuesToShow {
            altitudeBarometerDataSet.append(DataItem(Value: 0, Legend: dateFormatter.string(from:Calendar.current.startOfDay(for: Date()))))
        }
        
        self.altitudeBarometerDataSetMin = altitudeMinDefault
        self.altitudeBarometerDataSetMax = altitudeMaxDefault
        
        let minDataItem = altitudeBarometerDataSet.min(by: { $0.Value < $1.Value })
        let maxDataItem = altitudeBarometerDataSet.max(by: { $0.Value < $1.Value })
        
        if (minDataItem!.Value - 250 > altitudeMinDefault) {
            self.altitudeBarometerDataSetMin = minDataItem!.Value - 50
        }

        if (maxDataItem!.Value + 250 < altitudeMaxDefault) {
            self.altitudeBarometerDataSetMax = maxDataItem!.Value + 50
        }
    }
    
    func gpsDataSetRefresh() {
        altitudeGPSDataSet.removeAll()

        if self.historyItems.count < 1 {
            return
        }
        
        let minDate: Date = Calendar.current.startOfDay(for: self.historyItems.min(by: { $0.recordDate! < $1.recordDate! })!.recordDate!)
        
        for idx in 0..<amountOfValuesToShow {
            let currentDate: Date = Calendar.current.date(byAdding: Calendar.Component.day, value: idx, to: minDate)!
            let maxGPSAltitude: CGFloat = self.historyItems
                .filter { Calendar.current.startOfDay(for: $0.recordDate!) == currentDate }
                .max(by: { $0.gpsAltitude < $1.gpsAltitude })?.gpsAltitude ?? 0
            altitudeGPSDataSet.append(DataItem(Value: maxGPSAltitude, Legend: dateFormatter.string(from:currentDate)))
        }

        while altitudeGPSDataSet.count < amountOfValuesToShow {
            altitudeGPSDataSet.append(DataItem(Value: 0, Legend: dateFormatter.string(from:Calendar.current.startOfDay(for: Date()))))
        }

        self.altitudeGPSDataSetMin = altitudeMinDefault
        self.altitudeGPSDataSetMax = altitudeMaxDefault
        
        let minDataItem = altitudeGPSDataSet.min(by: { $0.Value < $1.Value })
        let maxDataItem = altitudeGPSDataSet.max(by: { $0.Value < $1.Value })
        
        if (minDataItem!.Value - 250 > altitudeMinDefault) {
            self.altitudeGPSDataSetMin = minDataItem!.Value - 50
        }

        if (maxDataItem!.Value + 250 < altitudeMaxDefault) {
            self.altitudeGPSDataSetMax = maxDataItem!.Value + 50
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
