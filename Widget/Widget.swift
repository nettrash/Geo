//
//  Widget.swift
//  Widget
//
//  Created by Ivan Alekseev on 23/01/2025.
//

import WidgetKit
import SwiftUI
import CoreMotion

struct Provider: AppIntentTimelineProvider {
    
    /// Reads the latest data from the shared App Group store.
    private func readLatestInformation() -> InformationToken? {
        SharedSnapshotStore.readCurrent()
    }

    /// Reads a fresh barometer sample, merges with the last known GPS
    /// snapshot, and persists the combined result through
    /// `SharedSnapshotStore` (which also appends to the ring buffer that
    /// the main app drains on launch).
    ///
    /// Reads pressure from the relative stream and altitude from the
    /// Apple-calibrated absolute stream (iOS 15+) in parallel. The
    /// absolute stream uses Apple's location-tagged sea-level-pressure
    /// data, so it isn't biased by weather like the raw barometric
    /// formula is. Falls back to the formula only when the absolute
    /// stream is unavailable or fails to deliver a reading.
    private func readFreshBarometer() async -> InformationToken? {
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return nil }

        async let pressureSample = readPressureSample()
        async let absoluteSample = readAbsoluteAltitudeSample()
        let (ps, abs) = await (pressureSample, absoluteSample)

        guard let pressure = ps else { return nil }

        let altitude: Double
        if let abs = abs {
            altitude = abs
        } else {
            // Bootstrap fallback: lapse-rate pressure-only formula.
            // Used only when the calibrated absolute stream is
            // unavailable (older OS / hardware, or location
            // authorisation not granted to the host app).
            altitude = Atmosphere.altitude(pressureKPa: pressure)
        }

        // Preserve last known GPS data (including coordinates so
        // the main app can backfill complete history items).
        let previous = self.readLatestInformation()

        let info = InformationToken(
            recordDate: Date(),
            gpsAltitude: previous?.gpsAltitude ?? 0.0,
            gpsSpeed: previous?.gpsSpeed ?? 0.0,
            barPreassure: pressure,
            barAltitude: altitude,
            gpsLatitude: previous?.gpsLatitude ?? 0.0,
            gpsLongitude: previous?.gpsLongitude ?? 0.0
        )

        SharedSnapshotStore.write(info)
        return info
    }

    /// One-shot relative-altitude read: starts updates, takes the first
    /// sample, stops. Returns the absolute pressure in kPa.
    private func readPressureSample() async -> Double? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Double?, Never>) in
            let altimeter = CMAltimeter()
            var resumed = false
            altimeter.startRelativeAltitudeUpdates(to: .main) { data, _ in
                // CoreMotion can enqueue multiple callbacks before
                // `stop` takes effect; guard against double-resume,
                // which would trap on a checked continuation.
                if resumed { return }
                resumed = true
                altimeter.stopRelativeAltitudeUpdates()
                continuation.resume(returning: data?.pressure.doubleValue)
            }
        }
    }

    /// One-shot absolute-altitude read (iOS 15+). Returns Apple's
    /// calibrated MSL altitude in metres, or `nil` if the device /
    /// OS can't deliver one.
    private func readAbsoluteAltitudeSample() async -> Double? {
        guard #available(iOS 15.0, *), CMAltimeter.isAbsoluteAltitudeAvailable() else {
            return nil
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Double?, Never>) in
            let altimeter = CMAltimeter()
            var resumed = false
            altimeter.startAbsoluteAltitudeUpdates(to: .main) { data, _ in
                if resumed { return }
                resumed = true
                altimeter.stopAbsoluteAltitudeUpdates()
                continuation.resume(returning: data?.altitude)
            }
        }
    }
    
    func placeholder(in context: Context) -> InformationEntry {
        InformationEntry(date: Date(), configuration: nil, information: readLatestInformation())
    }

    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> InformationEntry {
        if context.isPreview {
            return InformationEntry(date: Date(), configuration: configuration, information: InformationToken(recordDate: Date(), gpsAltitude: 2450.0, gpsSpeed: 2.0, barPreassure: 563.0, barAltitude: 2650.0))
        }
        // Try fresh barometer, fall back to UserDefaults
        let info = await readFreshBarometer() ?? readLatestInformation()
        return InformationEntry(date: Date(), configuration: configuration, information: info)
    }
    
    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<InformationEntry> {
        // Try reading a fresh barometer sample directly
        let info = await readFreshBarometer() ?? readLatestInformation()
        let entry = InformationEntry(date: Date(), configuration: configuration, information: info)
        
        // Self-refresh every 2 minutes as a fallback.
        // The main app also triggers immediate reloads via WidgetCenter
        // whenever barometer or GPS data changes.
        let refreshDate = Date().addingTimeInterval(120)
        return Timeline(entries: [entry], policy: .after(refreshDate))
    }
}

struct InformationEntry: TimelineEntry {
    let date: Date
    let configuration: ConfigurationAppIntent?
    let information: InformationToken?
}

struct WidgetEntryView : View {
    @Environment(\.widgetFamily) var family: WidgetFamily
    var entry: Provider.Entry

    /// Shared staleness threshold (seconds). Beyond this age the snapshot
    /// is treated as stale: the header switches to a relative age and the
    /// carried-forward GPS section is dimmed. Kept in sync with the
    /// Android widget (30 min).
    private static let stalenessThreshold: TimeInterval = 30 * 60

    var body: some View {
        ZStack {
            Image("Background")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .opacity(0.3)

            if let information = entry.information {

                let isStale = entry.date.timeIntervalSince(information.recordDate) > Self.stalenessThreshold

                VStack {
                    HStack {
                        Text("Actual on:").font(.system(size: 6)).bold().underline()

                        Spacer()

                        if isStale {
                            // Relative age (e.g. "2h ago") so a multi-hour-old
                            // snapshot is not mistaken for current data.
                            Text(information.recordDate, style: .relative).font(.system(size: 6))
                        } else {
                            Text(information.recordDate, style: .date).font(.system(size: 6))
                            Text(information.recordDate, style: .time).font(.system(size: 6))
                        }
                    }

                    Spacer()

                    if (entry.configuration?.showGPS ?? true) {

                        HStack(alignment: .top) {
                            Text("GPS:").font(.system(size: 6)).bold().underline()

                            Spacer()

                            VStack(alignment: .trailing) {
                                Text(verbatim: "\(String(format: "%.0f", information.gpsAltitude)) m")
                                    .font(.system(size: 8))
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                Text(verbatim: "\(String(format: "%.1f", information.gpsSpeed)) m/s")
                                    .font(.system(size: 8))
                                Text(verbatim: "\(String(format: "%.1f", (information.gpsSpeed) * 3600.0 / 1000.0)) km/h")
                                    .font(.system(size: 8))
                            }
                        }
                        // The GPS line is carried forward from the last fix
                        // while the barometer self-refreshes each tick, so it
                        // can be arbitrarily old. Dim it once stale.
                        .opacity(isStale ? 0.4 : 1.0)

                        Spacer()
                            .frame(height: 10)

                    }
                    
                    if entry.configuration?.showBarometer ?? true {
                        
                        HStack(alignment: .top) {
                            Text("Barometer:").font(.system(size: 6)).bold().underline()
                            
                            Spacer()

                            VStack(alignment: .trailing) {
                                Text(verbatim: "\(String(format: "%.0f", information.barAltitude)) m")
                                    .font(.system(size: 8))
                                Text(verbatim: "\(String(format: "%.4f", information.barPreassure)) kPa")
                                    .font(.system(size: 8))
                                Text(verbatim: "\(String(format: "%.4f", (information.barPreassure) * 7.50062)) mm Hg")
                                    .font(.system(size: 8))
                                Text(verbatim: "\(String(format: "%.4f", (information.barPreassure) / 101.325)) atm")
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
