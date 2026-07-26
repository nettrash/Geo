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
import UserNotifications
@preconcurrency import BackgroundTasks

class GeoAppDelegate: NSObject, UIApplicationDelegate, ObservableObject {

    // Mountains data
    var mountainsData: MountainData?

    // Instance of barometer representation.
    var barometer: Barometer?

    // Instance of location manager
    var location: Location?

    // Compass / device-heading source for the peak-bearing arrows. Owned
    // here (like barometer/location) and passed to the Info views so only
    // the small bearing row observes its frequent heading updates — not the
    // whole Info tab. Started/stopped by the Info view's lifecycle.
    var deviceMotion: DeviceMotionManager?

    // History
    var history: History = History()

    // Trip Recorder (M5c) — recording state + saved-trip list for the Stat tab.
    var tripRecorder: TripRecorder?

    // Summit log — logged ascents (auto-detect arrival at a known peak).
    var summitLog: SummitLogStore?

    // Offline expedition pack — pre-cached area (OSM peaks + terrain DEM)
    // so the AR peaks/skyline keep working on a no-signal summit. Seeds the
    // live peak + elevation caches from the saved packs at launch.
    var offlinePack: OfflinePackManager?

    // Magnetic Conditions — the planetary Kp index from NOAA SWPC plus the
    // bundled magnetic-coordinate grid. Held here so the Info card, the Info
    // tab and the scene-phase refresh all share one cache and one fetch gate.
    // The request carries nothing about the user, and Phase 1 does no
    // background work at all: it refreshes only while the app is in front.
    var spaceWeather: SpaceWeatherService?

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

        self.deviceMotion = DeviceMotionManager()

        self.tripRecorder = TripRecorder(history: self.history)
        self.summitLog = SummitLogStore(history: self.history)

        // Offline expedition pack — loads saved packs and seeds the live
        // peak/elevation caches so a no-signal launch over a cached area
        // still draws the AR skyline. `location` feeds "download current area".
        self.offlinePack = OfflinePackManager()
        self.offlinePack?.location = self.location

        // Magnetic Conditions. Constructing the actor does no I/O and issues
        // no request — the cache and the correction grid load lazily on first
        // touch, and the fetch is gated to one Kp bin (3 h).
        self.spaceWeather = SpaceWeatherService.shared

        // Spin up WatchConnectivity. The manager is non-isolated and
        // safe to construct from any thread; we set our own delegate
        // pointer back into the manager so it can route inbound Watch
        // samples into the data model.
        self.connectivity = PhoneConnectivityManager()
        self.connectivity?.app = self

        // Ask once for permission to deliver the local storm-warning
        // notification (M5a). Degrades silently if denied — the BGTask
        // path checks authorization before posting.
        requestNotificationAuthorizationIfNeeded()

        // Pull anything Widget / Watch recorded while we were suspended back into
        // the main app: rehydrate the in-memory barometer with the most recent
        // sample and persist any background-captured reading into CoreData history.
        restoreFromSharedStorage()
    }

    /// Pushes the latest combined data to the widget.
    /// Delegates to Location which owns the unified data write path.
    func pushDataToWidget() {
        // Carry the last known GPS altitude / coords forward when there's no
        // live fix, instead of writing a 0 m / null-island sentinel. A
        // fabricated 0 m altitude mixed into the storm-tendency de-trend (which
        // corrects each sample to its altitude) injects a large artificial
        // pressure step; a genuine 0 m reading is fine because a real fix
        // populates `loc?.altitude` (so we only substitute when there's NO fix).
        let previous = SharedSnapshotStore.readCurrent()
        let loc = self.location?.location
        let info = InformationToken(
            recordDate: Date(),
            gpsAltitude: loc?.altitude ?? previous?.gpsAltitude ?? 0.0,
            gpsSpeed: max(loc?.speed ?? previous?.gpsSpeed ?? 0.0, 0.0),
            barPreassure: self.barometer?.pressure ?? 0.0,
            barAltitude: self.barometer?.height ?? 0.0,
            gpsLatitude: loc?.coordinate.latitude ?? previous?.gpsLatitude ?? 0.0,
            gpsLongitude: loc?.coordinate.longitude ?? previous?.gpsLongitude ?? 0.0
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
            bar.everest = current.barAltitude / Atmosphere.everestHeightM
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

    /// Request authorization for the local storm-warning notification.
    /// Marked `nonisolated` so it's callable from any context; the
    /// completion handler only logs, so it's thread-agnostic. Calling
    /// this when the user has already decided is a harmless no-op — iOS
    /// only surfaces the prompt while the status is `.notDetermined`.
    nonisolated func requestNotificationAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                AppLog.app.error("Notification authorization error: \(String(describing: error))")
            }
        }
    }

    /// Reload widget timelines at most every 30 seconds to avoid exceeding the system budget.
    func reloadWidgetIfNeeded() {
        guard lastWidgetReloadDate.addingTimeInterval(30) < Date() else { return }
        lastWidgetReloadDate = Date()
        WidgetCenter.shared.reloadTimelines(ofKind: "GEO")
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {

        initialize()

        registerBackgroundTasks()

        return true
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
        } catch {
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
        // No network required, deliberately — this task exists to capture a
        // barometer sample, which is exactly what a user needs on a no-signal
        // summit. Nothing that wants the network may ever be hung off it:
        // flipping this to `true` so the Kp fetch could ride along would stop
        // the sample capture on precisely the devices the capture is for. The
        // one background network call rides the app-refresh task below.
        processingRequest.requiresNetworkConnectivity = false
        processingRequest.requiresExternalPower = false
        processingRequest.earliestBeginDate = Date(timeIntervalSinceNow: 60)

        do {
            try BGTaskScheduler.shared.submit(processingRequest)
        } catch {
            AppLog.background.error("Could not schedule background processing: \(String(describing: error))")
        }

        // Schedule the lightweight app refresh task (~every 15 min). This is
        // the only background path allowed to reach the network, and the
        // aurora check that rides it stays a no-op until the user opts in.
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
        runBackgroundRefresh(task: task, checkingAuroraAlert: true)
    }

    /// Drives the background refresh on a `Task` so the OperationQueue's
    /// main thread stays free. Uses `withTaskCancellationHandler` so the
    /// system's expiration callback can cancel us cleanly.
    ///
    /// `checkingAuroraAlert` is true on the `BGAppRefreshTask` path and only
    /// there. The processing task sets `requiresNetworkConnectivity = false`
    /// on purpose so the barometer capture survives a no-signal summit, so
    /// putting the Kp fetch on it would mean either flipping that flag — a
    /// real offline regression for the feature that task exists for — or
    /// issuing a request that fails on exactly the devices we scheduled it
    /// for. The app-refresh task is the one the system already only runs when
    /// it is willing to let us use the network.
    nonisolated private func runBackgroundRefresh(task: BGTask,
                                                  checkingAuroraAlert: Bool = false) {
        let work = Task.detached(priority: .utility) {
            await Self.captureBarometerSampleAndPersist()
            if checkingAuroraAlert {
                await Self.evaluateAuroraAlert()
            }
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

        // `try?` swallows the sleep's `CancellationError`, so if the BGTask
        // expired during the wait we'd otherwise carry on. Bail before
        // writing a (possibly empty) snapshot, touching CoreData, or posting
        // a notification after the system has told us to stop.
        guard !Task.isCancelled else {
            barometer.Stop()
            return
        }

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

        // Pressure-trend storm warning (M5a): classify the de-trended
        // 3-hour tendency and, if it crosses the storm threshold, post a
        // local notification. Best-effort and failure-tolerant — never
        // blocks the sample write.
        await evaluateStormWarning(latest: info)

        // WidgetKit already de-duplicates closely-spaced timeline
        // reloads internally, so we just request one and let the
        // system decide.
        WidgetCenter.shared.reloadTimelines(ofKind: "GEO")
        AppLog.background.debug("background refresh done")
    }

    // MARK: - Storm warning (M5a)

    /// App-group key holding the last time a storm notification fired,
    /// used to enforce the cooldown across BGTask invocations / launches.
    private static let stormLastNotifiedKey = "StormWarningLastNotifiedAt"

    /// Assemble the trailing 3-hour sample set (recent CoreData history +
    /// not-yet-drained buffered background snapshots + the just-captured
    /// reading), run the shared `StormWarning` fit, and act on the result.
    private static func evaluateStormWarning(latest: InformationToken) async {
        let now = Date()
        let windowStart = now.addingTimeInterval(-StormWarning.windowHours * 3600)

        // CoreData — we're off the main thread here, so use a private
        // background context. The fetch runs on the context's own queue
        // and returns value-typed samples, so nothing actor-isolated
        // crosses the `perform` boundary.
        let context = PersistenceController.shared.container.newBackgroundContext()
        let coreDataSamples: [PressureSample] = await context.perform {
            let request: NSFetchRequest<HistoryItem> = HistoryItem.fetchRequest()
            request.predicate = NSPredicate(
                format: "recordDate >= %@ and barometerPressure > 0", windowStart as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(keyPath: \HistoryItem.recordDate, ascending: true)]
            let rows = (try? context.fetch(request)) ?? []
            return rows.compactMap { row -> PressureSample? in
                guard let rd = row.recordDate else { return nil }
                return PressureSample(date: rd, pressureKPa: row.barometerPressure, altitudeM: row.gpsAltitude)
            }
        }

        // Merge: CoreData history + not-yet-drained buffered snapshots +
        // the just-captured sample, deduped by whole-second recordDate so
        // a buffered snapshot already mirrored into CoreData isn't counted
        // twice.
        var byTime: [TimeInterval: PressureSample] = [:]
        func add(_ sample: PressureSample) {
            guard sample.pressureKPa > 0, sample.date >= windowStart, sample.date <= now else { return }
            // Truncate to the whole second so a buffered snapshot and its
            // exact CoreData mirror collapse to one key. (`.rounded()` would
            // round to the *nearest* second, splitting a calendar second at
            // the .5 boundary.)
            byTime[sample.date.timeIntervalSince1970.rounded(.down)] = sample
        }
        coreDataSamples.forEach(add)
        for token in SharedSnapshotStore.readBuffer() {
            add(PressureSample(date: token.recordDate, pressureKPa: token.barPreassure, altitudeM: token.gpsAltitude))
        }
        add(PressureSample(date: latest.recordDate, pressureKPa: latest.barPreassure, altitudeM: latest.gpsAltitude))

        let trend = StormWarning.tendency(Array(byTime.values), now: now)
        // Don't post an alert if the BGTask was cancelled while we were
        // assembling the sample set / hitting CoreData above.
        guard !Task.isCancelled else { return }
        handleStormTrend(trend, now: now)
    }

    /// Turn a classified tendency into (at most) one cooldown-gated local
    /// notification. Recovery to steady/rising resets the cooldown so a
    /// genuinely new storm can alert promptly.
    private static func handleStormTrend(_ trend: PressureTrend, now: Date) {
        // Fall back to `.standard` if the App Group suite is unavailable: the
        // cooldown is read/written only here in the main app process, so it
        // doesn't need cross-process sharing — and a nil store would let the
        // cooldown silently break and re-fire the alert on every tick.
        let defaults = UserDefaults(suiteName: SharedSnapshotStore.appGroupID) ?? .standard
        switch trend.classification {
        case .steady, .rising:
            defaults.removeObject(forKey: stormLastNotifiedKey)
            return
        case .unknown, .falling:
            return
        case .fallingFast:
            break
        }

        let last = defaults.object(forKey: stormLastNotifiedKey) as? Date ?? .distantPast
        guard now.timeIntervalSince(last) >= StormWarning.notificationCooldownHours * 3600 else { return }

        postStormNotification(dropHPa: abs(trend.changeHPaOver3h))
        defaults.set(now, forKey: stormLastNotifiedKey)
    }

    /// Deliver the storm-warning notification, gated on authorization so a
    /// denied permission no-ops silently (no nag loop).
    private static func postStormNotification(dropHPa: Double) {
        // Re-fetch `current()` inside each closure rather than capturing a
        // local, so no non-Sendable `UNUserNotificationCenter` crosses the
        // `@Sendable` completion-handler boundary.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized ||
                  settings.authorizationStatus == .provisional else { return }

            let content = UNMutableNotificationContent()
            content.title = "Pressure falling fast"
            content.body = String(
                format: "Barometric pressure has dropped %.1f hPa in the last 3 hours — weather may be deteriorating.",
                dropHPa
            )
            content.sound = .default

            // A fixed identifier coalesces repeat advisories into one entry.
            let request = UNNotificationRequest(identifier: "storm-warning", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    AppLog.background.error("Failed to post storm notification: \(String(describing: error))")
                }
            }
        }
    }

    // MARK: - Aurora alert (Phase 2, opt-in)

    /// App-group key for the alerts toggle written by the "What this means"
    /// sheet on the Magnetic Conditions card. Default OFF, and `bool(forKey:)`
    /// reads an absent key as false, so an install that never opens that sheet
    /// never runs a line of the code below.
    static let auroraAlertsEnabledKey = "AuroraAlertsEnabled"

    /// App-group key holding the last time an aurora notification fired,
    /// used to enforce the cooldown across BGTask invocations / launches.
    private static let auroraLastNotifiedKey = "AuroraAlertLastNotifiedAt"

    /// Opt-in aurora alert, reached only from the app-refresh path. The toggle
    /// is read before anything else, so with alerts off this issues no
    /// request and reads no position — the background half of the feature
    /// simply does not exist until the user asks for it.
    ///
    /// The decision itself is the pure `AuroraAlert.shouldNotify`, so every
    /// "don't wake somebody for this" rule is a unit test rather than
    /// something only a rare storm night could exercise.
    private static func evaluateAuroraAlert() async {
        // Same deliberate `?? .standard` fallback as the storm cooldown above:
        // the toggle and the stamp are read and written only here in the main
        // app process, so they don't need cross-process sharing — and a nil
        // store would let the cooldown silently break and re-fire the alert on
        // every tick.
        let defaults = UserDefaults(suiteName: SharedSnapshotStore.appGroupID) ?? .standard
        let enabled = defaults.bool(forKey: auroraAlertsEnabledKey)
        guard enabled else { return }

        let service = SpaceWeatherService.shared
        await service.refreshIfStale()
        let snapshot = await service.snapshot()

        // The system may have expired the task while the request was in
        // flight; don't go on to post an alert after being told to stop.
        guard !Task.isCancelled else { return }

        // Last known position, from the shared snapshot the barometer capture
        // has just refreshed. This path never starts CoreLocation: a 3-hourly
        // global index does not justify waking the GPS in the background. Null
        // island is the "no fix ever" sentinel `pushDataToWidget` writes, not
        // a place anyone is standing, so it is the one coordinate we refuse.
        guard let fix = SharedSnapshotStore.readCurrent(),
              fix.gpsLatitude != 0 || fix.gpsLongitude != 0 else { return }

        let now = Date()
        let conditions = Geomagnetic.conditions(series: snapshot.series,
                                                latitude: fix.gpsLatitude,
                                                longitude: fix.gpsLongitude,
                                                grid: snapshot.grid,
                                                now: now)
        let last = defaults.object(forKey: auroraLastNotifiedKey) as? Date
        guard AuroraAlert.shouldNotify(conditions: conditions,
                                       enabled: enabled,
                                       lastNotifiedAt: last,
                                       now: now) else { return }

        postAuroraNotification(conditions)
        defaults.set(now, forKey: auroraLastNotifiedKey)
    }

    /// Deliver the aurora notification, gated on authorization so a denied
    /// permission no-ops silently (no nag loop). Authorization is asked for
    /// once in `initialize()`, so turning the toggle on raises no second
    /// prompt and this path never asks for anything.
    private static func postAuroraNotification(_ conditions: MagneticConditions) {
        let body = auroraBody(conditions)
        // Re-fetch `current()` inside each closure rather than capturing a
        // local, so no non-Sendable `UNUserNotificationCenter` crosses the
        // `@Sendable` completion-handler boundary.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized ||
                  settings.authorizationStatus == .provisional else { return }

            let content = UNMutableNotificationContent()
            content.title = "Aurora possible tonight"
            content.body = body
            content.sound = .default

            // A fixed identifier coalesces repeat advisories into one entry —
            // and a DIFFERENT one from the pressure warning's "storm-warning",
            // because these are two unrelated events and neither may quietly
            // replace the other in Notification Centre.
            let request = UNNotificationRequest(identifier: "aurora-alert", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    AppLog.background.error("Failed to post aurora notification: \(String(describing: error))")
                }
            }
        }
    }

    /// The notification body, in the two forms the alert gate lets through:
    /// inside the oval, and a glow on the horizon. No brightness adjective and
    /// no exclamation mark — the model has no brightness term (honesty
    /// contract item 8) — and the southern hemisphere reads the same sentence
    /// with "north" swapped for "south".
    private static func auroraBody(_ conditions: MagneticConditions) -> String {
        let aurora = conditions.aurora
        let pole = aurora.isNorthernHemisphere ? "north" : "south"
        let horizon = aurora.isNorthernHemisphere ? "northern" : "southern"

        // "Kp 6 forecast for 22:00–01:00 UTC. " — thirds notation, never a
        // decimal (item 13), and the bin in UTC because that is the frame SWPC
        // publishes in and the only one that means the same to every reader.
        var lead = ""
        if let kp = conditions.kpNow {
            lead = "Kp \(Geomagnetic.kpThirdsLabel(kp)) forecast"
            if let start = conditions.binStart {
                let end = start.addingTimeInterval(Geomagnetic.kpBinHours * 3600)
                lead += " for \(utcTimeFormatter.string(from: start))–\(utcTimeFormatter.string(from: end)) UTC"
            }
            lead += ". "
        }

        // The darkness window is local time: it is the one figure the reader
        // acts on, and they act on it by looking at their own clock.
        let from = aurora.windowStart.map { " from \(localTimeFormatter.string(from: $0))" } ?? ""

        // `.ovalReaches` shares the overhead wording on purpose: a margin at
        // or above zero means the observer is poleward of the oval's
        // equatorward edge, i.e. inside it. `.horizonGlow` is the only verdict
        // where the display is somewhere else and the horizon has to be clear.
        if aurora.visibility == .horizonGlow {
            return lead + "Possible glow low on the \(horizon) horizon\(from). You'll want a clear, open view \(pole)."
        }
        return lead + "From where you are the auroral oval reaches overhead — look \(pole)\(from)."
    }

    /// UTC, POSIX locale — the Kp bin is published in UTC, and a bin rendered
    /// in the reader's own zone would silently disagree with the card's footer.
    private static let utcTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// Local clock, `.short`, the same idiom as the card — so the darkness
    /// time honours the reader's 12/24-hour preference.
    private static let localTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
