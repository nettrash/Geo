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
            if self.stepLocation == nil {
                self.stepLocation = CLLocation(latitude: self.location!.coordinate.latitude, longitude: self.location!.coordinate.longitude)
                refreshData()
            } else if self.stepLocation!.distance(from: self.location!) > 100.0 { // > 100 m
                self.stepLocation = CLLocation(latitude: self.location!.coordinate.latitude, longitude: self.location!.coordinate.longitude)
                refreshData()
            }
            //refreshView()
        }
    }
    
    func refreshData() {
        if (self.stepLocation != nil) {
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
