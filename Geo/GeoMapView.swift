//
//  GeoMapView.swift
//  Geo
//
//  Created by nettrash on 18/06/2024.
//

import SwiftUI
import MapKit

struct GeoMapView: View {
    
    @State var cameraPosition = MapCameraPosition.userLocation(followsHeading: false, fallback: MapCameraPosition.automatic)
    
    @State var app: GeoAppDelegate?
    
    @State private var isShowDetails: Bool = false
    @State private var isHistorySelected: Bool = false
    @State private var historySelected: HistoryItem? = nil
    @State private var mountainSelected: MountainInfo? = nil
    
    private let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter
        }()

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
                                mountainSelected = mountain
                                isHistorySelected = false
                                isShowDetails = true
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
                                mountainSelected = mountain
                                isHistorySelected = false
                                isShowDetails = true
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
                                mountainSelected = mountain
                                isHistorySelected = false
                                isShowDetails = true
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
                                historySelected = historyItem
                                isHistorySelected = true
                                isShowDetails = true
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
        .sheet(isPresented: $isShowDetails) {
            if isHistorySelected {
                if historySelected != nil {
                    HistoryDetailsView(item: historySelected)
                } else {
                    Text("Loading...")
                }
            } else {
                if mountainSelected != nil {
                    MountainDetailsView(mountain: mountainSelected)
                } else {
                    Text("Loading...")
                }
            }
        }
    }
}

#Preview {
    GeoMapView(app: GeoAppDelegate())
}
