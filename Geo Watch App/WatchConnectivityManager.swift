//
//  WatchConnectivityManager.swift
//  Geo Watch App
//
//  Watch-side WatchConnectivity. Streams barometer samples to the
//  iPhone (live message when reachable, applicationContext otherwise)
//  and accepts inbound iPhone snapshots so the Watch UI can show GPS
//  context (altitude, speed) alongside its own barometer reading.
//
//  Deliberately not `@MainActor`-isolated — see notes on the iPhone-
//  side `PhoneConnectivityManager`. WCSession callbacks land on a
//  background queue; we hop to the main queue with GCD before
//  touching `GeoWatchAppDelegate` state.
//

import Foundation
import WatchConnectivity

/// `@unchecked Sendable` — the only mutable state is a `weak` reference
/// (atomic at the runtime level) and a `let` `WCSession?` that is itself
/// thread-safe. Marking the class explicitly Sendable lets us hand
/// `self` to a `Task { @MainActor in … }` without the compiler tripping
/// strict-concurrency data-race diagnostics.
final class WatchConnectivityManager: NSObject, @unchecked Sendable {

    /// Set by the watch app delegate; lets us write inbound iPhone
    /// snapshots into the existing in-memory state.
    weak var appDelegate: GeoWatchAppDelegate?

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

    /// Push the current barometer + GPS snapshot to the iPhone. We
    /// prefer a live message when the iPhone is reachable; fall back
    /// to `updateApplicationContext` so the iPhone wakes up with the
    /// data on next launch.
    func sendCurrentSnapshot(_ token: InformationToken) {
        guard let session, session.activationState == .activated else { return }
        guard let data = try? JSONEncoder().encode(token) else { return }

        if session.isReachable {
            session.sendMessageData(data, replyHandler: nil) { _ in
                // Best-effort; fall through to the context update below.
            }
        }
        do {
            try session.updateApplicationContext(["snapshot": data])
        } catch {
            // Non-fatal — the iPhone will pick up the next snapshot.
        }
    }
}

extension WatchConnectivityManager: WCSessionDelegate {

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        // Activation state is inferred via `session.activationState`.
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        guard let token = try? JSONDecoder().decode(InformationToken.self, from: messageData) else { return }
        // GeoWatchAppDelegate is `@MainActor`, so dispatch the
        // delivery via a main-actor `Task`.
        Task { @MainActor [weak self] in
            self?.appDelegate?.applyInbound(token)
        }
    }

    func session(_ session: WCSession,
                 didReceiveApplicationContext applicationContext: [String : Any]) {
        guard let data = applicationContext["snapshot"] as? Data,
              let token = try? JSONDecoder().decode(InformationToken.self, from: data) else {
            return
        }
        Task { @MainActor [weak self] in
            self?.appDelegate?.applyInbound(token)
        }
    }
}
