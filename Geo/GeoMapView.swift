//
//  GeoMapView.swift
//  Geo
//
//  Created by nettrash on 18/06/2024.
//

import SwiftUI
import MapKit

let emptyHistoryItem: HistoryItem = HistoryItem()
let emptyMountainInfo: MountainInfo = MountainInfo()

class selectedData: ObservableObject {
    @Published var selectedHistoryItem: HistoryItem = emptyHistoryItem
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
            if app?.mountainsData?.sevenPeaks?.mountains != nil {
                ForEach(app!.mountainsData!.sevenPeaks!.mountains!) { mountain in

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
            
            if app?.mountainsData?.highest?.mountains != nil {
                ForEach(app!.mountainsData!.highest!.mountains!.filter({h in !app!.mountainsData!.sevenPeaks!.mountains!.contains(where: { m in
                    m.name == h.name
                })})) { mountain in

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
                        
            if app?.mountainsData?.snowLeopardOfRussia?.mountains != nil {
                ForEach(app!.mountainsData!.snowLeopardOfRussia!.mountains!.filter({h in !app!.mountainsData!.sevenPeaks!.mountains!.contains(where: { m in
                    m.name == h.name
                }) && !app!.mountainsData!.highest!.mountains!.contains(where: { m in
                    m.name == h.name
                })})) { mountain in

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
            
            if app?.history.historyItems != nil {
                ForEach(app!.history.historyItems.suffix(25)) { historyItem in
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
            self.app?.history.Refresh()
        }
        .sheet(isPresented: $isShowHistoryDetails) {
            if (selected.selectedHistoryItem == emptyHistoryItem) {
                Text("Loading...")
            } else {
                HistoryDetailsView(item: selected.selectedHistoryItem)
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
