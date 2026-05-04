//
//  Location.swift
//  Geo
//
//  Created by nettrash on 19/06/2024.
//

import Foundation
import CoreLocation

@Observable
class Location: NSObject, @preconcurrency CLLocationManagerDelegate {
    
    var app: GeoAppDelegate? = nil
    var barometer: Barometer? = nil
    var locationManager: CLLocationManager? = nil
    var location: CLLocation? = nil
    var mountainsData: MountainData? = nil
    var closestMountain: MountainInfo? = nil
    var closestMountainDistance: Double? = nil
    var highestMountain: MountainInfo? = nil
    var highestMountainDistance: Double? = nil
    var lastVisit: CLVisit? = nil
    var allowTracking: Bool = true

    private var stepLocation: CLLocation? = nil
    private var trackingStepLocation: CLLocation? = nil
    private let horizontalStep: CGFloat = 1000 //1000m
    private let verticalStep: CGFloat = 50 //50m
    private var lastInfoDate: Date = Date()
    private let trackingStep: TimeInterval = 15 // 15 second
    
    /// Last barometer pressure recorded for step-based history
    private var lastRecordedPressure: Double = 0
    /// Minimum pressure change (kPa) to trigger a barometer-driven history record
    /// ~0.1 kPa ≈ ~8m altitude change
    private let pressureStep: Double = 0.1
    
    func initialize() {
        if (self.locationManager == nil) {
            self.locationManager = CLLocationManager()
            
            self.locationManager!.delegate = self
            self.locationManager!.desiredAccuracy = kCLLocationAccuracyBest
            let status = self.locationManager!.authorizationStatus
            if status == .authorizedAlways || status == .authorizedWhenInUse {
                startLocationMonitor()
            } else {
                self.locationManager!.requestAlwaysAuthorization()
            }
        }
        if (self.mountainsData?.sevenPeaks?.mountains?.count ?? 0) > 0 {
            self.highestMountain = self.mountainsData?.sevenPeaks?.mountains?[0]
        } else {
            self.highestMountain = nil
        }
    }
    
    //Location
    private func startLocationMonitor() {
        self.locationManager?.startUpdatingLocation()
    }
    
    private func stopLocationMonitor() {
        self.locationManager?.stopUpdatingLocation()
    }
        
    //CLLocationManagerDelegate
    @MainActor func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latestLocation = locations.last else { return }
        self.location = latestLocation
        refreshCloserMountain()
        let lastInfoComponents = Calendar.current.dateComponents([.day], from: self.lastInfoDate)
        let infoComponent = Calendar.current.dateComponents([.day], from: Date())
        
        if let step = self.stepLocation {
            if step.distance(from: latestLocation) > self.horizontalStep ||
                abs(step.altitude - latestLocation.altitude) > self.verticalStep ||
                lastInfoComponents.day != infoComponent.day {
                self.stepLocation = latestLocation.copy() as? CLLocation
                refreshData()
            }
        } else {
            self.stepLocation = latestLocation.copy() as? CLLocation
            refreshData()
        }
        
        if self.allowTracking {
            if self.trackingStepLocation == nil {
                self.trackingStepLocation = latestLocation.copy() as? CLLocation
                self.trackingRefresh()
            } else if self.lastInfoDate.addingTimeInterval(self.trackingStep) <= Date() {
                self.trackingStepLocation = latestLocation.copy() as? CLLocation
                self.trackingRefresh()
            }
        }

        // Write combined barometer + GPS data to widget
        pushCombinedDataToWidget()
    }
    
    /// Called by GeoAppDelegate when the barometer produces a new reading.
    /// Uses last known GPS location + fresh barometer data.
    @MainActor func onBarometerUpdated() {
        guard let barometer = self.barometer, barometer.pressure > 0 else { return }
        
        // Always push the latest combined data to the widget
        pushCombinedDataToWidget()
        
        // Check if pressure changed enough to record a CoreData history point
        let pressureDelta = abs(barometer.pressure - lastRecordedPressure)
        if lastRecordedPressure == 0 || pressureDelta >= pressureStep {
            lastRecordedPressure = barometer.pressure
            
            // Record to CoreData history if we have a known location
            if self.location != nil {
                self.stepLocation = self.location?.copy() as? CLLocation
                refreshData()
            }
        }
        
        // Update tracking on every barometer reading (subject to time interval),
        // regardless of pressure step — this keeps the real-time tracking graph
        // showing both barometer and GPS data in parallel.
        if self.allowTracking && self.location != nil {
            self.trackingStepLocation = self.location?.copy() as? CLLocation
            if self.lastInfoDate.addingTimeInterval(self.trackingStep) <= Date() {
                self.trackingRefresh()
            }
        }
    }
    
    /// Writes the latest combined barometer + GPS data to the shared App
    /// Group store, appends it to the rolling buffer for back-fill, and
    /// pushes the same snapshot over WatchConnectivity if a Watch is paired.
    @MainActor private func pushCombinedDataToWidget() {
        let info = InformationToken(
            recordDate: Date(),
            gpsAltitude: self.location?.altitude ?? 0.0,
            gpsSpeed: max(self.location?.speed ?? 0.0, 0.0),
            barPreassure: self.barometer?.pressure ?? 0.0,
            barAltitude: self.barometer?.height ?? 0.0,
            gpsLatitude: self.location?.coordinate.latitude ?? 0.0,
            gpsLongitude: self.location?.coordinate.longitude ?? 0.0
        )
        SharedSnapshotStore.write(info)
        self.app?.connectivity?.sendCurrentSnapshot(info)
        self.app?.reloadWidgetIfNeeded()
    }
    
    @MainActor func refreshData() {
        guard let step = self.stepLocation else {
            self.stepLocation = nil
            return
        }

        let controller = PersistenceController.shared
        let historyItem = HistoryItem(context: controller.container.viewContext)
        historyItem.recordDate = Date()
        historyItem.barometerAltitude = self.barometer?.height ?? 0
        historyItem.barometerPressure = self.barometer?.pressure ?? 0
        historyItem.gpsLatitude = step.coordinate.latitude
        historyItem.gpsLongitude = step.coordinate.longitude
        historyItem.gpsAltitude = step.altitude
        historyItem.gpsVelocity = max(step.speed, 0)

        do {
            try controller.container.viewContext.save()
        } catch {
            let nsError = error as NSError
            AppLog.location.error("Error saving history: \(String(describing: nsError))")
            controller.container.viewContext.rollback()
            return
        }
        // Mark dirty so the next read refreshes; don't trigger a fetch
        // here — the AR view's poll loop will pick it up.
        app?.history.markDirty()
        app?.history.Refresh()
        self.lastInfoDate = Date()
    }
    
    @MainActor func trackingRefresh() {
        guard self.allowTracking,
              let trackingLocation = self.trackingStepLocation else {
            self.trackingStepLocation = nil
            return
        }
        
        app?.history.addTrackingInformation(trackingLocation, self.barometer)
        self.lastInfoDate = Date()
    }
    
    func refreshCloserMountain() {
        guard let loc = self.location else {
            self.closestMountain = nil
            return
        }
        var m: [MountainInfo] = []
        m.append(contentsOf: self.mountainsData?.highest?.mountains ?? [])
        m.append(contentsOf: self.mountainsData?.sevenPeaks?.mountains ?? [])
        m.append(contentsOf: self.mountainsData?.snowLeopardOfRussia?.mountains ?? [])
        if let v = m.min(by: { (a: MountainInfo, b: MountainInfo) -> Bool in
            loc.distance(from: CLLocation(latitude: a.coordinates?.latitude ?? 0, longitude: a.coordinates?.longitude ?? 0)) < loc.distance(from: CLLocation(latitude: b.coordinates?.latitude ?? 0, longitude: b.coordinates?.longitude ?? 0))
        }) {
            self.closestMountain = v
            let distance = loc.distance(from: CLLocation(latitude: v.coordinates?.latitude ?? 0, longitude: v.coordinates?.longitude ?? 0))
            self.closestMountainDistance = distance
            let distanceH = loc.distance(from: CLLocation(latitude: self.highestMountain?.coordinates?.latitude ?? 0, longitude: self.highestMountain?.coordinates?.longitude ?? 0))
            self.highestMountainDistance = distanceH
        } else {
            self.closestMountain = nil
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        if status == .notDetermined { return }
        
        if status == .authorizedAlways || status == .authorizedWhenInUse {
            startLocationMonitor()
        } else {
            if status == .denied {
                stopLocationMonitor()
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        lastVisit = visit;
    }
}
