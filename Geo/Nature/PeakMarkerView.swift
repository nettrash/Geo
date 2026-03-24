//
//  PeakMarkerView.swift
//  Geo
//
//  Created by nettrash on 24/03/2026.
//

import SwiftUI

/// Single peak marker displayed in the AR overlay
struct PeakMarkerView: View {
    let peak: NearbyPeak
    
    var body: some View {
        VStack(spacing: 2) {
            // Peak name
            Text(verbatim: peak.name)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
            
            // Distance and altitude
            HStack(spacing: 4) {
                Text(verbatim: formatDistance(peak.distance))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                
                if peak.altitude > 0 {
                    Text(verbatim: "·")
                        .foregroundStyle(.white.opacity(0.6))
                    Text(verbatim: formatAltitude(peak.altitude))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            
            // Arrow pointing down to the peak location
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 8))
                .foregroundStyle(.orange)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.black.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.orange.opacity(0.8), lineWidth: 1)
                )
        )
    }
    
    private func formatDistance(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.1f km", meters / 1000)
        } else {
            return String(format: "%.0f m", meters)
        }
    }
    
    private func formatAltitude(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.1f km", meters / 1000)
        } else {
            return String(format: "%.0f m", meters)
        }
    }
}
