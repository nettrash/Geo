//
//  AROcclusionManager.swift
//  Geo
//
//  Created by nettrash on 25/03/2026.
//

import Foundation
import ARKit
import simd
import CoreLocation

/// Manages AR scene mesh data and performs raycasting to determine
/// whether real-world surfaces (walls, ceiling, floor) occlude virtual markers.
///
/// Requires a LiDAR-equipped device with `sceneReconstruction` enabled.
/// On devices without LiDAR, all points are reported as visible.
@MainActor
class AROcclusionManager: ObservableObject {
    
    /// Set of point IDs that are currently occluded (behind real geometry)
    @Published var occludedIDs: Set<UUID> = []
    
    /// Whether scene reconstruction is available on this device
    @Published var isSupported: Bool = false
    
    /// Distance (meters) from the camera to the nearest surface in the camera's forward direction.
    /// Computed from detected planes (all devices) every frame.
    @Published var wallDistance: Float?
    
    /// Collected mesh anchors from ARKit scene reconstruction
    private var meshAnchors: [ARMeshAnchor] = []
    
    /// Detected plane anchors (walls, floor, ceiling) — works on ALL ARKit devices
    private var planeAnchors: [ARPlaneAnchor] = []
    
    /// Camera transform from the latest AR frame
    private var cameraTransform: simd_float4x4 = matrix_identity_float4x4
    
    /// Queue for heavy raycasting work
    private let raycastQueue = DispatchQueue(label: "me.nettrash.Geo.occlusion", qos: .userInitiated)
    
    /// Maximum distance (meters) to consider mesh hits for occlusion.
    /// Mesh geometry beyond this distance is ignored (room-scale only).
    private let maxMeshOcclusionDistance: Float = 30.0
    
    // MARK: - Mesh Updates
    
    /// Called when ARSession adds or updates mesh anchors
    func updateMeshAnchors(_ anchors: [ARMeshAnchor]) {
        meshAnchors = anchors
    }
    
    /// Called when ARSession removes mesh anchors
    func removeMeshAnchors(_ anchors: [ARMeshAnchor]) {
        let removeIDs = Set(anchors.map(\.identifier))
        meshAnchors.removeAll { removeIDs.contains($0.identifier) }
    }
    
    /// Called when ARSession adds or updates plane anchors
    func updatePlaneAnchors(_ anchors: [ARPlaneAnchor]) {
        planeAnchors = anchors
    }
    
    /// Called when ARSession removes plane anchors
    func removePlaneAnchors(_ anchors: [ARPlaneAnchor]) {
        let removeIDs = Set(anchors.map(\.identifier))
        planeAnchors.removeAll { removeIDs.contains($0.identifier) }
    }
    
    /// Update the camera transform from the current AR frame
    func updateCameraTransform(_ transform: simd_float4x4) {
        cameraTransform = transform
        updateWallDistance()
    }
    
    /// Compute the distance from the camera to the nearest detected plane
    /// along the camera's forward direction.
    private func updateWallDistance() {
        guard !planeAnchors.isEmpty else {
            wallDistance = nil
            return
        }
        
        let camPos = simd_float3(cameraTransform.columns.3.x,
                                  cameraTransform.columns.3.y,
                                  cameraTransform.columns.3.z)
        // Camera forward = -Z column of the camera transform
        let forward = -simd_normalize(simd_float3(cameraTransform.columns.2.x,
                                                   cameraTransform.columns.2.y,
                                                   cameraTransform.columns.2.z))
        
        var minDist: Float?
        
        for anchor in planeAnchors {
            let planeTransform = anchor.transform
            // Plane normal = Y axis of the plane's local coordinate system
            let normal = simd_normalize(simd_float3(planeTransform.columns.1.x,
                                                     planeTransform.columns.1.y,
                                                     planeTransform.columns.1.z))
            let center = simd_float3(planeTransform.columns.3.x,
                                      planeTransform.columns.3.y,
                                      planeTransform.columns.3.z)
            
            let denom = dot(forward, normal)
            guard abs(denom) > 1e-6 else { continue }
            
            let t = dot(center - camPos, normal) / denom
            guard t > 0.05 else { continue } // must be in front of camera
            
            // Check if hit point is within the plane's detected extent
            let hitWorld = camPos + forward * t
            let inv = planeTransform.inverse
            let hitLocal = inv * simd_float4(hitWorld.x, hitWorld.y, hitWorld.z, 1.0)
            
            let halfX = anchor.planeExtent.width / 2 + 0.1
            let halfZ = anchor.planeExtent.height / 2 + 0.1
            if abs(hitLocal.x) <= halfX && abs(hitLocal.z) <= halfZ {
                if minDist == nil || t < minDist! {
                    minDist = t
                }
            }
        }
        
        wallDistance = minDist
    }
    
    // MARK: - Occlusion Check
    
    /// A point to test for occlusion, specified in ARKit world space.
    struct OcclusionTarget: Sendable {
        let id: UUID
        /// Position in ARKit world space (ENU: +X=East, +Y=Up, −Z=North)
        let worldPosition: simd_float3
    }
    
    /// Whether a raycast is currently in flight (prevents piling up work)
    private var isRaycasting = false
    
    /// Per-ID confidence counter. Increments when occluded, decrements when clear.
    /// A point is added to occludedIDs only after reaching occlusionThreshold,
    /// and removed only after dropping to 0, preventing rapid toggling.
    private var occlusionConfidence: [UUID: Int] = [:]
    
    /// Consecutive consistent reads required to toggle occlusion state.
    private let occlusionThreshold = 2
    
    /// Snapshot of a detected plane for safe background-thread access.
    private struct PlaneSnapshot: Sendable {
        let transform: simd_float4x4
        let width: Float
        let height: Float
    }
    
    /// Check which targets are occluded by room geometry.
    /// Uses detected planes (ALL devices) and mesh raycasting (LiDAR only).
    func checkOcclusion(targets: [OcclusionTarget]) {
        guard !isRaycasting else { return }
        
        let hasMesh = isSupported && !meshAnchors.isEmpty
        let hasPlanes = !planeAnchors.isEmpty
        
        guard hasMesh || hasPlanes else {
            if !occludedIDs.isEmpty { occludedIDs = [] }
            return
        }
        
        // Snapshot current state for background work
        let anchors = meshAnchors
        let camera = cameraTransform
        let maxDist = maxMeshOcclusionDistance
        let planes: [PlaneSnapshot] = planeAnchors
            .filter { $0.alignment == .vertical }
            .map { PlaneSnapshot(transform: $0.transform, width: $0.planeExtent.width, height: $0.planeExtent.height) }
        isRaycasting = true
        
        raycastQueue.async { [weak self] in
            let cameraPos = simd_float3(camera.columns.3.x,
                                         camera.columns.3.y,
                                         camera.columns.3.z)
            
            var newOccluded = Set<UUID>()
            
            for target in targets {
                let toTarget = target.worldPosition - cameraPos
                let dist = length(toTarget)
                
                // Skip very close points
                guard dist > 0.1 else { continue }
                
                // 1. Check against detected wall planes (works on ALL devices)
                if Self.isOccludedByPlanes(
                    cameraPos: cameraPos,
                    targetPos: target.worldPosition,
                    distance: dist,
                    planes: planes
                ) {
                    newOccluded.insert(target.id)
                    continue
                }
                
                // 2. Check against mesh geometry (LiDAR only)
                if hasMesh {
                    let direction = normalize(toTarget)
                    let rayMaxDist = min(dist, maxDist)
                    
                    if let hitDistance = Self.raycastAgainstMeshes(
                        origin: cameraPos,
                        direction: direction,
                        meshAnchors: anchors,
                        maxDistance: rayMaxDist
                    ) {
                        if hitDistance < dist - 0.1 {
                            newOccluded.insert(target.id)
                        }
                    }
                }
            }
            
            Task { @MainActor [weak self] in
                guard let self else { return }
                
                let allIDs = Set(targets.map(\.id))
                var stableOccluded = self.occludedIDs
                
                for id in allIDs {
                    if newOccluded.contains(id) {
                        let c = min((self.occlusionConfidence[id] ?? 0) + 1, self.occlusionThreshold)
                        self.occlusionConfidence[id] = c
                        if c >= self.occlusionThreshold { stableOccluded.insert(id) }
                    } else {
                        let c = max((self.occlusionConfidence[id] ?? 0) - 1, 0)
                        self.occlusionConfidence[id] = c
                        if c == 0 { stableOccluded.remove(id) }
                    }
                }
                // Evict confidence entries for points no longer in the target list
                self.occlusionConfidence = self.occlusionConfidence.filter { allIDs.contains($0.key) }
                
                if stableOccluded != self.occludedIDs {
                    self.occludedIDs = stableOccluded
                }
                self.isRaycasting = false
            }
        }
    }
    
    // MARK: - Plane-Based Occlusion
    
    /// Check if a target point is behind any detected vertical plane (wall).
    private nonisolated static func isOccludedByPlanes(
        cameraPos: simd_float3,
        targetPos: simd_float3,
        distance: Float,
        planes: [PlaneSnapshot]
    ) -> Bool {
        let dir = (targetPos - cameraPos) / distance
        
        for plane in planes {
            // Plane normal = Y axis of the plane's local transform
            let normal = simd_normalize(simd_float3(
                plane.transform.columns.1.x,
                plane.transform.columns.1.y,
                plane.transform.columns.1.z
            ))
            let center = simd_float3(
                plane.transform.columns.3.x,
                plane.transform.columns.3.y,
                plane.transform.columns.3.z
            )
            
            // Ray-plane intersection
            let denom = dot(dir, normal)
            guard abs(denom) > 1e-6 else { continue }
            
            let t = dot(center - cameraPos, normal) / denom
            // Hit must be between camera and target
            guard t > 0.1 && t < distance - 0.1 else { continue }
            
            // Check if hit falls within the plane extent (+ margin)
            let hitWorld = cameraPos + dir * t
            let invTransform = plane.transform.inverse
            let hitLocal = invTransform * simd_float4(hitWorld.x, hitWorld.y, hitWorld.z, 1.0)
            
            let halfX = plane.width / 2 + 0.3
            let halfZ = plane.height / 2 + 0.3
            if abs(hitLocal.x) <= halfX && abs(hitLocal.z) <= halfZ {
                return true
            }
        }
        
        return false
    }
    
    // MARK: - Raycasting
    
    /// Perform a ray vs mesh intersection test against all mesh anchors.
    /// Returns the distance to the closest hit, or nil if no hit.
    private nonisolated static func raycastAgainstMeshes(
        origin: simd_float3,
        direction: simd_float3,
        meshAnchors: [ARMeshAnchor],
        maxDistance: Float
    ) -> Float? {
        var closestHit: Float? = nil
        
        for anchor in meshAnchors {
            // Quick bounding-sphere check to skip distant mesh chunks
            let anchorPos = simd_float3(anchor.transform.columns.3.x,
                                         anchor.transform.columns.3.y,
                                         anchor.transform.columns.3.z)
            let toAnchor = anchorPos - origin
            let anchorDist = length(toAnchor)
            
            // ARMeshAnchor chunks are typically ~5m across. Skip if too far.
            let chunkRadius: Float = 8.0
            if anchorDist > maxDistance + chunkRadius {
                continue
            }
            
            // Test against triangles in this mesh
            if let hit = raycastAgainstMeshAnchor(
                origin: origin,
                direction: direction,
                anchor: anchor,
                maxDistance: closestHit ?? maxDistance
            ) {
                if closestHit == nil || hit < closestHit! {
                    closestHit = hit
                }
            }
        }
        
        return closestHit
    }
    
    /// Raycast against a single ARMeshAnchor's triangle geometry.
    private nonisolated static func raycastAgainstMeshAnchor(
        origin: simd_float3,
        direction: simd_float3,
        anchor: ARMeshAnchor,
        maxDistance: Float
    ) -> Float? {
        let geometry = anchor.geometry
        let transform = anchor.transform
        
        // Get vertex buffer
        let vertexSource = geometry.vertices
        let vertexCount = vertexSource.count
        guard vertexCount > 0 else { return nil }
        
        // Get face (index) buffer
        let faceSource = geometry.faces
        let faceCount = faceSource.count
        guard faceCount > 0 else { return nil }
        guard faceSource.indexCountPerPrimitive == 3 else { return nil } // triangles
        
        // Read vertices (transform to world space)
        let vertexStride = vertexSource.stride
        let vertexBuffer = vertexSource.buffer.contents()
        
        // Read face indices
        let indexBuffer = faceSource.buffer.contents()
        let bytesPerIndex = faceSource.bytesPerIndex
        
        var closestHit: Float? = nil
        
        for faceIdx in 0..<faceCount {
            // Read 3 vertex indices for this triangle
            let i0 = readIndex(indexBuffer, at: faceIdx * 3 + 0, bytesPerIndex: bytesPerIndex)
            let i1 = readIndex(indexBuffer, at: faceIdx * 3 + 1, bytesPerIndex: bytesPerIndex)
            let i2 = readIndex(indexBuffer, at: faceIdx * 3 + 2, bytesPerIndex: bytesPerIndex)
            
            guard i0 < vertexCount, i1 < vertexCount, i2 < vertexCount else { continue }
            
            // Read vertex positions (local space)
            let v0Local = readVertex(vertexBuffer, at: i0, stride: vertexStride)
            let v1Local = readVertex(vertexBuffer, at: i1, stride: vertexStride)
            let v2Local = readVertex(vertexBuffer, at: i2, stride: vertexStride)
            
            // Transform to world space
            let v0 = transformPoint(v0Local, by: transform)
            let v1 = transformPoint(v1Local, by: transform)
            let v2 = transformPoint(v2Local, by: transform)
            
            // Möller–Trumbore ray-triangle intersection
            if let t = rayTriangleIntersection(
                origin: origin,
                direction: direction,
                v0: v0, v1: v1, v2: v2
            ) {
                if t > 0.05 && t <= (closestHit ?? maxDistance) {
                    closestHit = t
                }
            }
        }
        
        return closestHit
    }
    
    // MARK: - Helpers
    
    /// Read a vertex index from the index buffer
    private nonisolated static func readIndex(_ buffer: UnsafeRawPointer, at index: Int, bytesPerIndex: Int) -> Int {
        switch bytesPerIndex {
        case 2:
            return Int(buffer.load(fromByteOffset: index * 2, as: UInt16.self))
        case 4:
            return Int(buffer.load(fromByteOffset: index * 4, as: UInt32.self))
        default:
            return 0
        }
    }
    
    /// Read a float3 vertex position from the vertex buffer
    private nonisolated static func readVertex(_ buffer: UnsafeRawPointer, at index: Int, stride: Int) -> simd_float3 {
        let ptr = buffer.advanced(by: index * stride)
        let x = ptr.load(fromByteOffset: 0, as: Float.self)
        let y = ptr.load(fromByteOffset: 4, as: Float.self)
        let z = ptr.load(fromByteOffset: 8, as: Float.self)
        return simd_float3(x, y, z)
    }
    
    /// Transform a point from local space to world space using a 4x4 matrix
    private nonisolated static func transformPoint(_ point: simd_float3, by matrix: simd_float4x4) -> simd_float3 {
        let p4 = simd_float4(point.x, point.y, point.z, 1.0)
        let world = matrix * p4
        return simd_float3(world.x, world.y, world.z)
    }
    
    /// Möller–Trumbore ray-triangle intersection.
    /// Returns the distance `t` along the ray, or nil if no intersection.
    private nonisolated static func rayTriangleIntersection(
        origin: simd_float3,
        direction: simd_float3,
        v0: simd_float3,
        v1: simd_float3,
        v2: simd_float3
    ) -> Float? {
        let epsilon: Float = 1e-6
        
        let edge1 = v1 - v0
        let edge2 = v2 - v0
        let h = cross(direction, edge2)
        let a = dot(edge1, h)
        
        // Ray is parallel to triangle
        if abs(a) < epsilon { return nil }
        
        let f = 1.0 / a
        let s = origin - v0
        let u = f * dot(s, h)
        
        if u < 0.0 || u > 1.0 { return nil }
        
        let q = cross(s, edge1)
        let v = f * dot(direction, q)
        
        if v < 0.0 || u + v > 1.0 { return nil }
        
        let t = f * dot(edge2, q)
        
        if t > epsilon {
            return t
        }
        
        return nil
    }
}
