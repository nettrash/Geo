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

        // Build the container, with a one-shot recovery: if the
        // initial load fails (corruption, schema mismatch, disk
        // full, …) we delete the on-disk store, log it, and fall
        // back to an in-memory store so the app still launches and
        // the user can recover the next time CloudKit syncs.
        let buildContainer: (Bool) -> NSPersistentCloudKitContainer = { useInMemory in
            let c = NSPersistentCloudKitContainer(name: "Geo")
            if useInMemory {
                c.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
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

        // First load failed and we weren't already in-memory: delete
        // the corrupted store and try again. This trades local data
        // for app-launch reliability — CloudKit will replay items
        // back from iCloud the next time the user signs in.
        if let firstError = loadError, !inMemory {
            log.error("Persistent store failed to load: \(String(describing: firstError)). Deleting and retrying.")

            for desc in c.persistentStoreDescriptions {
                if let url = desc.url, FileManager.default.fileExists(atPath: url.path) {
                    do {
                        try FileManager.default.removeItem(at: url)
                        // Also remove the WAL / SHM siblings that
                        // SQLite leaves behind.
                        let wal = url.appendingPathExtension("wal")
                        let shm = url.appendingPathExtension("shm")
                        try? FileManager.default.removeItem(at: wal)
                        try? FileManager.default.removeItem(at: shm)
                    } catch {
                        log.error("Failed to delete corrupted store at \(url.path): \(String(describing: error))")
                    }
                }
            }

            // Rebuild and try once more.
            c = buildContainer(false)
            var retryError: NSError?
            c.loadPersistentStores { _, error in
                if let error = error as NSError? { retryError = error }
            }

            // Retry also failed → fall back to in-memory so the app
            // at least launches. The user keeps the session's data
            // but nothing persists; iCloud will resync on relaunch
            // once the underlying issue clears.
            if let retryError {
                log.fault("Retry of persistent-store load failed: \(String(describing: retryError)). Falling back to in-memory store.")
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
}
