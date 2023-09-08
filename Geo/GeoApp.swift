//
//  GeoApp.swift
//  Geo
//
//  Created by nettrash on 08/09/2023.
//

import SwiftUI

@main
struct GeoApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
