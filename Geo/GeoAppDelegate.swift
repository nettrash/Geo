//
//  GeoAppDelegate.swift
//  Geo
//
//  Created by nettrash on 29/12/2023.
//

import Foundation
import UIKit
import CoreData
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

    /// WatchConnectivity bridge — `nil` on devices that don't support it.
    var connectivity: PhoneConnectivityManager?

    private let backgroundTaskIndentifier_Refresh = "me.nettrash.Geo.background.refresh"
    private let backgroundTaskIdentifier_AppRefresh = "me.nettrash.Geo.background.apprefresh"
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

        // Spin up WatchConnectivity. The manager is non-isolated and
        // safe to construct from any thread; we set our own delegate
        // pointer back into the manager so it can route inbound Watch
        // samples into the data model.
        self.connectivity = PhoneConnectivityManager()
        self.connectivity?.app = self

        // Pull anything Widget / Watch recorded while we were suspended back into
        // the main app: rehydrate the in-memory barometer with the most recent
        // sample and persist any background-captured reading into CoreData history.
        restoreFromSharedStorage()
    }

    /// Pushes the latest combined data to the widget.
    /// Delegates to Location which owns the unified data write path.
    func pushDataToWidget() {
        let info = InformationToken(
            recordDate: Date(),
            gpsAltitude: self.location?.location?.altitude ?? 0.0,
            gpsSpeed: max(self.location?.location?.speed ?? 0.0, 0.0),
            barPreassure: self.barometer?.pressure ?? 0.0,
            barAltitude: self.barometer?.height ?? 0.0,
            gpsLatitude: self.location?.location?.coordinate.latitude ?? 0.0,
            gpsLongitude: self.location?.location?.coordinate.longitude ?? 0.0
        )
        SharedSnapshotStore.write(info)
        connectivity?.sendCurrentSnapshot(info)
        reloadWidgetIfNeeded()
    }

    /// Pull anything the Widget / Watch wrote while the main app was
    /// suspended back into the active session:
    ///
    /// 1. Rehydrate `barometer.pressure / .height / .everest` from the
    ///    most recent snapshot if the live sensor hasn't produced a
    ///    value yet.
    /// 2. Drain the rolling buffer of background snapshots into the
    ///    CoreData history. Each insert is deduped by `recordDate` so
    ///    repeated calls are idempotent.
    func restoreFromSharedStorage() {
        // 1. Rehydrate barometer if the live sensor hasn't produced a
        //    value yet — pure in-memory work, fine on the launch path.
        if let current = SharedSnapshotStore.readCurrent(),
           let bar = self.barometer,
           bar.pressure == 0,
           current.barPreassure > 0 {
            bar.pressure = current.barPreassure
            bar.height = current.barAltitude
            bar.everest = current.barAltitude / 8848
        }

        // 2. Off-load the buffer drain. CloudKit's sync engine
        //    routinely holds a SQLite read lock; if we save on the
        //    main `viewContext` the post-save WAL checkpoint loops on
        //    "database busy" and stalls the main thread, blocking the
        //    UI from appearing. Routing the work through a background
        //    context lets CoreData serialise it without blocking
        //    launch. The viewContext picks up the inserts via
        //    `automaticallyMergesChangesFromParent`.
        let buffered = SharedSnapshotStore.readBuffer()
        guard !buffered.isEmpty else { return }

        let history = self.history
        DispatchQueue.global(qos: .utility).async {
            let context = PersistenceController.shared.container.newBackgroundContext()
            context.perform {
                var inserted = 0
                for token in buffered where token.barPreassure > 0 {
                    let request: NSFetchRequest<HistoryItem> = HistoryItem.fetchRequest()
                    request.predicate = NSPredicate(format: "recordDate == %@", token.recordDate as NSDate)
                    request.fetchLimit = 1
                    if let count = try? context.count(for: request), count > 0 { continue }

                    let item = HistoryItem(context: context)
                    item.recordDate = token.recordDate
                    item.barometerPressure = token.barPreassure
                    item.barometerAltitude = token.barAltitude
                    item.gpsAltitude = token.gpsAltitude
                    item.gpsVelocity = token.gpsSpeed
                    item.gpsLatitude = token.gpsLatitude
                    item.gpsLongitude = token.gpsLongitude
                    inserted += 1
                }

                if inserted > 0 {
                    do {
                        try context.save()
                        AppLog.app.debug("Backfilled \(inserted, privacy: .public) buffered samples")
                    } catch {
                        context.rollback()
                        AppLog.app.error("Failed to persist buffered samples: \(String(describing: error))")
                        // Leave the buffer in place so the next launch
                        // can retry.
                        return
                    }
                }

                // Mark the cache stale so the next history view
                // triggers a refresh on its own schedule.
                DispatchQueue.main.async {
                    history.markDirty()
                }

                SharedSnapshotStore.clearBuffer()
            }
        }
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
        // Push latest data to widget immediately before going to background
        pushDataToWidget()
        
        // Force an immediate widget reload (bypass throttle)
        lastWidgetReloadDate = .distantPast
        reloadWidgetIfNeeded()
        
        // Schedule background tasks for periodic refresh
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
    
    // Marked `nonisolated` because `BGTaskScheduler` invokes the
    // registered handler closures on a background dispatch queue.
    // Under Swift 6, `GeoAppDelegate` is implicitly `@MainActor`
    // (via `UIApplicationDelegate`), so calling MainActor-isolated
    // methods from the BG closure trips a runtime isolation check
    // (SIGTRAP / brk 1 in libdispatch via libswift_Concurrency).
    // The handlers below only touch `BGTaskScheduler` and spin work
    // off into `Task.detached`, so they're safe to run off-main.
    nonisolated func registerBackgroundTasks() {
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskIndentifier_Refresh, using: nil) { task in
                // Conditional cast: if the system ever hands us a
                // task of an unexpected concrete type, log it and
                // mark the task complete rather than crashing.
                guard let processingTask = task as? BGProcessingTask else {
                    AppLog.background.error("Unexpected task type for processing identifier: \(type(of: task))")
                    task.setTaskCompleted(success: false)
                    return
                }
                self.handleBackgroundProcessing(task: processingTask)
            }
            BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskIdentifier_AppRefresh, using: nil) { task in
                guard let refreshTask = task as? BGAppRefreshTask else {
                    AppLog.background.error("Unexpected task type for app-refresh identifier: \(type(of: task))")
                    task.setTaskCompleted(success: false)
                    return
                }
                self.handleAppRefresh(task: refreshTask)
            }
        }
    }

    nonisolated func scheduleBackgroundProcessing() {
        // Schedule the heavy processing task
        let processingRequest = BGProcessingTaskRequest(identifier: backgroundTaskIndentifier_Refresh)
        processingRequest.requiresNetworkConnectivity = false
        processingRequest.requiresExternalPower = false
        processingRequest.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        
        do {
            try BGTaskScheduler.shared.submit(processingRequest)
        } catch {
            AppLog.background.error("Could not schedule background processing: \(String(describing: error))")
        }

        // Schedule the lightweight app refresh task (~every 15 min)
        let refreshRequest = BGAppRefreshTaskRequest(identifier: backgroundTaskIdentifier_AppRefresh)
        refreshRequest.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        do {
            try BGTaskScheduler.shared.submit(refreshRequest)
        } catch {
            AppLog.background.error("Could not schedule app refresh: \(String(describing: error))")
        }
    }
    
    nonisolated func handleBackgroundProcessing(task: BGProcessingTask) {
        scheduleBackgroundProcessing()
        runBackgroundRefresh(task: task)
    }

    nonisolated func handleAppRefresh(task: BGAppRefreshTask) {
        // Reschedule immediately so the next one is queued
        scheduleBackgroundProcessing()
        runBackgroundRefresh(task: task)
    }

    /// Drives the background refresh on a `Task` so the OperationQueue's
    /// main thread stays free. Uses `withTaskCancellationHandler` so the
    /// system's expiration callback can cancel us cleanly.
    nonisolated private func runBackgroundRefresh(task: BGTask) {
        let work = Task.detached(priority: .utility) {
            await Self.captureBarometerSampleAndPersist()
        }
        task.expirationHandler = {
            work.cancel()
        }
        Task {
            _ = await work.value
            task.setTaskCompleted(success: !work.isCancelled)
        }
    }

    /// Background-safe sample capture. Lives off the main thread so it
    /// doesn't block UI-related operations queued on `OperationQueue.main`.
    private static func captureBarometerSampleAndPersist() async {
        AppLog.background.debug("background refresh start")
        let barometer = Barometer()
        barometer.Start()

        // Give the barometer time to deliver a sample without blocking a
        // thread. `Task.sleep` is cancellation-aware, so the system's
        // expiration handler will short-circuit this cleanly.
        try? await Task.sleep(nanoseconds: 3_000_000_000)

        let previous = SharedSnapshotStore.readCurrent()

        let info = InformationToken(
            recordDate: Date(),
            gpsAltitude: previous?.gpsAltitude ?? 0,
            gpsSpeed: previous?.gpsSpeed ?? 0,
            barPreassure: barometer.pressure,
            barAltitude: barometer.height,
            gpsLatitude: previous?.gpsLatitude ?? 0,
            gpsLongitude: previous?.gpsLongitude ?? 0
        )
        SharedSnapshotStore.write(info)
        barometer.Stop()

        // WidgetKit already de-duplicates closely-spaced timeline
        // reloads internally, so we just request one and let the
        // system decide.
        WidgetCenter.shared.reloadTimelines(ofKind: "GEO")
        AppLog.background.debug("background refresh done")
    }
}
