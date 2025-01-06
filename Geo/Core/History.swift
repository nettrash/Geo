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
    
    private let amountOfValuesToShow: Int = 25
    let pressureDataSetMinDefault: Double = 0
    let pressureDataSetMaxDefault: Double = 1000
    let altitudeMinDefault: Double = 0
    let altitudeMaxDefault: Double = 10000

    private let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter
        }()

    @MainActor func Refresh() {
        do {
            let controller = PersistenceController.shared
            let fetchRequest: NSFetchRequest<HistoryItem> = HistoryItem.fetchRequest()
            fetchRequest.predicate = NSPredicate(
                format: "recordDate >= %@", Calendar.current.date(byAdding: .day, value: -7, to: Date())! as CVarArg
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
    
    @MainActor func pressureDataSetRefresh() {
        pressureDataSet.removeAll()
        
        for historyItem in self.historyItems.suffix(amountOfValuesToShow) {
            pressureDataSet.append(DataItem(Value: historyItem.barometerPressure * 7.50062, Legend: dateFormatter.string(from: historyItem.recordDate ?? Date())))
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
    
    @MainActor func barometerDataSetRefresh() {
        altitudeBarometerDataSet.removeAll()
        
        for historyItem in self.historyItems.suffix(amountOfValuesToShow) {
            altitudeBarometerDataSet.append(DataItem(Value: historyItem.barometerAltitude, Legend: dateFormatter.string(from: historyItem.recordDate ?? Date())))
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
    
    @MainActor func gpsDataSetRefresh() {
        altitudeGPSDataSet.removeAll()
        
        for historyItem in self.historyItems.suffix(amountOfValuesToShow) {
            altitudeGPSDataSet.append(DataItem(Value: historyItem.gpsAltitude, Legend: dateFormatter.string(from: historyItem.recordDate ?? Date())))
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

}
