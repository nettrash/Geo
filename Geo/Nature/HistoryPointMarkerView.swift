//
//  HistoryPointMarkerView.swift
//  Geo
//
//  Created by nettrash on 24/03/2026.
//

import SwiftUI

/// History point marker for the AR camera view — visually distinct from peak markers
/// Uses a blue/cyan color scheme with a timeline-style design
struct HistoryPointMarkerView: View {
    let point: ARHistoryPoint
    
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
    
    var body: some View {
        VStack(spacing: 2) {
            // Date/time
            Text(verbatim: dateFormatter.string(from: point.date))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.cyan)
                .lineLimit(1)
            
            // Altitude info
            HStack(spacing: 3) {
                Image(systemName: "location.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.cyan.opacity(0.8))
                
                Text(verbatim: formatAltitude(point.gpsAltitude))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                
                if point.barometerAltitude > 0 {
                    Text(verbatim: "·")
                        .foregroundStyle(.white.opacity(0.5))
                    
                    Image(systemName: "barometer")
                        .font(.system(size: 8))
                        .foregroundStyle(.cyan.opacity(0.8))
                    
                    Text(verbatim: formatAltitude(point.barometerAltitude))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            
            // Distance from current position
            Text(verbatim: formatDistance(point.distance))
                .font(.system(size: 9, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
            
            // Dot marker pointing down
            Circle()
                .fill(.cyan)
                .frame(width: 6, height: 6)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.black.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.cyan.opacity(0.6), lineWidth: 0.5)
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
        if abs(meters) >= 1000 {
            return String(format: "%.1f km", meters / 1000)
        } else {
            return String(format: "%.0f m", meters)
        }
    }
}
