//
//  PhoneConnectivityManager.swift
//  Geo
//
//  iPhone-side WatchConnectivity wrapper. Listens for barometer
//  samples streamed from the Watch and forwards them into the shared
//  data path: rehydrate the in-memory barometer, persist a CoreData
//  history item, and refresh widgets.
//
//  Deliberately not `@MainActor`-isolated: WCSession delegate
//  callbacks fire on a background queue, and the rest of the codebase
//  (GeoAppDelegate / Location / Barometer) is plain non-isolated NS
//  classes that already assume main-thread access by convention. We
//  hop to the main queue with GCD before touching any of that state.
//

import Foundation
import CoreData
import WatchConnectivity
import WidgetKit

/// `@unchecked Sendable` — the only mutable state is a `weak`
/// reference (atomic at runtime) and a `let` `WCSession?` that is
/// itself thread-safe. Marking the class explicitly Sendable lets us
/// hand `self` to `DispatchQueue.main.async` / `Task { @MainActor in … }`
/// without strict-concurrency data-race diagnostics firing.
final class PhoneConnectivityManager: NSObject, @unchecked Sendable {

    /// Pointer back to the app delegate so we can route inbound
    /// samples through the existing barometer / history pipelines.
    weak var app: GeoAppDelegate?

    private let session: WCSession?

    override init() {
        if WCSession.isSupported() {
            self.session = WCSession.default
        } else {
            self.session = nil
        }
        super.init()
        self.session?.delegate = self
        self.session?.activate()
    }

    // MARK: - Outbound

    /// Push the latest combined snapshot to the Watch. Best-effort —
    /// fire-and-forget; the Watch already runs its own barometer and
    /// uses our values mostly for GPS context.
    func sendCurrentSnapshot(_ token: InformationToken) {
        guard let session, session.activationState == .activated, session.isReachable else {
            return
        }
        do {
            let data = try JSONEncoder().encode(token)
            session.sendMessageData(data, replyHandler: nil) { error in
                AppLog.connectivity.error("Failed to send snapshot to Watch: \(String(describing: error))")
            }
        } catch {
            AppLog.connectivity.error("Failed to encode outbound snapshot: \(String(describing: error))")
        }
    }
}

extension PhoneConnectivityManager: WCSessionDelegate {

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if let error {
            AppLog.connectivity.error("WCSession activation failed: \(String(describing: error))")
        } else {
            AppLog.connectivity.debug("WCSession activated, state=\(activationState.rawValue, privacy: .public)")
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        AppLog.connectivity.debug("WCSession became inactive")
    }

    func sessionDidDeactivate(_ session: WCSession) {
        AppLog.connectivity.debug("WCSession deactivated, reactivating")
        WCSession.default.activate()
    }

    /// Inbound watch samples — handed off to the main actor.
    /// `GeoAppDelegate` conforms to `UIApplicationDelegate` (which is
    /// `@MainActor`-isolated under Swift 6), so its `barometer` and
    /// `history` properties are themselves main-actor-isolated. Use a
    /// `Task { @MainActor in … }` rather than `DispatchQueue.main.async`
    /// so the compiler sees the closure body as running on the main
    /// actor.
    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        guard let token = try? JSONDecoder().decode(InformationToken.self, from: messageData) else {
            AppLog.connectivity.error("Received undecodable Watch message")
            return
        }
        Task { @MainActor [weak self] in
            self?.handleInbound(token)
        }
    }

    func session(_ session: WCSession,
                 didReceiveApplicationContext applicationContext: [String : Any]) {
        guard let data = applicationContext["snapshot"] as? Data,
              let token = try? JSONDecoder().decode(InformationToken.self, from: data) else {
            return
        }
        Task { @MainActor [weak self] in
            self?.handleInbound(token)
        }
    }

    // MARK: - Main-actor handling

    @MainActor
    private func handleInbound(_ token: InformationToken) {
        guard let app else { return }

        // 1. Rehydrate barometer if our local sensor hasn't produced a
        //    sample yet (Watch readings are usually fresher when the
        //    iPhone has been sitting in a pocket).
        if let bar = app.barometer, bar.pressure == 0, token.barPreassure > 0 {
            bar.pressure = token.barPreassure
            bar.height = token.barAltitude
            bar.everest = token.barAltitude / 8848
        }

        // 2. Persist the inbound sample as a history item if it doesn't
        //    duplicate one we already have at that timestamp.
        guard token.barPreassure > 0 else { return }
        let context = PersistenceController.shared.container.viewContext
        let request: NSFetchRequest<HistoryItem> = HistoryItem.fetchRequest()
        request.predicate = NSPredicate(format: "recordDate == %@", token.recordDate as NSDate)
        request.fetchLimit = 1
        if let count = try? context.count(for: request), count > 0 { return }

        let item = HistoryItem(context: context)
        item.recordDate = token.recordDate
        item.barometerPressure = token.barPreassure
        item.barometerAltitude = token.barAltitude
        item.gpsAltitude = token.gpsAltitude
        item.gpsVelocity = token.gpsSpeed
        item.gpsLatitude = token.gpsLatitude
        item.gpsLongitude = token.gpsLongitude
        do {
            try context.save()
            // Just mark the cache stale; UI will re-fetch on next view
            // appearance. Avoids piling Refresh()-triggered fetches
            // onto the main thread under WAL pressure.
            app.history.markDirty()
            WidgetCenter.shared.reloadTimelines(ofKind: "GEO")
        } catch {
            context.rollback()
            AppLog.connectivity.error("Failed to persist Watch sample: \(String(describing: error))")
        }
    }
}
