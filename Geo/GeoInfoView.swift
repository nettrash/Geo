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

                    ClosestMountainInformationView(location: app?.location, motion: app?.deviceMotion)

                    HighestMountainInformationView(location: app?.location, motion: app?.deviceMotion)
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
                }
                .onDisappear {
                    isOnScreen = false
                    app?.deviceMotion?.stop()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard isOnScreen else { return }
                    if newPhase == .active { app?.deviceMotion?.start(includeAttitude: false) }
                    else { app?.deviceMotion?.stop() }
                }
        })
    }
}

#Preview {
    GeoInfoView(app: nil)
}
