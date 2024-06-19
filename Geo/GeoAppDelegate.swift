//
//  GeoAppDelegate.swift
//  Geo
//
//  Created by nettrash on 29/12/2023.
//

import Foundation
import UIKit
import CoreLocation

class GeoAppDelegate: NSObject, UIApplicationDelegate, ObservableObject {

    // Instance of barometer representation.
    var barometer: Barometer?
    
    // Instance of location manager
    var location: Location?
    
    // Initializing main stuctures for the app.
    func initialize() {
        self.barometer = Barometer()
        self.barometer?.Start()
    
        self.location = Location();
    }
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        initialize();
        
        return true;
    }
    
}
