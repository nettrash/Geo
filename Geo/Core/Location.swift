//
//  Location.swift
//  Geo
//
//  Created by nettrash on 19/06/2024.
//

import Foundation
import CoreLocation

@Observable
class Location: NSObject, CLLocationManagerDelegate {
    
    var barometer: Barometer? = nil
    var locationManager: CLLocationManager? = nil
    var location: CLLocation? = nil
    var mountainsData: MountainData? = nil
    var closestMountain: MountainInfo? = nil
    var closestMountainDistance: Double? = nil
    var highestMountain: MountainInfo? = nil
    var highestMountainDistance: Double? = nil

    private var stepLocation: CLLocation? = nil
    
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
        if (self.mountainsData?.highest?.mountains?.count ?? 0) > 0 {
            self.highestMountain = self.mountainsData?.highest?.mountains?[0]
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
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if locations.count > 0 {
            self.location = locations[locations.count - 1]
            refreshCloserMountain()
            if self.stepLocation == nil {
                self.stepLocation = self.location!.copy() as! CLLocation
                refreshData()
            } else if self.stepLocation!.distance(from: self.location!) > 100.0 || // > 100 m
                        abs(self.stepLocation!.altitude - self.location!.altitude) > 10.0 { // > 10 m
                self.stepLocation = self.location!.copy() as! CLLocation
                refreshData()
            }
            //refreshView()
        }
    }
    
    func refreshData() {
        if (self.stepLocation != nil && self.barometer!.pressure > 0) {
            let controller = PersistenceController.shared
            let historyItem = HistoryItem(context: controller.container.viewContext)
            historyItem.recordDate = Date()
            if (self.barometer != nil) {
                historyItem.barometerAltitude = self.barometer!.height
                historyItem.barometerPressure = self.barometer!.pressure
            }
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
        } else {
            self.stepLocation = nil
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
                //let alert = UIAlertController(title: NSLocalizedString("Location", comment: ""), message: NSLocalizedString("The lack of access to the location makes some of the functions of the application unusable", comment: ""), preferredStyle: UIAlertController.Style.actionSheet)
                //alert.addAction(UIAlertAction(title: NSLocalizedString("Continue", comment: ""), style: UIAlertAction.Style.cancel, handler: { (_ action: UIAlertAction) in
                //alert.dismiss(animated: true, completion: nil)
                //}))
                //self.show(alert, sender: nil)
            }
        }
    }
}
