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
                //refreshData()
            } else if self.stepLocation!.distance(from: self.location!) > 100.0 { // > 100 m
                self.stepLocation = CLLocation(latitude: self.location!.coordinate.latitude, longitude: self.location!.coordinate.longitude)
                //refreshData()
            }
            //refreshView()
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
