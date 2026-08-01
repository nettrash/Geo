//
//  AppLog.swift
//  Geo
//
//  Centralised `os.Logger` instances. Use these instead of `print` /
//  `NSLog` so that Console.app and the unified system log can filter
//  and group by subsystem/category.
//

import Foundation
import os

enum AppLog {
    /// Bundle id for the host app. Subsystem strings should always start
    /// with this so all logs from the Geo apps cluster together in
    /// Console.app.
    static let subsystem = "me.nettrash.Geo"

    static let app          = Logger(subsystem: subsystem, category: "app")
    static let location     = Logger(subsystem: subsystem, category: "location")
    static let barometer    = Logger(subsystem: subsystem, category: "barometer")
    static let widget       = Logger(subsystem: subsystem, category: "widget")
    static let watch        = Logger(subsystem: subsystem, category: "watch")
    static let connectivity = Logger(subsystem: subsystem, category: "connectivity")
    static let ar           = Logger(subsystem: subsystem, category: "ar")
    static let history      = Logger(subsystem: subsystem, category: "history")
    static let background   = Logger(subsystem: subsystem, category: "background")
    /// The NOAA SWPC planetary-Kp fetch and its cache. Nothing logged here
    /// ever carries a coordinate — the request itself carries none either.
    static let spaceWeather = Logger(subsystem: subsystem, category: "space-weather")
}
