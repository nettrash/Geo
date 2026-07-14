//
//  ARCameraView.swift
//  Geo
//
//  Created by nettrash on 24/03/2026.
//

import SwiftUI
import ARKit
import CoreLocation
import os

/// UIViewRepresentable wrapper for ARSCNView to show the camera feed.
///
/// The session is deliberately minimal: world tracking with `.gravityAndHeading`
/// alignment, and nothing else. It exists purely to give us (a) a camera image
/// and (b) a gravity- and north-aligned camera transform to project peaks and
/// the horizon line through. There is no scene reconstruction, no plane
/// detection and no depth — the Nature tab identifies mountains kilometres away,
/// so scanning the room around you bought nothing but battery drain.
struct ARCameraView: UIViewRepresentable {

    /// Shared session manager — publishes camera matrices every frame for overlay projection
    var sessionManager: ARSessionManager?

    /// When `false`, the AR session is paused. SwiftUI keeps tab views
    /// alive even when they're not visible, so the parent toggles this
    /// off as soon as the Nature tab disappears (or the app goes into
    /// the background) to stop draining battery on the camera/IMU.
    var isActive: Bool = true

    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView()
        arView.session.delegate = context.coordinator
        arView.autoenablesDefaultLighting = true
        arView.automaticallyUpdatesLighting = true

        if isActive {
            arView.session.run(Self.makeConfig())
            context.coordinator.isRunning = true
        }

        // Store the ARSCNView in the coordinator so we can read its bounds
        context.coordinator.arView = arView

        return arView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.sessionManager = sessionManager

        // Resume / pause to match the parent's intent. ARKit handles
        // these calls cheaply when the state already matches.
        if isActive, !context.coordinator.isRunning {
            uiView.session.run(Self.makeConfig())
            context.coordinator.isRunning = true
            AppLog.ar.debug("AR session resumed")
        } else if !isActive, context.coordinator.isRunning {
            uiView.session.pause()
            context.coordinator.isRunning = false
            AppLog.ar.debug("AR session paused")
        }
    }

    /// Centralised session configuration so `makeUIView` and `updateUIView`
    /// stay in sync. `.gravityAndHeading` is the only thing we actually need:
    /// it aligns ARKit's world axes to +X = East, +Y = Up, −Z = North, which is
    /// what every overlay projection assumes.
    private static func makeConfig() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravityAndHeading
        return config
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(sessionManager: sessionManager)
    }

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    @MainActor
    class Coordinator: NSObject, ARSessionDelegate {
        var sessionManager: ARSessionManager?
        weak var arView: ARSCNView?
        /// Tracks whether `session.run(...)` has been called more
        /// recently than `session.pause()`. Lets `updateUIView` make
        /// idempotent state-change decisions without querying ARKit.
        var isRunning: Bool = false
        /// Coalesces the per-frame overlay update so at most ONE `ARFrame` is
        /// ever retained at a time. `session(_:didUpdate:)` fires on ARKit's
        /// queue; capturing each frame into a `@MainActor` Task would, under
        /// main-thread contention, queue up several frames — and Apple warns
        /// that holding ARFrames pins pixel buffers from a small pool and can
        /// stall capture. While an update is still draining, newer frames are
        /// skipped (the overlay just refreshes a frame later). Sendable +
        /// `let`, so the nonisolated delegate can touch it.
        nonisolated let framePending = OSAllocatedUnfairLock(initialState: false)

        init(sessionManager: ARSessionManager?) {
            self.sessionManager = sessionManager
        }

        // MARK: - ARSessionDelegate

        nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
            // Skip this frame's overlay update if the previous one is still
            // draining on the main actor — otherwise we'd capture (retain)
            // another ARFrame behind it. Bounds in-flight frames to one.
            let alreadyPending = framePending.withLock { pending -> Bool in
                if pending { return true }
                pending = true
                return false
            }
            if alreadyPending { return }

            Task { @MainActor [weak self, framePending] in
                defer { framePending.withLock { $0 = false } }

                // Feed session manager with camera matrices for overlay projection
                if let arView = self?.arView {
                    let viewportSize = arView.bounds.size
                    let windowScene = UIApplication.shared.connectedScenes
                        .compactMap { $0 as? UIWindowScene }
                        .first
                    let orientation: UIInterfaceOrientation
                    if #available(iOS 26.0, *) {
                        orientation = windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
                    } else {
                        orientation = windowScene?.interfaceOrientation ?? .portrait
                    }
                    self?.sessionManager?.update(
                        from: frame,
                        viewportSize: viewportSize,
                        orientation: orientation
                    )
                }
            }
        }
    }
}
