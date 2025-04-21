//
//  GeoAppDelegate.swift
//  Geo
//
//  Created by nettrash on 29/12/2023.
//

import Foundation
import UIKit
import CoreLocation
@preconcurrency import BackgroundTasks
import WatchConnectivity

class GeoAppDelegate: NSObject, UIApplicationDelegate, ObservableObject, @preconcurrency WCSessionDelegate {

    //Mountains data
    var mountainsData: MountainData? = nil
    
    // Instance of barometer representation.
    var barometer: Barometer?
    
    // Instance of location manager
    var location: Location?
    
    // History
    var history: History = History()

    private let backgroundTaskIndentifier_Refresh = "me.nettrash.Geo.background.refresh"
    
    // WCSession
    var wcsession: WCSession? = nil
    
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
        
        initialize()
        
        registerBackgroundTasks()
        
        /*if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }*/

        return true;
    }
        
    func applicationWillResignActive(_ application: UIApplication) {
        self.scheduleBackgroundProcessing()
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
    
    func registerBackgroundTasks() {
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskIndentifier_Refresh, using: nil) { task in
                self.handleBackgroundProcessing(task: task as! BGProcessingTask)
            }
        }
    }
    
    func scheduleBackgroundProcessing() {
        let request = BGProcessingTaskRequest(identifier: backgroundTaskIndentifier_Refresh)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 10 * 60) //seconds

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Could not schedule app refresh: \(error)")
        }
    }
    
    func handleBackgroundProcessing(task: BGProcessingTask) {
        scheduleBackgroundProcessing()

        let operation = BackgroundRefreshOperation()

        task.expirationHandler = {
            operation.cancel()
        }

        operation.completionBlock = {
            task.setTaskCompleted(success: !operation.isCancelled)
        }

        OperationQueue.main.addOperation(operation)
    }
    
    func BackgroundRefreshOperation() -> Operation {
        return BlockOperation { [weak self] in
            guard let self else { return }
            
            print(">>> BackgroundRefreshOperation")
            
            let barometer = Barometer()
            barometer.Start()
            
            let location = Location()
            location.allowTracking = false
            location.app = self
            location.barometer = barometer
            location.mountainsData = MountainData()
            
            sleep(15)
            
            if let userDefaults = UserDefaults(suiteName: "group.me.nettrash.Geo") {
                let info = InformationToken(recordDate: Date(), gpsAltitude: location.location!.altitude, gpsSpeed: location.location!.speed, barPreassure: barometer.pressure, barAltitude: barometer.height)
                if let encoded = try? JSONEncoder().encode(info) {
                    userDefaults.set(encoded, forKey: "ActualInformation")
                }
            }

            print("<<< BackgroundRefreshOperation")
        }
    }
    
    //WCSessionDelegate
    
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        print("WCSession activationDidCompleteWith activationState: \(activationState)")
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        
    }

    func sessionDidDeactivate(_ session: WCSession) {
        
    }
    
    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        if self.mountainsData == nil {
            loadMountains()
        }
        
        if self.barometer == nil {
            self.barometer = Barometer()
            self.barometer?.Start()
        }
        
        if self.location == nil {
            self.location = Location()
            self.location?.app = self
            self.location?.barometer = self.barometer
            self.location?.mountainsData = self.mountainsData
        }
        
        self.location?.locationManager?.startMonitoringVisits()
    }
}
