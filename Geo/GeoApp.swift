//
//  GeoApp.swift
//  Geo
//
//  Created by nettrash on 08/09/2023.
//

import SwiftUI

@main
struct GeoApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: GeoAppDelegate
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            MainView(app: appDelegate)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .preferredColorScheme(.dark)
        }
    }
}
