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

    /// Summit-log proximity prompt: the peak currently offered for logging,
    /// and the last peak the user dismissed/logged so we don't re-nag while
    /// they linger on the summit.
    @State private var summitToLog: MountainInfo?
    /// The set captured WITH the peak when the prompt opens, so a later location
    /// update can't relabel the collection of the peak being shown.
    @State private var summitToLogSet: String = "highest"
    @State private var dismissedSummitID: String?

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
        .onAppear {
            permissions.refresh()
            evaluateSummitPrompt()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Re-check whenever the user comes back from Settings —
            // toggling a permission off / on takes effect immediately.
            if newPhase == .active { permissions.refresh() }
        }
        // Fires whenever the nearby-peak candidate changes (a new arrival, or
        // walking out of range), driven by Location's @Observable property.
        .onChange(of: app?.location?.nearbySummitCandidate?.id) { _, _ in
            evaluateSummitPrompt()
        }
        .sheet(item: $summitToLog) { peak in
            SummitLogSheet(
                app: app,
                peak: peak,
                set: summitToLogSet,           // captured with the peak, not re-read live
                onClose: { summitToLog = nil }
            )
            // Mark the peak handled on ANY dismissal (buttons AND swipe-down), so
            // it isn't re-prompted while the user lingers — but ONLY if still in
            // range. If they already walked away (candidate cleared) and then
            // closed a stale sheet, leave the walk-away reset intact so a genuine
            // re-approach can prompt again.
            .onDisappear {
                if app?.location?.nearbySummitCandidate?.id == peak.id {
                    dismissedSummitID = peak.id
                }
            }
        }
    }

    /// Decide whether to present the "log this ascent?" prompt for the current
    /// nearby peak. Suppresses re-prompting for a peak the user just dismissed
    /// or already logged; resets once they walk out of range.
    private func evaluateSummitPrompt() {
        guard let candidate = app?.location?.nearbySummitCandidate else {
            dismissedSummitID = nil   // out of range → a fresh re-approach may prompt
            return
        }
        guard summitToLog == nil,
              candidate.id != dismissedSummitID,
              app?.summitLog?.wasRecentlyLogged(candidate) != true else { return }
        summitToLogSet = app?.location?.nearbySummitSet ?? "highest"
        summitToLog = candidate
    }
}

struct MainView_Previews: PreviewProvider {
    static var previews: some View {
        MainView(app: GeoAppDelegate()).environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
