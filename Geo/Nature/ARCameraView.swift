//
//  ARCameraView.swift
//  Geo
//
//  Created by nettrash on 24/03/2026.
//

import SwiftUI
import ARKit
import CoreLocation

/// UIViewRepresentable wrapper for ARSCNView to show the camera feed.
/// When a LiDAR sensor is available, enables scene reconstruction so the
/// `AROcclusionManager` can hide markers behind real-world surfaces (walls, etc.).
struct ARCameraView: UIViewRepresentable {
    
    /// Shared occlusion manager — receives mesh anchors from the AR session
    var occlusionManager: AROcclusionManager?
    
    /// Shared session manager — publishes camera matrices every frame for overlay projection
    var sessionManager: ARSessionManager?
    
    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView()
        arView.session.delegate = context.coordinator
        arView.autoenablesDefaultLighting = true
        arView.automaticallyUpdatesLighting = true
        
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravityAndHeading
        
        // Detect the floor/ceiling for surface-distance display.
        // Vertical plane detection is intentionally omitted: detected nearby surfaces
        // (trees, fences, buildings) would incorrectly occlude distant outdoor GPS markers.
        // LiDAR mesh occlusion (below) handles accurate close-range occlusion on supported devices.
        config.planeDetection = [.horizontal]
        
        // Enable scene reconstruction (mesh) on LiDAR devices for occlusion
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        
        arView.session.run(config)
        
        // Store the ARSCNView in the coordinator so we can read its bounds
        context.coordinator.arView = arView
        
        return arView
    }
    
    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.occlusionManager = occlusionManager
        context.coordinator.sessionManager = sessionManager
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
            
            Task { @MainActor [weak self] in
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
