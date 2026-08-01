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

    /// Two-tier throttle for the inbound watch->history path. The Watch
    /// streams a fresh snapshot (with a new `Date()`) on every ~1 Hz
    /// barometer tick, so the exact-`recordDate` dedup below never
    /// collides and history would grow ~3600 rows/hour while the app is
    /// foregrounded. Mirror Android's `WearInboundListener`: skip the
    /// insert when pressure has barely moved *and* too little time has
    /// passed since the last persisted sample. Both fields are only
    /// touched from `handleInbound`, which is `@MainActor`-isolated.
    private var lastPersistedPressure: Double?
    private var lastPersistedDate: Date?

    /// Skip inserts when pressure hasn't moved at least this much (kPa).
    private static let pressureDeltaKPa: Double = 0.1
    /// Hard minimum spacing between inserts, regardless of pressure delta.
    private static let minInterval: TimeInterval = 30

    /// Outbound mirror of the inbound throttle above. `pushCombinedDataToWidget`
    /// fires from BOTH hot paths — `didUpdateLocations` (~1 Hz) and
    /// `onBarometerUpdated` (~1 Hz) — so an unthrottled send woke the Bluetooth
    /// radio ~2x/second for the whole foreground session.
    ///
    /// Suppressing those sends is behaviour-neutral because nothing on the Watch
    /// renders this token live: `GeoWatchAppDelegate.applyInbound` only stores the
    /// GPS context (never displayed — it is re-emitted into the Watch complication
    /// snapshot) and refreshes the barometric calibration reference, which tracks
    /// weather on a minutes-to-hours scale. The Watch's live altitude comes from
    /// its own altimeter. Keeping the pressure-delta tier means a real climb still
    /// pushes a fresh calibration reference immediately.
    private var lastSentPressure: Double?
    private var lastSentDate: Date?

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
    ///
    /// Throttled on the same two tiers as the inbound path (significant
    /// pressure move OR `minInterval` elapsed). Pass `force: true` at
    /// scene transitions so the Watch always receives the freshest sample
    /// before we stop sampling — mirrors `reloadWidgetIfNeeded`'s
    /// `lastWidgetReloadDate = .distantPast` bypass and Android's
    /// `WidgetUpdater.pushImmediate()`.
    ///
    /// `@MainActor` because both call sites (`Location.pushCombinedDataToWidget`
    /// and `GeoAppDelegate.pushDataToWidget`) are already main-actor isolated;
    /// the annotation is what keeps the throttle state race-free.
    @MainActor
    func sendCurrentSnapshot(_ token: InformationToken, force: Bool = false) {
        guard let session, session.activationState == .activated, session.isReachable else {
            return
        }
        if !force,
           let lastPressure = lastSentPressure,
           let lastDate = lastSentDate {
            let deltaPressure = abs(token.barPreassure - lastPressure)
            let deltaTime = token.recordDate.timeIntervalSince(lastDate)
            if deltaPressure < Self.pressureDeltaKPa && deltaTime < Self.minInterval {
                return
            }
        }
        do {
            let data = try JSONEncoder().encode(token)
            session.sendMessageData(data, replyHandler: nil) { error in
                AppLog.connectivity.error("Failed to send snapshot to Watch: \(String(describing: error))")
            }
            lastSentPressure = token.barPreassure
            lastSentDate = token.recordDate
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
            bar.everest = token.barAltitude / Atmosphere.everestHeightM
        }

        // 2. Persist the inbound sample as a history item if it doesn't
        //    duplicate one we already have at that timestamp.
        guard token.barPreassure > 0 else { return }

        // 2a. Two-tier throttle (mirrors Android's WearInboundListener):
        //     the Watch sends ~1 Hz, each with a fresh recordDate, so the
        //     exact-timestamp dedup below never collides. Skip the insert
        //     when pressure has barely moved AND too little time has
        //     passed since the last persisted sample.
        if let lastPressure = lastPersistedPressure, let lastDate = lastPersistedDate {
            let deltaPressure = abs(token.barPreassure - lastPressure)
            let deltaTime = token.recordDate.timeIntervalSince(lastDate)
            if deltaPressure < Self.pressureDeltaKPa && deltaTime < Self.minInterval {
                return
            }
        }

        let context = PersistenceController.shared.container.viewContext
        let request: NSFetchRequest<HistoryItem> = HistoryItem.fetchRequest()
        // Widen the dedup from exact equality to a small time window so a
        // redelivered (e.g. application-context) sample near the same
        // instant doesn't create a second near-identical row.
        let windowStart = token.recordDate.addingTimeInterval(-1) as NSDate
        let windowEnd = token.recordDate.addingTimeInterval(1) as NSDate
        request.predicate = NSPredicate(format: "recordDate >= %@ AND recordDate <= %@",
                                        windowStart, windowEnd)
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
            // Record what we just persisted so the throttle above can
            // compare the next inbound sample against it.
            lastPersistedPressure = token.barPreassure
            lastPersistedDate = token.recordDate
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
