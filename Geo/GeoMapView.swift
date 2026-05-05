//
//  GeoMapView.swift
//  Geo
//
//  Created by nettrash on 18/06/2024.
//

import SwiftUI
import MapKit

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

    var body: some View {
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
        }
        .scrollDisabled(true)
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
    }
}

#Preview {
    GeoMapView(app: GeoAppDelegate())
}
