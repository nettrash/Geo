//
//  SharedSnapshotStore.swift
//  Geo
//
//  Single source of truth for the App Group `UserDefaults` keys that
//  both the main apps, the iPhone widget and the Watch widget read
//  from / write to. Centralises the "current snapshot" + "ring buffer"
//  pattern so back-fill logic stays identical everywhere.
//

import Foundation
import os

/// Shared App Group store. All readers / writers go through here so the
/// keys stay consistent and a single audit point exists for backward
/// compatibility on disk.
enum SharedSnapshotStore {

    static let appGroupID = "group.me.nettrash.Geo"

    /// Latest snapshot of barometer + GPS state.
    static let currentKey = "ActualInformation"

    /// Rolling buffer of the last `bufferCapacity` snapshots so the main
    /// app can back-fill CoreData history with samples captured by the
    /// widget while it was suspended.
    static let bufferKey = "SnapshotRingBuffer"
    static let bufferCapacity = 12

    private static let log = Logger(subsystem: AppLog.subsystem, category: "snapshot-store")

    // MARK: - Current snapshot

    /// Read the most recent persisted snapshot, or `nil` if none exists.
    static func readCurrent() -> InformationToken? {
        guard let ud = UserDefaults(suiteName: appGroupID),
              let data = ud.object(forKey: currentKey) as? Data else {
            return nil
        }
        do {
            return try JSONDecoder().decode(InformationToken.self, from: data)
        } catch {
            log.error("Failed to decode current snapshot: \(String(describing: error))")
            return nil
        }
    }

    /// Persist `token` as the current snapshot and append it to the ring
    /// buffer for later backfill. Caller is responsible for triggering
    /// any widget reload they want.
    static func write(_ token: InformationToken) {
        guard let ud = UserDefaults(suiteName: appGroupID) else { return }
        do {
            let data = try JSONEncoder().encode(token)
            ud.set(data, forKey: currentKey)
        } catch {
            log.error("Failed to encode snapshot: \(String(describing: error))")
        }
        appendToBuffer(token, in: ud)
    }

    // MARK: - Ring buffer (for backfill)

    /// Read the buffered snapshots oldest-first.
    static func readBuffer() -> [InformationToken] {
        guard let ud = UserDefaults(suiteName: appGroupID),
              let data = ud.object(forKey: bufferKey) as? Data else {
            return []
        }
        do {
            return try JSONDecoder().decode([InformationToken].self, from: data)
        } catch {
            log.error("Failed to decode buffer: \(String(describing: error))")
            return []
        }
    }

    /// Replace the buffer with `tokens` (used when the main app drains
    /// the buffer on launch / foregrounding).
    static func writeBuffer(_ tokens: [InformationToken]) {
        guard let ud = UserDefaults(suiteName: appGroupID) else { return }
        if tokens.isEmpty {
            ud.removeObject(forKey: bufferKey)
            return
        }
        do {
            let data = try JSONEncoder().encode(tokens)
            ud.set(data, forKey: bufferKey)
        } catch {
            log.error("Failed to encode buffer: \(String(describing: error))")
        }
    }

    /// Drop every snapshot currently buffered. Called by the main app
    /// once it has finished moving the buffered samples into CoreData.
    static func clearBuffer() {
        guard let ud = UserDefaults(suiteName: appGroupID) else { return }
        ud.removeObject(forKey: bufferKey)
    }

    private static func appendToBuffer(_ token: InformationToken,
                                       in ud: UserDefaults) {
        var buffer: [InformationToken] = []
        if let data = ud.object(forKey: bufferKey) as? Data,
           let decoded = try? JSONDecoder().decode([InformationToken].self, from: data) {
            buffer = decoded
        }

        // Skip near-duplicates that would otherwise spam the buffer when
        // the barometer reports the same value many times in a row.
        if let last = buffer.last,
           abs(last.barPreassure - token.barPreassure) < 0.005,
           abs(last.recordDate.timeIntervalSince(token.recordDate)) < 5 {
            return
        }

        buffer.append(token)
        while buffer.count > bufferCapacity {
            buffer.removeFirst()
        }

        do {
            let data = try JSONEncoder().encode(buffer)
            ud.set(data, forKey: bufferKey)
        } catch {
            log.error("Failed to append to buffer: \(String(describing: error))")
        }
    }
}
