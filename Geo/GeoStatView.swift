//
//  GeoStatView.swift
//  Geo
//
//  Created by nettrash on 18/06/2024.
//

import SwiftUI

struct GeoStatView: View {
    @ObservedObject var history: History
    @Environment(\.scenePhase) private var scenePhase
    @State private var showClearHistoryConfirmation = false
    private let app: GeoAppDelegate?

    var body: some View {
        ZStack(content: {
            Image("GeoBig")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .opacity(0.02)
            ScrollView {
                Text("TRACKING")
                    .font(.title)
                    .padding()
                if self.history.trackingAltitudeDataSetMin < 0 {
                    GraphPointsView(Caption: "TRACKING ALTITUDE", Data: $history.trackingAltitudeDataSet, Lines: [GraphLine(value: 4500, text: "thin air", color: Color.yellow), GraphLine(value: 7980, text: "death zone", color: Color.red), GraphLine(value: 0, text: "sea level", color: Color.blue)],
                                    min: $history.trackingAltitudeDataSetMin, max: $history.trackingAltitudeDataSetMax, Colors: [.white, .orange], Legend: ["barometer", "gps"], measurement: "m"
                    )
                } else {
                    GraphPointsView(Caption: "TRACKING ALTITUDE", Data: $history.trackingAltitudeDataSet, Lines: [GraphLine(value: 4500, text: "thin air", color: Color.yellow), GraphLine(value: 7980, text: "death zone", color: Color.red)],
                                    min: $history.trackingAltitudeDataSetMin, max: $history.trackingAltitudeDataSetMax, Colors: [.white, .orange], Legend: ["barometer", "gps"], measurement: "m"
                    )
                }
                Text("STATISTICS")
                    .font(.title)
                    .padding()
                GraphView(Caption: "PRESSURE", Data: $history.pressureDataSet, Lines: [GraphLine(value: 760, text: "normal", color: Color.green)],
                          min: $history.pressureDataSetMin, max: $history.pressureDataSetMax, measurement: "mm Hg")
                if self.history.altitudeBarometerDataSetMin < 0 {
                    GraphView(Caption: "ALTITUDE BAROMETER", Data: $history.altitudeBarometerDataSet, Lines: [GraphLine(value: 4500, text: "thin air", color: Color.yellow), GraphLine(value: 7980, text: "death zone", color: Color.red), GraphLine(value: 0, text: "sea level", color: Color.blue)],
                              min: $history.altitudeBarometerDataSetMin, max: $history.altitudeBarometerDataSetMax, measurement: "m")
                } else {
                    GraphView(Caption: "ALTITUDE BAROMETER", Data: $history.altitudeBarometerDataSet, Lines: [GraphLine(value: 4500, text: "thin air", color: Color.yellow), GraphLine(value: 7980, text: "death zone", color: Color.red)],
                              min: $history.altitudeBarometerDataSetMin, max: $history.altitudeBarometerDataSetMax, measurement: "m")
                }
                if self.history.altitudeGPSDataSetMin < 0 {
                    GraphView(Caption: "ALTITUDE GPS", Data: $history.altitudeGPSDataSet, Lines: [GraphLine(value: 4500, text: "thin air", color: Color.yellow), GraphLine(value: 7980, text: "death zone", color: Color.red), GraphLine(value: 0, text: "sea level", color: Color.blue)], min: $history.altitudeGPSDataSetMin, max: $history.altitudeGPSDataSetMax, measurement: "m")
                } else {
                    GraphView(Caption: "ALTITUDE GPS", Data: $history.altitudeGPSDataSet, Lines: [GraphLine(value: 4500, text: "thin air", color: Color.yellow), GraphLine(value: 7980, text: "death zone", color: Color.red)], min: $history.altitudeGPSDataSetMin, max: $history.altitudeGPSDataSetMax, measurement: "m")
                }

                if let recorder = app?.tripRecorder {
                    TripsSectionView(recorder: recorder)
                        .onAppear { recorder.reload() }
                }

                Button {
                    self.showClearHistoryConfirmation = true
                } label: {
                    Text("Clear history")
                        .font(.system(size: 14))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .foregroundColor(.white)
                        .background(Color(red: 1.0, green: 0.231, blue: 0.188))  // #FF3B30, matches Android
                        .cornerRadius(8)
                }
                .padding()
            }
        })
        .alert("Clear all history?", isPresented: $showClearHistoryConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                self.history.clearAll()
                self.history.refreshIfNeeded()
            }
        } message: {
            Text("This permanently deletes all recorded points and can't be undone.")
        }
        .onAppear {
            // Lazy refresh — re-fetches only when CoreData has changed
            // since the last pass. TabView builds the tab subtrees
            // up-front, so init does not re-run on tab re-selection;
            // this keeps the graphs live when the user returns here.
            self.app?.history.refreshIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                self.app?.history.refreshIfNeeded()
            }
        }
    }

    init(app: GeoAppDelegate?) {
        // Lazy refresh — only re-fetches when a new HistoryItem has
        // been inserted since the last fetch. Avoids hammering the
        // CoreData store every time the view is constructed.
        app?.history.refreshIfNeeded()
        self.app = app
        self.history = (app ?? GeoAppDelegate()).history
    }

}

// MARK: - Trip Recorder UI (M5c)

/// One-tap record control + saved-trip list. Wraps the always-on sample
/// stream into named outings; tapping a trip opens its summary + profile.
private struct TripsSectionView: View {
    let recorder: TripRecorder
    @State private var showNamePrompt = false
    @State private var tripName = ""
    @State private var selectedTrip: Trip?

    var body: some View {
        VStack(spacing: 8) {
            Text("TRIPS")
                .font(.title)
                .padding(.top)

            if recorder.isRecording, let start = recorder.startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("● Recording — \(TripFormat.duration(context.date.timeIntervalSince(start)))")
                        .font(.headline)
                        .foregroundStyle(.red)
                }
                HStack {
                    Button("Stop & Save") {
                        tripName = TripFormat.defaultName(start)
                        showNamePrompt = true
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Discard", role: .destructive) { recorder.cancel() }
                        .buttonStyle(.bordered)
                }
                .padding(.bottom)
            } else {
                Button {
                    recorder.start()
                } label: {
                    Label("Start trip", systemImage: "figure.hiking")
                }
                .buttonStyle(.borderedProminent)
                .padding(.bottom)
            }

            if recorder.trips.isEmpty {
                Text("No trips yet — tap Start to record an outing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                ForEach(recorder.trips) { trip in
                    Button { selectedTrip = trip } label: { TripRowView(trip: trip) }
                        .buttonStyle(.plain)
                }
            }
        }
        .alert("Name this trip", isPresented: $showNamePrompt) {
            TextField("Trip name", text: $tripName)
            Button("Save") {
                let trimmed = tripName.trimmingCharacters(in: .whitespacesAndNewlines)
                // Fall back to a name based on the recording START time (still set
                // here, before stop), so it matches the prefilled default.
                let fallback = TripFormat.defaultName(recorder.startedAt ?? Date())
                recorder.stop(name: trimmed.isEmpty ? fallback : trimmed)
            }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(item: $selectedTrip) { trip in
            TripDetailView(trip: trip, recorder: recorder)
        }
    }
}

private struct TripRowView: View {
    let trip: Trip
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.name ?? "Trip").font(.subheadline).fontWeight(.semibold)
                Text(TripFormat.dateRange(trip.startDate)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("↑ \(TripFormat.meters(trip.totalAscent))").font(.caption)
                Text(TripFormat.km(trip.distance)).font(.caption).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.15))
        .cornerRadius(10)
        .padding(.horizontal)
    }
}

private struct TripDetailView: View {
    let trip: Trip
    let recorder: TripRecorder
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(TripFormat.dateRange(trip.startDate))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    let profile = recorder.elevationProfile(for: trip)
                    if profile.count > 1 {
                        ElevationProfileView(samples: profile).frame(height: 140)
                    }

                    statRow("Ascent", "↑ \(TripFormat.meters(trip.totalAscent))")
                    statRow("Descent", "↓ \(TripFormat.meters(trip.totalDescent))")
                    statRow("Max altitude", TripFormat.meters(trip.maxAltitude))
                    statRow("Min altitude", TripFormat.meters(trip.minAltitude))
                    statRow("Distance", TripFormat.km(trip.distance))
                    statRow("Moving time", TripFormat.duration(trip.movingTime))
                    statRow("Total time", TripFormat.duration(
                        (trip.endDate ?? Date()).timeIntervalSince(trip.startDate ?? Date())))
                }
                .padding()
            }
            .fontDesign(.monospaced)
            .navigationTitle(trip.name ?? "Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            .alert("Delete this trip?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) { recorder.delete(trip); dismiss() }
                Button("Cancel", role: .cancel) { }
            }
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
    }
}

/// Lightweight elevation-profile sparkline (barometric altitude vs sample).
private struct ElevationProfileView: View {
    let samples: [Double]
    var body: some View {
        GeometryReader { geo in
            let minV = samples.min() ?? 0
            let maxV = samples.max() ?? 1
            let range = max(maxV - minV, 1)
            Path { path in
                for (i, value) in samples.enumerated() {
                    let x = geo.size.width * CGFloat(i) / CGFloat(max(samples.count - 1, 1))
                    let y = geo.size.height * (1 - CGFloat((value - minV) / range))
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.orange, lineWidth: 2)
        }
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
    }
}

private enum TripFormat {
    static func meters(_ m: Double) -> String { "\(Int(m.rounded())) m" }
    static func km(_ m: Double) -> String { String(format: "%.2f km", m / 1000) }

    static func duration(_ seconds: TimeInterval) -> String {
        let t = Int(max(0, seconds))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    static func dateRange(_ start: Date?) -> String {
        guard let start else { return "" }
        return stamp.string(from: start)
    }

    static func defaultName(_ start: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        return "Trip \(f.string(from: start))"
    }
}

#Preview {
    GeoStatView(app: GeoAppDelegate())
}
