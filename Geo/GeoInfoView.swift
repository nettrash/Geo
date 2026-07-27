//
//  GeoInfoView.swift
//  Geo
//
//  Created by nettrash on 18/06/2024.
//

import SwiftUI

struct GeoInfoView: View {
    @State var app: GeoAppDelegate?
    @Environment(\.scenePhase) private var scenePhase
    /// Whether the Info tab is currently on-screen, so the scene-phase
    /// handler only (re)starts the compass when this tab is actually showing.
    @State private var isOnScreen = false
    /// Published up from the Magnetic Conditions card so the peak-bearing rows
    /// below it can add the G3+ heading caption without a second fetch or a
    /// second copy of the state.
    @State private var magnetic: MagneticConditions?

    var body: some View {
        ZStack(content: {
            Image("GeoBig")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .opacity(0.02)
                ScrollView {
                    BarometerInformationView(barometer: app?.barometer, history: app?.history)
                        .onAppear { app?.history.refreshIfNeeded() }

                    SatelliteInformationView(location: app?.location)
                        .onAppear(perform: {
                            app?.location?.initialize()
                        })

                    SolarInformationView(location: app?.location)

                    // Sibling of the Sun card — both answer "what is the sky
                    // doing here" — and deliberately above the mountain cards,
                    // where its compass caption lands. Not next to the
                    // barometer card, whose own storm warning is a different
                    // storm entirely.
                    MagneticInformationView(location: app?.location,
                                            weather: app?.spaceWeather) { magnetic = $0 }
                        .onAppear { Task { await app?.spaceWeather?.refreshIfStale() } }

                    ClosestMountainInformationView(location: app?.location,
                                                   motion: app?.deviceMotion,
                                                   magnetic: magnetic)

                    HighestMountainInformationView(location: app?.location,
                                                   motion: app?.deviceMotion,
                                                   magnetic: magnetic)

                    OfflinePackCard(manager: app?.offlinePack, location: app?.location)

                    DataSourcesCredit()
                }
                // Run the compass only while the Info tab is visible AND the
                // scene is active (low-power, AR-free peak direction finder).
                // `onDisappear` doesn't fire on background, so also stop on
                // scene-phase change — mirroring GeoNatureView's AR gating.
                .onAppear {
                    isOnScreen = true
                    // Heading-only: the bearing arrow needs `heading`, not the
                    // 30 Hz pitch/roll attitude stream (AR-only).
                    if scenePhase == .active { app?.deviceMotion?.start(includeAttitude: false) }
                    // The Satellite card below is the app's ONLY high-fidelity
                    // GPS consumer (6 dp coordinates, live speed), so full
                    // accuracy is bought only while this tab is showing.
                    app?.location?.setPrecision(high: true)
                }
                .onDisappear {
                    isOnScreen = false
                    app?.deviceMotion?.stop()
                    app?.location?.setPrecision(high: false)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard isOnScreen else { return }
                    if newPhase == .active { app?.deviceMotion?.start(includeAttitude: false) } else { app?.deviceMotion?.stop() }
                    app?.location?.setPrecision(high: newPhase == .active)
                }
        })
    }
}

/// Data-source attribution footer for the Info tab. Credits the public data
/// providers the app depends on (fair-use / attribution courtesy for
/// Open-Meteo and OpenStreetMap, plus Apple's frameworks).
private struct DataSourcesCredit: View {
    var body: some View {
        VStack(spacing: 3) {
            Text("Data sources")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Text("Peaks © OpenStreetMap contributors (Overpass)")
            Text("Elevation by Open-Meteo")
            Text("Space weather by NOAA SWPC (public domain)")
            Text("Magnetic coordinates from IGRF-14 and AACGM-v2")
            Text("Maps by Apple · AR by ARKit")
        }
        .font(.system(size: 11, design: .rounded))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

#Preview {
    GeoInfoView(app: nil)
}
