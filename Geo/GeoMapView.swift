//
//  GeoMapView.swift
//  Geo
//
//  Created by nettrash on 18/06/2024.
//

import SwiftUI
import MapKit
import Combine

let emptyMountainInfo: MountainInfo = MountainInfo()

class selectedData: ObservableObject {
    @Published var selectedHistoryItem: HistoryItem? = nil
    @Published var selectedMountainInfo: MountainInfo = emptyMountainInfo
}

struct GeoMapView: View {
    
    @State private var isShowHistoryDetails: Bool = false
    @State private var isShowMountainDetails: Bool = false
    @State private var selected: selectedData = selectedData()
    
    private let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter
        }()

    @State var cameraPosition = MapCameraPosition.userLocation(followsHeading: false, fallback: MapCameraPosition.automatic)
    @State var app: GeoAppDelegate?

    // Offline expedition pack — region circles + "choose an area on the map" flow.
    @State private var offlinePacks: [OfflinePack] = []
    @State private var chooseAreaMode = false
    @State private var downloadRadiusKm: Double = 10
    @State private var mapCenter: CLLocationCoordinate2D?
    @State private var selectedPack: OfflinePack?
    @State private var nameAction: OfflineNameAction?
    @State private var nameText = ""

    var body: some View {
        ZStack {
        Map(position: $cameraPosition, interactionModes: .all)
        {
            if let sevenPeaks = app?.mountainsData?.sevenPeaks?.mountains {
                ForEach(sevenPeaks) { mountain in

                    Annotation(mountain.name ?? "", coordinate: CLLocationCoordinate2DMake(mountain.coordinates?.latitude ?? 0, mountain.coordinates?.longitude ?? 0)) {
                        Image("7MountainPoint")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 40, alignment: .center)
                            .onTapGesture {
                                selected.selectedMountainInfo = mountain
                                isShowMountainDetails = true
                            }
                    }

                }
            }
            
            if let highest = app?.mountainsData?.highest?.mountains {
                let sevenPeakNames = Set(app?.mountainsData?.sevenPeaks?.mountains?.compactMap({ $0.name }) ?? [])
                ForEach(highest.filter({ h in !sevenPeakNames.contains(h.name ?? "") })) { mountain in

                    Annotation(mountain.name ?? "", coordinate: CLLocationCoordinate2DMake(mountain.coordinates?.latitude ?? 0, mountain.coordinates?.longitude ?? 0)) {
                        Image("MountainPoint")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 40, alignment: .center)
                            .onTapGesture {
                                selected.selectedMountainInfo = mountain
                                isShowMountainDetails = true
                            }
                    }

                }
            }
                        
            if let snowLeopard = app?.mountainsData?.snowLeopardOfRussia?.mountains {
                let sevenPeakNames = Set(app?.mountainsData?.sevenPeaks?.mountains?.compactMap({ $0.name }) ?? [])
                let highestNames = Set(app?.mountainsData?.highest?.mountains?.compactMap({ $0.name }) ?? [])
                ForEach(snowLeopard.filter({ h in
                    let name = h.name ?? ""
                    return !sevenPeakNames.contains(name) && !highestNames.contains(name)
                })) { mountain in

                    Annotation(mountain.name ?? "", coordinate: CLLocationCoordinate2DMake(mountain.coordinates?.latitude ?? 0, mountain.coordinates?.longitude ?? 0)) {
                        Image("SnowLeopardPoint")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 40, alignment: .center)
                            .onTapGesture {
                                selected.selectedMountainInfo = mountain
                                isShowMountainDetails = true
                            }
                    }

                }
            }
            
            if let historyItems = app?.history.historyItems {
                ForEach(historyItems.suffix(25)) { historyItem in
                    Annotation(dateFormatter.string(from: historyItem.recordDate ?? Date()), coordinate: CLLocationCoordinate2DMake(historyItem.gpsLatitude, historyItem.gpsLongitude)) {
                        Image("HistoryPoint")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 40, alignment: .center)
                            .onTapGesture {
                                selected.selectedHistoryItem = historyItem
                                isShowHistoryDetails = true
                            }
                    }
                }
            }

            // Offline pack regions: one orange circle per saved pack with a
            // tappable centre handle (→ delete), plus a blue preview circle of
            // the chosen radius while picking an area.
            ForEach(offlinePacks) { pack in
                MapCircle(center: pack.center, radius: pack.radiusKm * 1000)
                    .foregroundStyle(.orange.opacity(0.12))
                    .stroke(.orange.opacity(0.8), lineWidth: 1.5)
                Annotation(pack.name, coordinate: pack.center) {
                    Image(systemName: "square.and.arrow.down.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.orange)
                        .padding(6)
                        .background(.thinMaterial, in: Circle())
                        .onTapGesture { selectedPack = pack }
                }
            }
            if chooseAreaMode, let center = mapCenter {
                MapCircle(center: center, radius: downloadRadiusKm * 1000)
                    .foregroundStyle(.blue.opacity(0.12))
                    .stroke(.blue, lineWidth: 2)
            }
        }
        .scrollDisabled(!chooseAreaMode)
        .mapControlVisibility(.visible)
        .mapControls {
            MapCompass()
            MapUserLocationButton()
            MapScaleView()
            MapPitchToggle()
        }
        .onAppear {
            // Lazy refresh — re-fetches only when CoreData has changed
            // since the last pass. Stops a quick tab toggle from
            // forcing a full 30-day fetch.
            self.app?.history.refreshIfNeeded()
        }
        // Track the map centre so "Download here" + the preview circle use it.
        .onMapCameraChange(frequency: .continuous) { context in
            mapCenter = context.region.center
        }
        // Mirror the manager's packs into local @State so the circles update
        // live (GeoMapView holds `app` as plain @State, not an observed object).
        .onReceive((app?.offlinePack?.$packs)?.eraseToAnyPublisher()
                   ?? Just([OfflinePack]()).eraseToAnyPublisher()) { newPacks in
            offlinePacks = newPacks
        }
        .sheet(isPresented: $isShowHistoryDetails) {
            if let historyItem = selected.selectedHistoryItem {
                HistoryDetailsView(item: historyItem)
            } else {
                Text("Loading...")
            }
        }
        .sheet(isPresented: $isShowMountainDetails) {
            if (selected.selectedMountainInfo.id == emptyMountainInfo.id) {
                Text("Loading...")
            } else {
                MountainDetailsView(mountain: selected.selectedMountainInfo)
            }
        }

            // Crosshair marking the area centre while choosing a region.
            if chooseAreaMode {
                Image(systemName: "plus")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.blue)
                    .allowsHitTesting(false)
            }

            // Bottom control bar — only when the offline manager exists.
            if let manager = app?.offlinePack {
                VStack {
                    Spacer()
                    MapOfflineBar(manager: manager,
                                  chooseAreaMode: $chooseAreaMode,
                                  radiusKm: $downloadRadiusKm,
                                  mapCenter: mapCenter,
                                  onDownloadHere: { center, radius in
                                      nameText = ""
                                      nameAction = .download(center, radius)
                                  })
                }
            }
        }
        // Tap a saved region's centre → rename or delete it.
        .confirmationDialog(selectedPack?.name ?? "", isPresented: Binding(
            get: { selectedPack != nil },
            set: { if !$0 { selectedPack = nil } }
        ), titleVisibility: .visible) {
            Button("Update") {
                if let pack = selectedPack { Task { await app?.offlinePack?.updatePack(pack) } }
                selectedPack = nil
            }
            Button("Rename") {
                if let pack = selectedPack {
                    nameText = pack.name
                    nameAction = .rename(pack)
                }
                selectedPack = nil
            }
            Button("Delete", role: .destructive) {
                if let pack = selectedPack { app?.offlinePack?.delete(pack) }
                selectedPack = nil
            }
            Button("Cancel", role: .cancel) { selectedPack = nil }
        }
        // Name a new area (on download) or rename an existing one.
        .alert(nameAlertTitle, isPresented: Binding(
            get: { nameAction != nil },
            set: { if !$0 { nameAction = nil } }
        )) {
            TextField("Name", text: $nameText)
            Button("Save") { commitName() }
            Button("Cancel", role: .cancel) { nameAction = nil }
        }
    }

    private var nameAlertTitle: String {
        if case .rename = nameAction { return "Rename area" }
        return "Name this area"
    }

    private func commitName() {
        guard let action = nameAction, let manager = app?.offlinePack else { nameAction = nil; return }
        switch action {
        case .download(let center, let radius):
            let chosenName = nameText
            Task {
                await manager.createPack(name: chosenName, center: center, radiusKm: radius)
                chooseAreaMode = false
            }
        case .rename(let pack):
            manager.rename(pack, to: nameText)
        }
        nameAction = nil
    }
}

/// What the Map tab's name alert is committing — a new download or a rename.
private enum OfflineNameAction {
    case download(CLLocationCoordinate2D, Double)
    case rename(OfflinePack)
}

/// Bottom control bar for the Map tab's offline-area download flow. Observes the
/// manager directly so it shows live download progress.
private struct MapOfflineBar: View {
    @ObservedObject var manager: OfflinePackManager
    @Binding var chooseAreaMode: Bool
    @Binding var radiusKm: Double
    let mapCenter: CLLocationCoordinate2D?
    /// Called with the chosen centre + radius; the host then prompts for a name
    /// before kicking off the download.
    let onDownloadHere: (CLLocationCoordinate2D, Double) -> Void

    private let radii: [Double] = [5, 10, 50, 100]

    var body: some View {
        VStack(spacing: 8) {
            if !chooseAreaMode {
                Button {
                    chooseAreaMode = true
                } label: {
                    Label("Download a region", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            } else if manager.isDownloading {
                // A pack is a single Overpass peak query — no chartable phase — so
                // an indeterminate spinner, not a 0%-stuck bar.
                HStack(spacing: 8) {
                    ProgressView()
                    Text(manager.statusText.isEmpty ? "Downloading…" : manager.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker("Radius", selection: $radiusKm) {
                    ForEach(radii, id: \.self) { Text("\(Int($0)) km").tag($0) }
                }
                .pickerStyle(.segmented)
                HStack {
                    Button("Cancel", role: .cancel) { chooseAreaMode = false }
                    Spacer()
                    Button("Download here") {
                        guard let center = mapCenter else { return }
                        onDownloadHere(center, radiusKm)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding()
    }
}

#Preview {
    GeoMapView(app: GeoAppDelegate())
}
