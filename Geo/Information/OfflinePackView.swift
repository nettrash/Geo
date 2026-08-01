//
//  OfflinePackView.swift
//  Geo
//
//  Info-tab card + management sheet for the offline expedition pack:
//  download the area around the current location (named peaks)
//  so the AR view keeps working with no signal, and list / delete the
//  saved packs. Map tiles are out of scope (MapKit licensing) — this is
//  "offline data & AR", not "offline map".
//

import SwiftUI
import CoreLocation

/// Info-tab card. Renders nothing until the manager exists.
struct OfflinePackCard: View {
    let manager: OfflinePackManager?
    let location: Location?

    var body: some View {
        if let manager {
            OfflinePackCardBody(manager: manager, location: location)
        }
    }
}

private struct OfflinePackCardBody: View {
    @ObservedObject var manager: OfflinePackManager
    let location: Location?
    @State private var showManager = false

    private var summary: String {
        if manager.packs.isEmpty { return "No areas saved" }
        return "\(manager.packs.count) area\(manager.packs.count == 1 ? "" : "s") saved"
    }

    var body: some View {
        ZStack {
            Text("O F F L I N E")
                .opacity(0.2)
                .font(.title)
                .rotationEffect(.degrees(-25))
                .padding()

            VStack {
                HStack(alignment: .top) {
                    Text("Expedition pack")
                        .font(.subheadline)
                        .padding()
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(verbatim: summary)
                        if manager.isDownloading {
                            Text(verbatim: "Downloading…")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding()
                }

                Button {
                    showManager = true
                } label: {
                    Text("Manage offline areas")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .padding([.horizontal, .bottom])

                Spacer().frame(height: 10)
            }
            .background(Color.gray.opacity(0.3))
            .fontDesign(.monospaced)
            .cornerRadius(15)
            .padding()
        }
        .sheet(isPresented: $showManager) {
            OfflinePackManagerView(manager: manager, location: location)
        }
    }
}

/// Full management sheet: download current area + saved-pack list.
struct OfflinePackManagerView: View {
    @ObservedObject var manager: OfflinePackManager
    let location: Location?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var radiusKm: Double = 10
    private let radii: [Double] = [5, 10, 50, 100]

    @State private var renamingPack: OfflinePack?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Download current area") {
                    if location?.location == nil {
                        Text("Waiting for a GPS fix…")
                            .foregroundStyle(.secondary)
                    } else {
                        TextField("Name (optional)", text: $name)
                        Picker("Radius", selection: $radiusKm) {
                            ForEach(radii, id: \.self) { r in
                                Text("\(Int(r)) km").tag(r)
                            }
                        }
                        if manager.isDownloading {
                            // A pack is now a single Overpass peak query — quick,
                            // and with no multi-step phase to chart — so this is an
                            // indeterminate spinner, not a 0%-stuck progress bar.
                            HStack(spacing: 8) {
                                ProgressView()
                                Text(manager.statusText.isEmpty ? "Downloading…" : manager.statusText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Button("Download this area") {
                                guard let center = location?.location?.coordinate else { return }
                                let chosenName = name
                                let chosenRadius = radiusKm
                                Task {
                                    await manager.createPack(name: chosenName,
                                                             center: center,
                                                             radiusKm: chosenRadius)
                                    name = ""
                                }
                            }
                        }
                    }
                }

                Section("Saved packs") {
                    if manager.packs.isEmpty {
                        Text("None yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(manager.packs) { pack in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pack.name)
                                        .font(.headline)
                                    Text("\(pack.peakCount) peaks · \(Int(pack.radiusKm)) km")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(pack.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if manager.updatingPackID == pack.id {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                            // Swipe right = rename / update, swipe left = delete.
                            .swipeActions(edge: .leading) {
                                Button {
                                    renameText = pack.name
                                    renamingPack = pack
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(.blue)

                                Button {
                                    Task { await manager.updatePack(pack) }
                                } label: {
                                    Label("Update", systemImage: "arrow.clockwise")
                                }
                                .tint(.orange)
                                .disabled(manager.isDownloading)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    manager.delete(pack)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                Section {
                    Text("Caches the area's named mountain peaks so the AR Nature view can label them with no signal. The chosen radius sets how wide an area is cached; peaks are shown in the camera out to ~80 km, so a wider pack means more distant summits get named on the horizon. Map tiles aren't included (provider licensing).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Offline packs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Rename area", isPresented: Binding(
                get: { renamingPack != nil },
                set: { if !$0 { renamingPack = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let pack = renamingPack { manager.rename(pack, to: renameText) }
                    renamingPack = nil
                }
                Button("Cancel", role: .cancel) { renamingPack = nil }
            }
        }
    }
}
