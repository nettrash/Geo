//
//  PermissionsMonitor.swift
//  Geo
//
//  Centralised observation of the iOS permissions Geo depends on so
//  the UI can surface a single, consistent "we can't do X because the
//  user denied Y" message instead of silently failing.
//
//  Why this exists
//  ---------------
//  The camera path already shows a graceful permission alert in
//  `GeoNatureView`. Location and motion didn't — if the user denies
//  either, the maps / graphs / barometer-driven features just go
//  blank. This class tracks the live authorization status for both
//  sensors and exposes flags that `MainView` consumes to drop a
//  banner with an "Open Settings" button.
//

import Foundation
import CoreLocation
import CoreMotion

@MainActor
final class PermissionsMonitor: ObservableObject {

    /// `true` when the user has explicitly denied / restricted access
    /// to *any* of the sensors Geo needs. Drives a one-shot in-app
    /// banner.
    @Published var locationDenied: Bool = false
    @Published var motionDenied: Bool = false

    /// Last refreshed authorisation status — useful for diagnostics.
    @Published private(set) var locationAuthorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var motionAuthorization: CMAuthorizationStatus = .notDetermined

    /// Convenience for the UI: any sensor we care about is denied.
    var hasAnyDenial: Bool { locationDenied || motionDenied }

    /// Refresh from the system. Cheap to call — both APIs return
    /// cached values. Re-poll whenever the app becomes active so a
    /// user who toggles a switch in Settings sees the banner clear.
    func refresh() {
        let loc: CLAuthorizationStatus
        if #available(iOS 14.0, *) {
            loc = CLLocationManager().authorizationStatus
        } else {
            loc = CLLocationManager.authorizationStatus()
        }
        locationAuthorization = loc
        locationDenied = (loc == .denied || loc == .restricted)

        let motion = CMAltimeter.authorizationStatus()
        motionAuthorization = motion
        // Treat both `.denied` and `.restricted` as "user can't use
        // these features". `.notDetermined` is *not* a denial — the
        // first sensor read will trigger the system prompt.
        motionDenied = (motion == .denied || motion == .restricted)
    }
}
