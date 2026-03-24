//
//  GeoAppDelegate.swift
//  Geo
//
//  Created by nettrash on 29/12/2023.
//

import Foundation
import UIKit
import CoreLocation
import WidgetKit
@preconcurrency import BackgroundTasks

class GeoAppDelegate: NSObject, UIApplicationDelegate, ObservableObject {
    
    //Mountains data
    var mountainsData: MountainData? = nil
    
    // Instance of barometer representation.
    var barometer: Barometer?
    
    // Instance of location manager
    var location: Location?
    
    // History
    var history: History = History()
    
    private let backgroundTaskIndentifier_Refresh = "me.nettrash.Geo.background.refresh"
    private var lastWidgetReloadDate: Date = .distantPast
    
    // Initializing main stuctures for the app.
    func initialize() {
        loadMountains()
        
        self.barometer = Barometer()
        self.barometer?.dataUpdated = { [weak self] in
            self?.location?.onBarometerUpdated()
        }
        self.barometer?.Start()
        
        self.location = Location()
        self.location?.app = self
        self.location?.barometer = self.barometer
        self.location?.mountainsData = self.mountainsData
    }
    
    /// Pushes the latest combined data to the widget.
    /// Delegates to Location which owns the unified data write path.
    func pushDataToWidget() {
        guard let userDefaults = UserDefaults(suiteName: "group.me.nettrash.Geo") else { return }
        
        let info = InformationToken(
            recordDate: Date(),
            gpsAltitude: self.location?.location?.altitude ?? 0.0,
            gpsSpeed: max(self.location?.location?.speed ?? 0.0, 0.0),
            barPreassure: self.barometer?.pressure ?? 0.0,
            barAltitude: self.barometer?.height ?? 0.0
        )
        if let encoded = try? JSONEncoder().encode(info) {
            userDefaults.set(encoded, forKey: "ActualInformation")
        }
        
        reloadWidgetIfNeeded()
    }
    
    /// Reload widget timelines at most every 30 seconds to avoid exceeding the system budget.
    func reloadWidgetIfNeeded() {
        guard lastWidgetReloadDate.addingTimeInterval(30) < Date() else { return }
        lastWidgetReloadDate = Date()
        WidgetCenter.shared.reloadTimelines(ofKind: "GEO")
    }
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        
        initialize()
        
        registerBackgroundTasks()
        
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
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        
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
    
    /// Background operation that starts a fresh barometer, waits for a reading,
    /// and pushes updated pressure/altitude data to the widget.
    /// GPS data is preserved from the last known value.
    func BackgroundRefreshOperation() -> Operation {
        return BlockOperation {
            print(">>> BackgroundRefreshOperation")
            
            let barometer = Barometer()
            barometer.Start()
            
            // Give barometer a moment to produce a reading
            Thread.sleep(forTimeInterval: 3)
            
            guard let userDefaults = UserDefaults(suiteName: "group.me.nettrash.Geo") else { return }
            
            // Read the last known GPS data and preserve it; only update barometer fields
            var lastGPSAltitude: Double = 0
            var lastGPSSpeed: Double = 0
            if let data = userDefaults.object(forKey: "ActualInformation") as? Data,
               let previous = try? JSONDecoder().decode(InformationToken.self, from: data) {
                lastGPSAltitude = previous.gpsAltitude
                lastGPSSpeed = previous.gpsSpeed
            }
            
            let info = InformationToken(
                recordDate: Date(),
                gpsAltitude: lastGPSAltitude,
                gpsSpeed: lastGPSSpeed,
                barPreassure: barometer.pressure,
                barAltitude: barometer.height
            )
            if let encoded = try? JSONEncoder().encode(info) {
                userDefaults.set(encoded, forKey: "ActualInformation")
            }
            
            barometer.Stop()
            
            WidgetCenter.shared.reloadTimelines(ofKind: "GEO")
            
            print("<<< BackgroundRefreshOperation")
        }
    }
}
