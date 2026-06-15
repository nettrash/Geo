//
//  SharePanoramaView.swift
//  Geo
//
//  The frozen, annotated panorama rendered to a shareable image: the captured
//  camera frame with the same peak/history markers + skyline the user sees,
//  plus a small branding footer. Reuses the live overlay views so the share
//  image can't drift from the on-screen rendering. Rendered off-screen via
//  `ImageRenderer`, so it self-sizes (no `.ignoresSafeArea`).
//

import SwiftUI
import CoreLocation

struct SharePanoramaView: View {
    let cameraImage: UIImage
    let size: CGSize
    let peaks: [NearbyPeak]
    let historyPoints: [ARHistoryPoint]
    let userLocation: CLLocation?
    let barometerAltitude: Double?
    let skylineSamples: [SkylineSample]
    @ObservedObject var sessionManager: ARSessionManager
    @ObservedObject var occlusionManager: AROcclusionManager
    let markerCount: Int

    var body: some View {
        ZStack {
            // Frozen camera frame.
            Image(uiImage: cameraImage)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()

            // Same skyline + markers the user sees, projected with the matrices
            // that are frozen for the duration of this synchronous render.
            HorizonOverlayView(
                userLocation: userLocation,
                barometerAltitude: barometerAltitude,
                skylineSamples: skylineSamples,
                sessionManager: sessionManager
            )

            PeakOverlayView(
                peaks: peaks,
                historyPoints: historyPoints,
                userLocation: userLocation,
                sessionManager: sessionManager,
                occlusionManager: occlusionManager
            )

            VStack {
                Spacer()
                footer
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color.black)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "mountain.2.fill")
                .foregroundStyle(.orange)
            Text(verbatim: "Geo")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            if markerCount > 0 {
                Text(verbatim: "·")
                    .foregroundStyle(.white.opacity(0.5))
                Text(verbatim: "\(markerCount) marked")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer()
            Text(Date().formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.45))
    }
}
