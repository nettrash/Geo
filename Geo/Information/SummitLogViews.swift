//
//  SummitLogViews.swift
//  Geo
//
//  UI for the summit log: the proximity "log this ascent?" prompt, the
//  Stat-tab trophy-case list/detail, and the shareable summit card.
//  Reuses the share plumbing (ShareImage / ActivityView) from
//  MarkerDetailSheet.swift.
//

import SwiftUI
import CoreLocation

// MARK: - Formatting

enum SummitFormat {
    static func date(_ d: Date?) -> String {
        (d ?? Date()).formatted(date: .abbreviated, time: .shortened)
    }
    /// Plain metres — summit elevations read conventionally in metres (not km),
    /// and this matches the Android display.
    static func meters(_ m: Double) -> String {
        String(format: "%.0f m", m)
    }
    static func setLabel(_ s: String?) -> String {
        switch s {
        case "sevenPeaks": return "Seven Summits"
        case "snowLeopardOfRussia": return "Snow Leopard"
        case "highest": return "Highest peaks"
        default: return "Peak"
        }
    }
    static func coordinate(_ lat: Double, _ lon: Double) -> String {
        String(format: "%.5f, %.5f", lat, lon)
    }
}

// MARK: - Proximity prompt (offer to log on arrival)

/// Presented app-wide when the user is near a known peak. Confirms the ascent
/// with an optional note. Manual confirm only — never auto-logs.
struct SummitLogSheet: View {
    let app: GeoAppDelegate?
    let peak: MountainInfo
    let set: String
    /// Called on Log or Not-now so the host can stop re-presenting this peak.
    var onClose: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var note: String = ""

    /// The user's own measured altitude (barometric MSL); nil until a real fix.
    private var measured: Double? { (app?.barometer?.height).flatMap { $0 > 0 ? $0 : nil } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Collection", value: SummitFormat.setLabel(set))
                    if let h = peak.height { LabeledContent("Elevation", value: "\(h) m") }
                    LabeledContent("Your altitude",
                                   value: measured.map { "\(Int($0.rounded())) m" } ?? "—")
                    LabeledContent("Date", value: SummitFormat.date(Date()))
                } header: {
                    Text("Log ascent")
                } footer: {
                    Text("Your altitude is the barometric reading — approximate unless calibrated. Only the peak's public location is stored, not yours.")
                }
                Section("Note") {
                    TextField("How was it? (optional)", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .navigationTitle(peak.name ?? "Summit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Not now") { close() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Log") {
                        app?.summitLog?.log(peak: peak, set: set,
                                            measuredAltitude: measured ?? 0,
                                            note: note.trimmingCharacters(in: .whitespacesAndNewlines))
                        close()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func close() { onClose(); dismiss() }
}

// MARK: - Trophy case (Stat tab)

struct SummitsSectionView: View {
    let store: SummitLogStore
    @State private var selected: SummitLog?

    var body: some View {
        VStack(spacing: 8) {
            Text("SUMMITS")
                .font(.title)
                .padding(.top)

            if store.summits.isEmpty {
                Text("No summits logged yet — when you reach a known peak, Geo offers to log it here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else {
                ForEach(store.summits) { log in
                    Button { selected = log } label: { SummitRowView(log: log) }
                        .buttonStyle(.plain)
                }
            }
        }
        .sheet(item: $selected) { log in
            SummitDetailView(log: log, store: store)
        }
    }
}

private struct SummitRowView: View {
    let log: SummitLog
    var body: some View {
        HStack {
            Image(systemName: "mountain.2.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(log.peakName ?? "Summit").font(.subheadline).fontWeight(.semibold)
                Text(SummitFormat.date(log.loggedDate)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if log.peakHeight > 0 {
                    Text("▲ \(SummitFormat.meters(log.peakHeight))").font(.caption)
                }
                Text(SummitFormat.setLabel(log.peakSet)).font(.caption2).foregroundStyle(.secondary)
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

private struct SummitDetailView: View {
    let log: SummitLog
    let store: SummitLogStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var showDeleteConfirm = false
    @State private var note: String = ""
    @State private var shareImage: ShareImage?
    /// Skip the on-close note save when the row is being deleted.
    @State private var isDeleting = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(SummitFormat.setLabel(log.peakSet))
                        .font(.subheadline).foregroundStyle(.secondary)

                    statRow("Logged", SummitFormat.date(log.loggedDate))
                    if log.peakHeight > 0 { statRow("Elevation", SummitFormat.meters(log.peakHeight)) }
                    if log.measuredAltitude > 0 { statRow("Your altitude", SummitFormat.meters(log.measuredAltitude)) }
                    statRow("Coordinates", SummitFormat.coordinate(log.peakLatitude, log.peakLongitude))

                    Text("Note").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                    // Persisted once when the detail closes (see .onDisappear),
                    // not per keystroke — a Core Data save on every character
                    // would amplify into CloudKit pushes.
                    TextField("Add a note", text: $note, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button { openInMaps() } label: {
                            Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        Button { shareCard() } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 6)
                }
                .padding()
            }
            .navigationTitle(log.peakName ?? "Summit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            .alert("Delete this summit?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) { isDeleting = true; store.delete(log); dismiss() }
                Button("Cancel", role: .cancel) { }
            }
            .sheet(item: $shareImage) { share in
                ActivityView(items: [share.image])
            }
            .onAppear { note = log.note ?? "" }
            .onDisappear {
                // Save the edited note once, on close (not per keystroke).
                if !isDeleting, note != (log.note ?? "") {
                    store.updateNote(log, note: note)
                }
            }
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .fontDesign(.monospaced)
    }

    private func openInMaps() {
        var c = URLComponents()
        c.scheme = "https"
        c.host = "maps.apple.com"
        c.queryItems = [
            URLQueryItem(name: "daddr", value: "\(log.peakLatitude),\(log.peakLongitude)"),
            URLQueryItem(name: "q", value: log.peakName ?? "Summit")
        ]
        if let url = c.url { UIApplication.shared.open(url) }
    }

    private func shareCard() {
        let card = SummitShareCardView(log: log)
        let renderer = ImageRenderer(content: card)
        renderer.scale = displayScale
        if let image = renderer.uiImage {
            shareImage = ShareImage(image: image)
        }
    }
}

// MARK: - Share card

/// Self-sizing card rendered off-screen via `ImageRenderer` for sharing.
/// Shows only public peak data + the user's own measured altitude — never the
/// user's raw GPS position (privacy invariant).
struct SummitShareCardView: View {
    let log: SummitLog

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "mountain.2.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text(SummitFormat.setLabel(log.peakSet).uppercased())
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.orange.opacity(0.9))
            Text(log.peakName ?? "Summit")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            if log.peakHeight > 0 {
                Text("▲ \(SummitFormat.meters(log.peakHeight))")
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
            }
            Text("Logged \(SummitFormat.date(log.loggedDate))")
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
            if let note = log.note, !note.isEmpty {
                Text("“\(note)”")
                    .font(.system(size: 15, design: .rounded))
                    .italic()
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                Image(systemName: "mountain.2.fill").foregroundStyle(.orange)
                Text(verbatim: "Geo").font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .padding(28)
        .frame(width: 340, height: 440)
        .background(
            LinearGradient(colors: [Color(red: 0.06, green: 0.10, blue: 0.18),
                                    Color(red: 0.10, green: 0.16, blue: 0.12)],
                           startPoint: .top, endPoint: .bottom)
        )
    }
}
