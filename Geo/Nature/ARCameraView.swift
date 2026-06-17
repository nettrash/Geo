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
/// When a LiDAR sensor is available, enables scene reconstruction so the
/// `AROcclusionManager` can hide markers behind real-world surfaces (walls, etc.).
struct ARCameraView: UIViewRepresentable {

    /// Shared occlusion manager — receives mesh anchors from the AR session
    var occlusionManager: AROcclusionManager?

    /// Shared session manager — publishes camera matrices every frame for overlay projection
    var sessionManager: ARSessionManager?

    /// When `false`, the AR session is paused. SwiftUI keeps tab views
    /// alive even when they're not visible, so the parent toggles this
    /// off as soon as the Nature tab disappears (or the app goes into
    /// the background) to stop draining battery on the camera/IMU/LiDAR.
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
        // Expose it to the session manager for the freeze-frame snapshot.
        sessionManager?.sceneView = arView

        return arView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.occlusionManager = occlusionManager
        context.coordinator.sessionManager = sessionManager
        sessionManager?.sceneView = uiView

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
    /// stay in sync.
    private static func makeConfig() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravityAndHeading
        // Detect BOTH plane alignments: the occlusion manager hides markers
        // behind detected vertical planes (walls) indoors and uses horizontal
        // planes for floor/ceiling distance. Horizontal-only left the
        // vertical-plane occlusion path permanently unreachable.
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        // Request scene depth so the LiDAR centre-depth readout and the
        // depth-based wall distance actually populate — ARKit only delivers
        // ARFrame.sceneDepth / smoothedSceneDepth when the matching frame
        // semantic is requested. Gated on device support; non-LiDAR devices
        // skip it and fall back to the raycast distance.
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        return config
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(occlusionManager: occlusionManager, sessionManager: sessionManager)
    }
    
    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
    }
    
    @MainActor
    class Coordinator: NSObject, ARSessionDelegate {
        var occlusionManager: AROcclusionManager?
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
        
        init(occlusionManager: AROcclusionManager?, sessionManager: ARSessionManager?) {
            self.occlusionManager = occlusionManager
            self.sessionManager = sessionManager
        }
        
        // MARK: - ARSessionDelegate
        
        nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            let meshAnchors = anchors.compactMap { $0 as? ARMeshAnchor }
            let planeAnchors = anchors.compactMap { $0 as? ARPlaneAnchor }
            guard !meshAnchors.isEmpty || !planeAnchors.isEmpty else { return }
            let allAnchors = session.currentFrame?.anchors ?? []
            let allMesh = allAnchors.compactMap { $0 as? ARMeshAnchor }
            let allPlanes = allAnchors.compactMap { $0 as? ARPlaneAnchor }
            Task { @MainActor [weak self] in
                if !meshAnchors.isEmpty { self?.occlusionManager?.updateMeshAnchors(allMesh) }
                if !planeAnchors.isEmpty { self?.occlusionManager?.updatePlaneAnchors(allPlanes) }
            }
        }
        
        nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            let meshAnchors = anchors.compactMap { $0 as? ARMeshAnchor }
            let planeAnchors = anchors.compactMap { $0 as? ARPlaneAnchor }
            guard !meshAnchors.isEmpty || !planeAnchors.isEmpty else { return }
            let allAnchors = session.currentFrame?.anchors ?? []
            let allMesh = allAnchors.compactMap { $0 as? ARMeshAnchor }
            let allPlanes = allAnchors.compactMap { $0 as? ARPlaneAnchor }
            Task { @MainActor [weak self] in
                if !meshAnchors.isEmpty { self?.occlusionManager?.updateMeshAnchors(allMesh) }
                if !planeAnchors.isEmpty { self?.occlusionManager?.updatePlaneAnchors(allPlanes) }
            }
        }
        
        nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
            let meshAnchors = anchors.compactMap { $0 as? ARMeshAnchor }
            let planeAnchors = anchors.compactMap { $0 as? ARPlaneAnchor }
            guard !meshAnchors.isEmpty || !planeAnchors.isEmpty else { return }
            Task { @MainActor [weak self] in
                if !meshAnchors.isEmpty { self?.occlusionManager?.removeMeshAnchors(meshAnchors) }
                if !planeAnchors.isEmpty { self?.occlusionManager?.removePlaneAnchors(planeAnchors) }
            }
        }
        
        nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
            let transform = frame.camera.transform
            
            // Raycast from camera center to find nearest surface (runs on AR thread, fast)
            let camPos = simd_float3(transform.columns.3.x,
                                      transform.columns.3.y,
                                      transform.columns.3.z)
            let forward = -simd_normalize(simd_float3(transform.columns.2.x,
                                                       transform.columns.2.y,
                                                       transform.columns.2.z))
            let query = ARRaycastQuery(origin: camPos,
                                       direction: forward,
                                       allowing: .estimatedPlane,
                                       alignment: .any)
            let rayDist: Float? = session.raycast(query).first.map { result in
                let hitPos = simd_float3(result.worldTransform.columns.3.x,
                                          result.worldTransform.columns.3.y,
                                          result.worldTransform.columns.3.z)
                return simd_distance(camPos, hitPos)
            }

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
                self?.occlusionManager?.updateCameraTransform(transform)
                self?.sessionManager?.raycastDistance = rayDist
                
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
