//
//  Geo_Watch_Widget.swift
//  Geo Watch Widget
//
//  Created by Ivan Alekseev on 28/04/2025.
//

import WidgetKit
import SwiftUI

@main
struct Geo_Watch_Widget: Widget {
    let kind: String = "me.nettrash.Geo.Watch.Widget"
    
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: EmptyProvider()) { entry in
            EmptyView()
        }
        .configurationDisplayName("Geo")
        .description("Geo Watch Widget")
    }
}

struct EmptyEntry: TimelineEntry {
    let date: Date
}

struct EmptyProvider: TimelineProvider {
    func placeholder(in context: Context) -> EmptyEntry {
        EmptyEntry(date: Date())
    }
    
    func getSnapshot(in context: Context, completion: @escaping (EmptyEntry) -> Void) {
        completion(EmptyEntry(date: Date()))
    }
    
    func getTimeline(in context: Context, completion: @escaping (Timeline<EmptyEntry>) -> Void) {
        let entry = EmptyEntry(date: Date())
        let timeline = Timeline(entries: [entry], policy: .never)
        completion(timeline)
    }
}
