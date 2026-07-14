//
//  SharePanoramaView.swift
//  Geo
//
//  The frozen, annotated panorama rendered to a shareable image: the captured
//  camera frame with the same peak markers + skyline the user sees, plus a
//  small branding footer. Reuses the live overlay views so the share image
//  can't drift from the on-screen rendering. Rendered off-screen via
//  `ImageRenderer`, so it self-sizes (no `.ignoresSafeArea`).
//

import SwiftUI
import CoreLocation

struct SharePanoramaView: View {
    let cameraImage: UIImage
    let size: CGSize
    let peaks: [NearbyPeak]
    let userLocation: CLLocation?
    let barometerAltitude: Double?
    /// The DEM-anchored observer altitude the skyline was computed with —
    /// same value the live view uses, so the share can't weld/suppress a
    /// different set of peaks than the screen showed. `nil` falls back to
    /// the baro-preferred / GPS expression.
    let observerAltitudeUsed: Double?
    let skylineSamples: [SkylineSample]
    @ObservedObject var sessionManager: ARSessionManager
    @ObservedObject var occlusionManager: AROcclusionManager
    let markerCount: Int

    /// One effective observer altitude for every projection in the share —
    /// mirrors `GeoNatureView.effectiveObserverAltitude`.
    private var effectiveObserverAltitude: Double? {
        observerAltitudeUsed
            ?? barometerAltitude.flatMap { $0 > 0 ? $0 : nil }
            ?? userLocation?.altitude
    }

    /// Peaks welded to the ridge (camera-independent `peakOnSilhouette`) — their
    /// AR markers are suppressed below so the share matches the live view: a
    /// silhouette peak is a ridge pill or nothing, never a flat marker.
    private var weldedPeakIDs: Set<UUID> {
        guard let loc = userLocation, !skylineSamples.isEmpty else { return [] }
        let obsAlt = effectiveObserverAltitude ?? loc.altitude
        return Set(peaks
            .filter { peakOnSilhouette($0, skyline: skylineSamples, observerAltitude: obsAlt) }
            .map { $0.id })
    }

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
                observerAltitudeUsed: observerAltitudeUsed,
                skylineSamples: skylineSamples,
                peaks: peaks,
                sessionManager: sessionManager
            )

            PeakOverlayView(
                // Peaks welded to the ridge are labelled by HorizonOverlayView
                // above, so suppress their AR markers here too — otherwise the
                // exported image double-draws them (pill + marker), which the
                // live view never does.
                peaks: peaks.filter { !weldedPeakIDs.contains($0.id) },
                userLocation: userLocation,
                observerAltitude: effectiveObserverAltitude,
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
                Text(verbatim: markerCount == 1 ? "1 marker" : "\(markerCount) markers")
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
