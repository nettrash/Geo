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
    
    /// Monotonic per-frame counter. The heavy matrices below update every
    /// frame as PLAIN (non-@Published) vars so they don't fire
    /// `objectWillChange` ~60 Hz and invalidate the whole overlay subtree.
    /// This single lightweight published tick is bumped once per frame;
    /// overlay bodies read it to stay live (`_ = sessionManager.frameTick`).
    @Published private(set) var frameTick: UInt64 = 0

    /// The camera's 4×4 view matrix (inverse of camera transform).
    /// Converts world-space → camera-space. Plain (see `frameTick`).
    var viewMatrix: simd_float4x4 = matrix_identity_float4x4

    /// The camera's 4×4 projection matrix for the current viewport.
    /// Converts camera-space → clip-space. Plain (see `frameTick`).
    var projectionMatrix: simd_float4x4 = matrix_identity_float4x4

    /// The camera's world-space transform (position + orientation). Plain (see `frameTick`).
    var cameraTransform: simd_float4x4 = matrix_identity_float4x4

    /// The current viewport size (points) — needed for projection. Plain (see `frameTick`).
    var viewportSize: CGSize = .zero

    /// Device interface orientation for correct projection matrix. Plain (see `frameTick`).
    var interfaceOrientation: UIInterfaceOrientation = .portrait
    
    /// Whether the AR session has started delivering frames.
    @Published var isTracking: Bool = false

    /// Manual compass-alignment offset, degrees. The device compass that
    /// seeds ARKit's `gravityAndHeading` frame is routinely 5–15° off,
    /// sliding the whole AR overlay sideways no matter how correct the
    /// geometry is; this knob lets the user drag the overlay back onto
    /// the real panorama. Applied inside `worldPoint(east:up:north:)` —
    /// the SINGLE projection every overlay element (skyline, cardinal
    /// labels, welded pills, AR markers, occlusion targets, tap
    /// hit-tests, share render) goes through — so everything shifts
    /// coherently with one value.
    ///
    /// SIGN CONVENTION: positive rotates all drawn content CLOCKWISE in
    /// compass bearing (a point drawn at bearing θ renders where θ +
    /// offset would) — because screen-right corresponds to increasing
    /// azimuth relative to the camera, a POSITIVE offset moves the
    /// overlay RIGHT on screen, matching a rightward drag. Consumers
    /// that window content by camera heading must compensate: the true
    /// bearing at the screen centre is (cameraHeading − offset).
    ///
    /// Session-only by design (plain published state, never persisted):
    /// compass error is different every session.
    @Published var headingAlignmentDeg: Double = 0

    /// The backing `ARSCNView`, set by `ARCameraView`'s coordinator. Held weakly
    /// so the session manager never keeps the camera view alive past the Nature
    /// tab. Used to grab the freeze-frame for the share shutter.
    weak var sceneView: ARSCNView?

    /// Snapshot the live camera feed as a `UIImage` (SceneKit `snapshot()` must
    /// run on the main thread). The SwiftUI peak/horizon overlays aren't SceneKit
    /// content, so they're composited on top separately by `NaturePanoramaView`.
    func snapshot() -> UIImage? { sceneView?.snapshot() }

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

        // Bump the single published tick once per frame so overlay views
        // re-render while the heavy matrices above stay plain properties.
        self.frameTick &+= 1

        self.isTracking = camera.trackingState == .normal
    }
    
    /// Map a local ENU offset (metres, East-North-Up) to an ARKit world-space
    /// point, anchored to the camera's current world position.
    ///
    /// ARKit's `gravityAndHeading` frame is +X = East, +Y = Up, −Z = North,
    /// and the world origin is the session-start pose — so we offset by the
    /// camera's translation (columns.3) to keep markers welded to the user as
    /// the camera drifts. This is the SINGLE projection shared by every overlay
    /// (PeakOverlayView, HorizonOverlayView) and the tap hit-test, so they can
    /// never diverge.
    ///
    /// The manual compass alignment (`headingAlignmentDeg`) is applied HERE,
    /// rotating (east, north) about the vertical axis, so every consumer of
    /// this choke point — horizon line, cardinal labels, peak markers,
    /// hit-tests — shifts coherently with
    /// the one knob. See the property doc for the sign derivation.
    func worldPoint(east: Double, up: Double, north: Double) -> simd_float3 {
        let (e, n) = Geometry.rotateENU(east: east, north: north,
                                        clockwiseDegrees: headingAlignmentDeg)
        let c = cameraTransform.columns.3
        return simd_float3(Float(e) + c.x, Float(up) + c.y, Float(-n) + c.z)
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
