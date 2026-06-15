//
//  MarkerDetailSheet.swift
//  Geo
//
//  Tap-to-identify detail sheet for AR peak / history markers, plus the
//  share-sheet plumbing used by the freeze-frame panorama capture.
//

import SwiftUI
import CoreLocation
import UIKit

/// A marker the user tapped in the AR view. Drives the detail sheet.
enum ARMarkerSelection: Identifiable {
    case peak(NearbyPeak)
    case history(ARHistoryPoint)

    var id: UUID {
        switch self {
        case .peak(let p): return p.id
        case .history(let h): return h.id
        }
    }
}

/// Identifiable wrapper so a freshly-rendered share image can drive a
/// `.sheet(item:)` presentation.
struct ShareImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Detail card shown when a peak or history marker is tapped. A richer
/// rendering of the same fields the on-screen marker already shows.
struct MarkerDetailSheet: View {
    let selection: ARMarkerSelection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                switch selection {
                case .peak(let peak): peakRows(peak)
                case .history(let point): historyRows(point)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var title: String {
        switch selection {
        case .peak(let p): return p.name
        case .history: return "History point"
        }
    }

    @ViewBuilder
    private func peakRows(_ peak: NearbyPeak) -> some View {
        Section {
            LabeledContent("Altitude", value: Self.altitude(peak.altitude))
            LabeledContent("Distance", value: Self.distance(peak.distance))
            LabeledContent("Bearing", value: Self.bearing(peak.bearing))
            LabeledContent("Coordinates", value: Self.coordinate(peak.coordinate))
        }
        Section {
            Button {
                openInMaps(peak.coordinate, name: peak.name)
            } label: {
                Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
            }
        }
    }

    @ViewBuilder
    private func historyRows(_ point: ARHistoryPoint) -> some View {
        Section {
            LabeledContent("Recorded", value: Self.dateTime(point.date))
            LabeledContent("GPS altitude", value: Self.altitude(point.gpsAltitude))
            if point.barometerAltitude > 0 {
                LabeledContent("Barometric altitude", value: Self.altitude(point.barometerAltitude))
            }
            if point.pressure > 0 {
                LabeledContent("Pressure", value: String(format: "%.1f kPa", point.pressure))
            }
            LabeledContent("Speed", value: String(format: "%.1f m/s", max(0, point.speed)))
            LabeledContent("Distance", value: Self.distance(point.distance))
            LabeledContent("Bearing", value: Self.bearing(point.bearing))
            LabeledContent("Coordinates", value: Self.coordinate(point.coordinate))
        }
        Section {
            Button {
                openInMaps(point.coordinate, name: "History point")
            } label: {
                Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
            }
        }
    }

    private func openInMaps(_ coordinate: CLLocationCoordinate2D, name: String) {
        // Build via URLComponents so the name is fully percent-encoded — the
        // `.urlQueryAllowed` set leaves `&` and `=` intact, which a name like
        // "A & B" would otherwise inject into the query.
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.queryItems = [
            URLQueryItem(name: "daddr", value: "\(coordinate.latitude),\(coordinate.longitude)"),
            URLQueryItem(name: "q", value: name)
        ]
        if let url = components.url {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Formatting

    static func altitude(_ m: Double) -> String {
        m >= 1000 ? String(format: "%.2f km", m / 1000) : String(format: "%.0f m", m)
    }
    static func distance(_ m: Double) -> String {
        m >= 1000 ? String(format: "%.1f km", m / 1000) : String(format: "%.0f m", m)
    }
    static func bearing(_ deg: Double) -> String {
        String(format: "%.0f° %@", deg, Geometry.cardinalDirection(deg))
    }
    static func coordinate(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", c.latitude, c.longitude)
    }
    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Thin `UIActivityViewController` wrapper for the system share sheet.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
