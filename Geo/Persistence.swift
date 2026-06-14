//
//  Persistence.swift
//  Geo
//
//  Created by nettrash on 08/09/2023.
//

import CoreData
import os

struct PersistenceController {
    static let shared = PersistenceController()

    static let preview: PersistenceController = {
        let result = PersistenceController(inMemory: true)
        let viewContext = result.container.viewContext
        for _ in 0..<10 {
            let newItem = HistoryItem(context: viewContext)
            newItem.recordDate = Date()
        }
        do {
            try viewContext.save()
        } catch {
            // Preview-only path. Log and continue with whatever we
            // managed to insert; don't crash the SwiftUI canvas.
            Logger(subsystem: "me.nettrash.Geo", category: "persistence")
                .error("Preview viewContext save failed: \(String(describing: error))")
        }
        return result
    }()

    let container: NSPersistentCloudKitContainer

    init(inMemory: Bool = false) {
        let log = Logger(subsystem: "me.nettrash.Geo", category: "persistence")

        let buildContainer: (Bool) -> NSPersistentCloudKitContainer = { useInMemory in
            let c = NSPersistentCloudKitContainer(name: "Geo")
            if let desc = c.persistentStoreDescriptions.first {
                if useInMemory {
                    desc.url = URL(fileURLWithPath: "/dev/null")
                }
                // Make sure the additive lightweight migration (e.g. the
                // Trip entity) is always attempted before any failure path.
                desc.shouldMigrateStoreAutomatically = true
                desc.shouldInferMappingModelAutomatically = true
            }
            return c
        }

        var c = buildContainer(inMemory)
        var loadError: NSError?

        c.loadPersistentStores { _, error in
            if let error = error as NSError? {
                loadError = error
            }
        }

        if let firstError = loadError, !inMemory {
            // Only RESET the on-disk store for errors that genuinely mean it
            // can't be opened against the current model (failed/incompatible
            // migration, or SQLite corruption). Transient errors (I/O, disk
            // pressure, file locks, CloudKit) must NOT destroy data — deleting
            // unconditionally would lose any offline / not-yet-synced rows.
            if Self.isStoreUnopenable(firstError) {
                log.error("Persistent store unopenable (code \(firstError.code, privacy: .public)): \(String(describing: firstError)). Backing up + resetting.")

                for desc in c.persistentStoreDescriptions {
                    if let url = desc.url, FileManager.default.fileExists(atPath: url.path) {
                        Self.backupStore(at: url, log: log)   // best-effort, recoverable copy
                        Self.removeStore(at: url, log: log)
                    }
                }

                c = buildContainer(false)
                var retryError: NSError?
                c.loadPersistentStores { _, error in
                    if let error = error as NSError? { retryError = error }
                }
                if let retryError {
                    log.fault("Retry after reset failed: \(String(describing: retryError)). Falling back to in-memory.")
                    c = buildContainer(true)
                    c.loadPersistentStores { _, error in
                        if let error = error as NSError? {
                            log.fault("In-memory persistent-store load failed: \(String(describing: error))")
                        }
                    }
                }
            } else {
                // Transient / non-corruption error: keep the on-disk data
                // intact and run on an in-memory store for this session only.
                // The next launch retries the real store once the issue clears.
                log.error("Persistent store failed to load (transient, code \(firstError.code, privacy: .public)): \(String(describing: firstError)). Using in-memory this session WITHOUT deleting on-disk data.")
                c = buildContainer(true)
                c.loadPersistentStores { _, error in
                    if let error = error as NSError? {
                        log.fault("In-memory persistent-store load failed: \(String(describing: error))")
                    }
                }
            }
        }

        c.viewContext.automaticallyMergesChangesFromParent = true
        self.container = c
    }

    /// True only for load errors that mean the store cannot be opened against
    /// the current model and a reset is the sole recovery: Core Data
    /// migration / model-incompatibility errors (codes 134100–134190) or
    /// SQLite file corruption. Everything else is treated as transient.
    private static func isStoreUnopenable(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain, (134100...134190).contains(error.code) {
            return true
        }
        // SQLITE_CORRUPT (11) / SQLITE_NOTADB (26) in the underlying SQLite
        // error. The domain check matters: code 11 in NSPOSIXErrorDomain is
        // EAGAIN (a transient lock), which must NOT trigger a destructive reset.
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == "NSSQLiteErrorDomain",
           underlying.code == 11 || underlying.code == 26 {
            return true
        }
        return false
    }

    private static func sidecarURLs(for url: URL) -> [URL] {
        [url,
         URL(fileURLWithPath: url.path + "-wal"),
         URL(fileURLWithPath: url.path + "-shm")]
    }

    /// Best-effort `*.backup` copy of the store (+ WAL/SHM) before a reset, so
    /// a destroyed store is at least recoverable off-device.
    private static func backupStore(at url: URL, log: Logger) {
        for file in sidecarURLs(for: url) where FileManager.default.fileExists(atPath: file.path) {
            let backup = URL(fileURLWithPath: file.path + ".backup")
            try? FileManager.default.removeItem(at: backup)
            do {
                try FileManager.default.copyItem(at: file, to: backup)
            } catch {
                log.error("Backup failed for \(file.lastPathComponent, privacy: .public): \(String(describing: error))")
            }
        }
    }

    private static func removeStore(at url: URL, log: Logger) {
        for file in sidecarURLs(for: url) where FileManager.default.fileExists(atPath: file.path) {
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                log.error("Failed to delete \(file.lastPathComponent, privacy: .public): \(String(describing: error))")
            }
        }
    }
}
