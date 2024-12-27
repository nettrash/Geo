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
    
    func Refresh() {
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
    }
}
