//
//  MainView.swift
//  Geo
//
//  Created by nettrash on 08/09/2023.
//

import SwiftUI
import CoreData

struct MainView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.scenePhase) private var scenePhase
    @State var app: GeoAppDelegate?

    /// Single source of truth for "the user denied a permission we
    /// need". `MainView` polls this on appear and on scene-active so
    /// the user gets a banner that disappears as soon as they fix
    /// the issue in Settings.
    @StateObject private var permissions = PermissionsMonitor()

    var body: some View {
        VStack(spacing: 0) {
            PermissionsBanner(monitor: permissions)
            TabView {
                GeoInfoView(app: app)
                    .tabItem {
                        Image(systemName: "ruler")
                        Text("Info")
                    }
                GeoStatView(app: app)
                    .tabItem {
                        Image(systemName: "chart.xyaxis.line")
                        Text("Stat")
                    }
                GeoMapView(app: app)
                    .tabItem {
                        Image(systemName: "map")
                        Text("Map")
                    }
                GeoNatureView(app: app)
                    .tabItem {
                        Image(systemName: "mountain.2")
                        Text("Nature")
                    }
            }
        }
        .onAppear { permissions.refresh() }
        .onChange(of: scenePhase) { _, newPhase in
            // Re-check whenever the user comes back from Settings —
            // toggling a permission off / on takes effect immediately.
            if newPhase == .active { permissions.refresh() }
        }
    }
}

struct MainView_Previews: PreviewProvider {
    static var previews: some View {
        MainView(app: GeoAppDelegate()).environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
