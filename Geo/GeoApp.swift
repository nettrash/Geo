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
    @Environment(\.scenePhase) private var phase
    
    var body: some Scene {
        WindowGroup {
            MainView(app: appDelegate)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .preferredColorScheme(.dark)
                .onChange(of: phase) {
                    switch phase {
                        case .background:
                            self.appDelegate.applicationWillResignActive(UIApplication.shared)
                        case .active:
                            // Pull anything Widget recorded while we were in
                            // the background (barometer + last GPS) before we
                            // overwrite the shared snapshot with our own state.
                            self.appDelegate.restoreFromSharedStorage()
                            self.appDelegate.pushDataToWidget()
                        default: break
                    }
                }
        }
    }
}
