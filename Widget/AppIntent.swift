//
//  AppIntent.swift
//  Widget
//
//  Created by Ivan Alekseev on 23/01/2025.
//

import WidgetKit
import AppIntents

struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Configuration" }
    static var description: IntentDescription { "GEO" }
    
    @Parameter(title: "Show Barometer Information", default: true)
    var showBarometer: Bool
    
    @Parameter(title: "Show GPS Information", default: true)
    var showGPS: Bool
}
