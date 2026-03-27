//
//  ARSessionManager.swift
//  Geo
//
//  Created by nettrash on 25/03/2026.
//

import Foundation
import ARKit
import CoreVideo
import simd

/// Publishes the AR camera's view and projection matrices every frame.
/// Used by PeakOverlayView to project world-space GPS points onto screen
/// coordinates with pixel-perfect alignment to the camera feed.
@MainActor
class ARSessionManager: ObservableObject {
    
    /// The camera's 4×4 view matrix (inverse of camera transform).
    /// Converts world-space → camera-space.
    @Published var viewMatrix: simd_float4x4 = matrix_identity_float4x4
    
    /// The camera's 4×4 projection matrix for the current viewport.
    /// Converts camera-space → clip-space.
    @Published var projectionMatrix: simd_float4x4 = matrix_identity_float4x4
    
    /// The camera's world-space transform (position + orientation).
    @Published var cameraTransform: simd_float4x4 = matrix_identity_float4x4
    
    /// The current viewport size (points) — needed for projection.
    @Published var viewportSize: CGSize = .zero
    
    /// Device interface orientation for correct projection matrix.
    @Published var interfaceOrientation: UIInterfaceOrientation = .portrait
    
    /// Whether the AR session has started delivering frames.
    @Published var isTracking: Bool = false
    
    /// Depth (meters) at the center of the viewport from LiDAR depth buffer.
    /// `nil` on non-LiDAR devices.
    @Published var centerDepth: Float?
    
    /// Distance (meters) to the nearest surface along the camera's forward direction,
    /// computed via `ARSession.raycast` with `.estimatedPlane`.
    /// Works on ALL ARKit devices and at much greater range (~20 m+) than plane detection.
    @Published var raycastDistance: Float?
    
    // MARK: - Scene Depth (LiDAR)
    
    /// Scene depth buffer copied each frame (Float32 meters). Not @Published to avoid extra SwiftUI churn.
    private(set) var depthData: [Float] = []
    private(set) var depthWidth: Int = 0
    private(set) var depthHeight: Int = 0
    /// Maps normalised camera-image UV → normalised viewport UV.
    private(set) var displayTransform: CGAffineTransform = .identity
    
    /// Update from an ARFrame — called by ARCameraView coordinator every frame.
    func update(from frame: ARFrame, viewportSize: CGSize, orientation: UIInterfaceOrientation) {
        let camera = frame.camera
        
        self.cameraTransform = camera.transform
        // viewMatrix = inverse of camera transform = converts world → camera space
        self.viewMatrix = camera.viewMatrix(for: orientation)
        // projectionMatrix maps camera-space → clip-space for the given viewport
        self.projectionMatrix = camera.projectionMatrix(
            for: orientation,
            viewportSize: viewportSize,
            zNear: 0.01,
            zFar: 1000
        )
        self.viewportSize = viewportSize
        self.interfaceOrientation = orientation
        
        self.isTracking = camera.trackingState == .normal
        
        // Capture scene depth for per-pixel occlusion (LiDAR devices only)
        self.displayTransform = frame.displayTransform(for: orientation, viewportSize: viewportSize)
        if let depthMap = (frame.smoothedSceneDepth ?? frame.sceneDepth)?.depthMap {
            CVPixelBufferLockBaseAddress(depthMap, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
            let w = CVPixelBufferGetWidth(depthMap)
            let h = CVPixelBufferGetHeight(depthMap)
            if let base = CVPixelBufferGetBaseAddress(depthMap) {
                let floatPtr = base.assumingMemoryBound(to: Float32.self)
                depthData = Array(UnsafeBufferPointer(start: floatPtr, count: w * h))
                depthWidth = w
                depthHeight = h
            }
        } else {
            depthData = []
        }
        
        // Compute center-of-viewport depth for wall distance display
        if !depthData.isEmpty, depthWidth > 0, depthHeight > 0 {
            let centerNorm = CGPoint(x: 0.5, y: 0.5)
            let camUV = centerNorm.applying(self.displayTransform.inverted())
            let px = min(max(Int(camUV.x * CGFloat(depthWidth)), 0), depthWidth - 1)
            let py = min(max(Int(camUV.y * CGFloat(depthHeight)), 0), depthHeight - 1)
            let d = depthData[py * depthWidth + px]
            centerDepth = d > 0.01 ? d : nil
        } else {
            centerDepth = nil
        }
    }
    
    /// Check if a world-space point projected to `screenPoint` is occluded
    /// by a real surface using the LiDAR scene depth buffer.
    /// Returns `false` (not occluded) when no depth data is available.
    func isOccludedByDepth(screenPoint: CGPoint, worldPoint: simd_float3) -> Bool {
        guard !depthData.isEmpty,
              depthWidth > 0, depthHeight > 0,
              viewportSize.width > 0, viewportSize.height > 0 else {
            return false
        }
        
        // Camera-space depth of the world point (along camera -Z axis)
        let w4 = simd_float4(worldPoint.x, worldPoint.y, worldPoint.z, 1.0)
        let camSpace = viewMatrix * w4
        let pointDepth = -camSpace.z
        guard pointDepth > 0 else { return false }
        
        // Screen point → normalised viewport → camera image UV (via inverse display transform)
        let normScreen = CGPoint(
            x: screenPoint.x / viewportSize.width,
            y: screenPoint.y / viewportSize.height
        )
        let camUV = normScreen.applying(displayTransform.inverted())
        
        let px = min(max(Int(camUV.x * CGFloat(depthWidth)), 0), depthWidth - 1)
        let py = min(max(Int(camUV.y * CGFloat(depthHeight)), 0), depthHeight - 1)
        
        let sceneDepth = depthData[py * depthWidth + px]
        
        // Real surface is closer than the marker → marker is behind a wall/surface
        return sceneDepth > 0.1 && sceneDepth < pointDepth - 0.3
    }
    
    /// Project a world-space 3D point (x,y,z) to screen coordinates (points).
    /// Returns nil if the point is behind the camera.
    func projectToScreen(_ worldPoint: simd_float3) -> CGPoint? {
        let vp = viewportSize
        guard vp.width > 0 && vp.height > 0 else { return nil }
        
        // World → clip space
        let world4 = simd_float4(worldPoint.x, worldPoint.y, worldPoint.z, 1.0)
        let clip = projectionMatrix * viewMatrix * world4
        
        // Behind camera check
        guard clip.w > 0 else { return nil }
        
        // Clip → NDC (normalized device coordinates: -1..1)
        let ndc = simd_float3(clip.x / clip.w, clip.y / clip.w, clip.z / clip.w)
        
        // NDC → screen coordinates (points)
        // NDC x: -1 = left, +1 = right
        // NDC y: -1 = bottom, +1 = top (in ARKit projection)
        let screenX = CGFloat((ndc.x + 1.0) * 0.5) * vp.width
        let screenY = CGFloat((1.0 - ndc.y) * 0.5) * vp.height
        
        return CGPoint(x: screenX, y: screenY)
    }
}
