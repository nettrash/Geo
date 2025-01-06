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

    //Mountains data
    var mountainsData: MountainData? = nil
    
    // Instance of barometer representation.
    var barometer: Barometer?
    
    // Instance of location manager
    var location: Location?
    
    // History
    var history: History = History()
    
    // Initializing main stuctures for the app.
    func initialize() {
        loadMountains()
        
        self.barometer = Barometer()
        self.barometer?.Start()
        
        self.location = Location()
        self.location?.app = self
        self.location?.barometer = self.barometer
        self.location?.mountainsData = self.mountainsData
    }
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        initialize();
        
        return true;
    }
    
    private func loadMountains() {
        do {
            guard let listPath = Bundle.main.path(forResource: "list", ofType: "json") else {
                return
            }
            let listUrl = URL(fileURLWithPath: listPath)
            guard let jsonData = try? Data(contentsOf: listUrl) else {
                return
            }
            let decoder = JSONDecoder()
            self.mountainsData = try decoder.decode(MountainData.self, from: jsonData)
        }
        catch {
            self.mountainsData = nil
        }
    }

}
