//
//  SummitLogStore.swift
//  Geo
//
//  Summit log — auto-detect arrival at a known peak, then log the ascent.
//  Observable store mirroring `TripRecorder`: wraps the `History` Core Data
//  CRUD and caches the saved list for the Stat-tab trophy case. Owned by
//  `GeoAppDelegate`; CloudKit-synced like `Trip`.
//

import Foundation
import CoreLocation

@Observable
final class SummitLogStore {
    private let history: History

    /// Logged ascents, newest first.
    var summits: [SummitLog] = []

    init(history: History) {
        self.history = history
        reload()
    }

    func reload() { summits = history.fetchSummits() }

    @discardableResult
    func log(peak: MountainInfo, set: String, measuredAltitude: Double, note: String) -> SummitLog? {
        let coord = peak.coordinates
        let log = history.saveSummit(
            // Never persist an empty name — the UI's `?? "Summit"` fallback only
            // catches nil, so a blank would render as an empty title.
            peakName: peak.name?.isEmpty == false ? peak.name! : "Summit",
            peakIdentifier: peak.id,
            peakSet: set,
            peakHeight: Double(peak.height ?? 0),
            latitude: coord?.latitude ?? 0,
            longitude: coord?.longitude ?? 0,
            measuredAltitude: measuredAltitude,
            note: note
        )
        reload()
        return log
    }

    func delete(_ log: SummitLog) {
        history.deleteSummit(log)
        reload()
    }

    func updateNote(_ log: SummitLog, note: String) {
        history.updateSummitNote(log, note: note)
        reload()
    }

    /// True if the peak was logged within the last 18 h — suppresses
    /// re-prompting while the user lingers on a summit (and across a quick
    /// app relaunch at the same spot).
    func wasRecentlyLogged(_ peak: MountainInfo) -> Bool {
        history.hasRecentSummit(peakIdentifier: peak.id, withinHours: 18)
    }
}
