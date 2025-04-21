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
    private let trackingStep: TimeInterval = 60 // 1 minute
    
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
        if locations.count > 0 {
            self.location = locations[locations.count - 1]
            refreshCloserMountain()
            let lastInfoComponents = Calendar.current.dateComponents([.day], from: self.lastInfoDate)
            let infoComponent = Calendar.current.dateComponents([.day], from: Date())
            
            if self.stepLocation == nil {
                self.stepLocation = self.location?.copy() as? CLLocation
                refreshData()
            } else if self.stepLocation!.distance(from: self.location!) > self.horizontalStep ||
                        abs(self.stepLocation!.altitude - self.location!.altitude) > self.verticalStep ||
                        lastInfoComponents.day != infoComponent.day {
                self.stepLocation = self.location?.copy() as? CLLocation
                refreshData()
            }
            
            if self.allowTracking {
                if self.trackingStepLocation == nil {
                    self.trackingStepLocation = self.location?.copy() as? CLLocation
                    self.trackingRefresh()
                } else if self.lastInfoDate.addingTimeInterval(self.trackingStep) <= Date() {
                    self.trackingStepLocation = self.location?.copy() as? CLLocation
                    self.trackingRefresh()
                }
            }

            if let userDefaults = UserDefaults(suiteName: "group.me.nettrash.Geo") {
                let info = InformationToken(recordDate: Date(), gpsAltitude: self.location!.altitude, gpsSpeed: self.location!.speed, barPreassure: self.barometer!.pressure, barAltitude: self.barometer!.height)
                if let encoded = try? JSONEncoder().encode(info) {
                    userDefaults.set(encoded, forKey: "ActualInformation")
                }
            }
        }
    }
    
    @MainActor func refreshData() {
        if (self.stepLocation != nil && (self.barometer?.pressure ?? 0) > 0) {
            let controller = PersistenceController.shared
            let historyItem = HistoryItem(context: controller.container.viewContext)
            historyItem.recordDate = Date()
            historyItem.barometerAltitude = self.barometer!.height
            historyItem.barometerPressure = self.barometer!.pressure
            historyItem.gpsLatitude = self.stepLocation!.coordinate.latitude
            historyItem.gpsLongitude = self.stepLocation!.coordinate.longitude
            historyItem.gpsAltitude = self.stepLocation!.altitude
            historyItem.gpsVelocity = self.stepLocation!.speed
            
            do {
                try controller.container.viewContext.save()
            } catch {
                let nsError = error as NSError
                fatalError("Unresolved error \(nsError), \(nsError.userInfo)")
            }
            app?.history.Refresh()
            self.lastInfoDate = Date()
        } else {
            self.stepLocation = nil
        }
    }
    
    @MainActor func trackingRefresh() {
        if (self.allowTracking && self.trackingStepLocation != nil && (self.barometer?.pressure ?? 0) > 0) {
            
            app?.history.addTrackingInformation(self.trackingStepLocation!, self.barometer!)
            self.lastInfoDate = Date()

        } else {
            self.trackingStepLocation = nil
        }
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
