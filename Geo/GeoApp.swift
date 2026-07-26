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
                    case .background, .inactive:
                        // Pause the high-rate sensors whenever the UI is
                        // not visible. The low-power background path
                        // (BGTaskScheduler) captures its own transient
                        // barometer sample, so the foreground streams are
                        // redundant while suspended/inactive.
                        self.appDelegate.barometer?.Stop()
                        self.appDelegate.location?.stopLocationMonitor()
                        if phase == .background {
                            self.appDelegate.applicationWillResignActive(UIApplication.shared)
                        }
                    case .active:
                        // Resume the high-rate sensors now the UI is
                        // visible again.
                        self.appDelegate.barometer?.Start()
                        self.appDelegate.location?.startLocationMonitor()
                        // Pull anything Widget recorded while we were in
                        // the background (barometer + last GPS) before we
                        // overwrite the shared snapshot with our own state.
                        self.appDelegate.restoreFromSharedStorage()
                        self.appDelegate.pushDataToWidget()
                        // Top up the planetary Kp index if what we hold is
                        // older than one 3-hour bin. Foreground only, and
                        // a no-op inside that window, so returning to the
                        // app repeatedly costs nothing.
                        Task { await self.appDelegate.spaceWeather?.refreshIfStale() }
                    @unknown default: break
                    }
                }
        }
    }
}
