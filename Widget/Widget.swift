//
//  Widget.swift
//  Widget
//
//  Created by Ivan Alekseev on 23/01/2025.
//

import WidgetKit
import SwiftUI

class TimelineForInfomationTokens {
    var entities: [InformationEntry] = []
}

struct Provider: AppIntentTimelineProvider {
    var timeline: TimelineForInfomationTokens = .init()
    
    func placeholder(in context: Context) -> InformationEntry {
        var informationToken: InformationToken? = nil
        
        if let userDefaults = UserDefaults(suiteName: "group.me.nettrash.Geo"),
           let data = userDefaults.object(forKey: "ActualInformation") as? Data,
           let info = try? JSONDecoder().decode(InformationToken.self, from: data) {
            informationToken = info
            timeline.entities.append(InformationEntry(date: Date(), configuration: nil, information: informationToken))
        }
        return timeline.entities.last ?? InformationEntry(date: Date(), configuration: nil, information: nil)
    }

    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> InformationEntry {
        var informationToken: InformationToken? = nil
        if let userDefaults = UserDefaults(suiteName: "group.me.nettrash.Geo"),
           let data = userDefaults.object(forKey: "ActualInformation") as? Data,
           let info = try? JSONDecoder().decode(InformationToken.self, from: data) {
            informationToken = info
            timeline.entities.append(InformationEntry(date: Date(), configuration: configuration, information: informationToken))
        }
        if context.isPreview && timeline.entities.isEmpty {
            return InformationEntry(date: Date(), configuration: configuration, information: InformationToken(recordDate: Date(), gpsAltitude: 2450.0, gpsSpeed: 2.0, barPreassure: 563.0, barAltitude: 2650.0))
        } else {
            return self.timeline.entities.last ?? placeholder(in: context)
        }
    }
    
    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<InformationEntry> {

        var informationToken: InformationToken? = nil
        if let userDefaults = UserDefaults(suiteName: "group.me.nettrash.Geo"),
           let data = userDefaults.object(forKey: "ActualInformation") as? Data,
           let info = try? JSONDecoder().decode(InformationToken.self, from: data) {
            informationToken = info
        }
        let entry = InformationEntry(date: Date(), configuration: configuration, information: informationToken)

        timeline.entities.append(entry)

        return Timeline(entries: timeline.entities, policy: .atEnd)
    }

//    func relevances() async -> WidgetRelevances<ConfigurationAppIntent> {
//        // Generate a list containing the contexts this widget is relevant in.
//    }
}

struct InformationEntry: TimelineEntry {
    let date: Date
    let configuration: ConfigurationAppIntent?
    let information: InformationToken?
}

struct WidgetEntryView : View {
    @Environment(\.widgetFamily) var family: WidgetFamily
    var entry: Provider.Entry

    var body: some View {
        ZStack {
            Image("Background")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .opacity(0.3)
            
            if let information = entry.information {

                VStack {
                    HStack {
                        Text("Actual on:").font(.system(size: 6)).bold().underline()
                        
                        Spacer()
                        
                        Text(information.recordDate, style: .date).font(.system(size: 6))
                        Text(information.recordDate, style: .time).font(.system(size: 6))
                    }
                    
                    Spacer()
                    
                    if (entry.configuration?.showGPS ?? true) {
                        
                        HStack(alignment: .top) {
                            Text("GPS:").font(.system(size: 6)).bold().underline()
                            
                            Spacer()
                            
                            VStack(alignment: .trailing) {
                                Text("\(String(format: "%.0f", information.gpsAltitude)) m")
                                    .font(.system(size: 8))
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                Text("\(String(format: "%.1f", information.gpsSpeed)) m/s")
                                    .font(.system(size: 8))
                                Text("\(String(format: "%.1f", (information.gpsSpeed) * 3600.0 / 1000.0)) km/h")
                                    .font(.system(size: 8))
                            }
                        }
                        
                        Spacer()
                            .frame(height: 10)
                        
                    }
                    
                    if entry.configuration?.showBarometer ?? true {
                        
                        HStack(alignment: .top) {
                            Text("Barometer:").font(.system(size: 6)).bold().underline()
                            
                            Spacer()

                            VStack(alignment: .trailing) {
                                Text("\(String(format: "%.0f", information.barAltitude)) m")
                                    .font(.system(size: 8))
                                Text("\(String(format: "%.4f", information.barPreassure)) kPa")
                                    .font(.system(size: 8))
                                Text("\(String(format: "%.4f", (information.barPreassure) * 7.50062)) mm Hg")
                                    .font(.system(size: 8))
                                Text("\(String(format: "%.4f", (information.barPreassure) / 101.325)) atm")
                                    .font(.system(size: 8))
                            }
                        }
                        
                    }

                }

            } else {
                
                Text("No information available...")
                
            }
        }
    }
}

struct Widget: SwiftUI.Widget {
    let kind: String = "GEO"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ConfigurationAppIntent.self, provider: Provider()) { entry in
            WidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

extension InformationToken {
    fileprivate static var one: InformationToken {
        let token = InformationToken(recordDate: Date(), gpsAltitude: 100.0, gpsSpeed: 10.0, barPreassure: 200.0, barAltitude: 1013.0)
        return token
    }
    
    fileprivate static var two: InformationToken {
        let token = InformationToken(recordDate: Date(), gpsAltitude: 101.0, gpsSpeed: 11.0, barPreassure: 201.0, barAltitude: 1014.0)
        return token
    }
}

#Preview(as: .systemSmall) {
    Widget()
} timeline: {
    InformationEntry(date: .now, configuration: nil, information: .one)
    InformationEntry(date: .now, configuration: nil, information: .two)
}
