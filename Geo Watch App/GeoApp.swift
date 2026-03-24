//
//  GeoApp.swift
//  Geo Watch App
//
//  Created by Ivan Alekseev on 24/01/2025.
//

import SwiftUI
import CoreMotion

@main
struct Geo_Watch_AppApp: App {
    @WKApplicationDelegateAdaptor var appDelegate: GeoWatchAppDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView(appDelegate: appDelegate)
        }
    }
}
