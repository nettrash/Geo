//
//  Geo_Watch_Widget.swift
//  Geo Watch Widget
//
//  Created by Ivan Alekseev on 28/04/2025.
//

import WidgetKit
import SwiftUI
import CoreMotion

// MARK: - Entry

struct GeoEntry: TimelineEntry {
    let date: Date
    let altitude: Double
    let pressure: Double
}

// MARK: - Provider

struct GeoProvider: TimelineProvider {
    private static let appGroupID = "group.me.nettrash.Geo"
    private static let pressureKey = "WatchBarometerPressure"
    private static let altitudeKey = "WatchBarometerAltitude"
    // Calibration reference written by the Watch app whenever the
    // paired iPhone sends a snapshot. The iPhone's `barAltitude` is
    // Apple's calibrated MSL altitude (CMAbsoluteAltitudeData), and
    // `barPreassure` is the pressure it observed at that altitude.
    // Anchoring the Watch widget's pressure sample against this pair
    // removes the weather bias the raw barometric formula has.
    private static let calibPressureKey = "iPhoneCalibPressure"
    private static let calibAltitudeKey = "iPhoneCalibAltitude"

    func placeholder(in context: Context) -> GeoEntry {
        GeoEntry(date: Date(), altitude: 0.0, pressure: 101.325)
    }

    func getSnapshot(in context: Context, completion: @escaping (GeoEntry) -> Void) {
        let (altitude, pressure) = readFromUserDefaults()
        completion(GeoEntry(date: Date(), altitude: altitude, pressure: pressure))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GeoEntry>) -> Void) {
        // Try reading a fresh barometer sample directly
        if CMAltimeter.isRelativeAltitudeAvailable() {
            let altimeter = CMAltimeter()
            altimeter.startRelativeAltitudeUpdates(to: .main) { data, error in
                altimeter.stopRelativeAltitudeUpdates()

                if let data = data {
                    let pressure = data.pressure.doubleValue  // kPa
                    let h: Double = self.altitudeFromPressure(pressure)

                    // Save to UserDefaults so next read has fresh data too
                    if let ud = UserDefaults(suiteName: GeoProvider.appGroupID) {
                        ud.set(pressure, forKey: GeoProvider.pressureKey)
                        ud.set(h, forKey: GeoProvider.altitudeKey)
                        ud.synchronize()
                    }

                    let entry = GeoEntry(date: Date(), altitude: h, pressure: pressure)
                    let refreshDate = Date().addingTimeInterval(300)
                    completion(Timeline(entries: [entry], policy: .after(refreshDate)))
                } else {
                    // Barometer read failed — fall back to UserDefaults
                    let (altitude, pressure) = self.readFromUserDefaults()
                    let entry = GeoEntry(date: Date(), altitude: altitude, pressure: pressure)
                    let refreshDate = Date().addingTimeInterval(300)
                    completion(Timeline(entries: [entry], policy: .after(refreshDate)))
                }
            }
        } else {
            // Barometer not available — use UserDefaults
            let (altitude, pressure) = readFromUserDefaults()
            let entry = GeoEntry(date: Date(), altitude: altitude, pressure: pressure)
            let refreshDate = Date().addingTimeInterval(300)
            completion(Timeline(entries: [entry], policy: .after(refreshDate)))
        }
    }

    /// Convert a freshly-sampled pressure (kPa) into altitude (m above
    /// MSL). Prefers the iPhone-calibrated reference when available;
    /// falls back to the standard-atmosphere formula otherwise.
    private func altitudeFromPressure(_ pressure: Double) -> Double {
        guard let ud = UserDefaults(suiteName: GeoProvider.appGroupID) else {
            return Atmosphere.altitude(pressureKPa: pressure)
        }
        let calibPressure = ud.double(forKey: GeoProvider.calibPressureKey)
        let calibAltitude = ud.double(forKey: GeoProvider.calibAltitudeKey)
        if calibPressure > 0 {
            // Lapse-rate analog anchored against the iPhone's calibrated
            // point; subtracting the two lapse-rate altitudes preserves
            // the calibration offset (Improvements #10/#11).
            return calibAltitude
                + (Atmosphere.altitude(pressureKPa: pressure)
                   - Atmosphere.altitude(pressureKPa: calibPressure))
        }
        // No iPhone calibration ever received — use the lapse-rate
        // standard-atmosphere formula as a bootstrap.
        return Atmosphere.altitude(pressureKPa: pressure)
    }

    private func readFromUserDefaults() -> (Double, Double) {
        guard let userDefaults = UserDefaults(suiteName: GeoProvider.appGroupID) else {
            return (0.0, 101.325)
        }
        userDefaults.synchronize()
        let pressure = userDefaults.double(forKey: GeoProvider.pressureKey)
        let altitude = userDefaults.double(forKey: GeoProvider.altitudeKey)
        if pressure > 0 {
            return (altitude, pressure)
        }
        return (0.0, 101.325)
    }
}

// MARK: - Corner Complication View

struct AltitudeCornerView: View {
    let altitude: Double
    let pressure: Double

    private var heightText: String {
        if abs(altitude) > 999 {
            return String(format: "%.1f km", altitude / 1000.0)
        }
        return String(format: "%.0f m", altitude)
    }

    private var gaugeValue: Double {
        min(max(altitude, 0), Atmosphere.everestHeightM)
    }

    var body: some View {
        Text(verbatim: heightText)
        .font(.system(size: 16, weight: .bold, design: .rounded))
        .minimumScaleFactor(0.3)
        .widgetLabel {
            Gauge(value: gaugeValue, in: 0...Atmosphere.everestHeightM) {
                EmptyView()
            }
            .gaugeStyle(.linearCapacity)
            .tint(Gradient(stops: [
                .init(color: .green, location: 0.0),
                .init(color: .green, location: 4000.0 / Atmosphere.everestHeightM),
                .init(color: .orange, location: 5000.0 / Atmosphere.everestHeightM),
                .init(color: .orange, location: 7480.0 / Atmosphere.everestHeightM),
                .init(color: .red, location: 8480.0 / Atmosphere.everestHeightM),
                .init(color: .red, location: 1.0),
            ]))
        }
    }
}

// MARK: - Circular Complication View

struct AltitudeCircularView: View {
    let altitude: Double
    let pressure: Double

    private var heightText: String {
        if abs(altitude) > 999 {
            return String(format: "%.1f", altitude / 1000.0)
        }
        return String(format: "%.0f", altitude)
    }

    private var heightUnitText: String {
        abs(altitude) > 999 ? "km" : "m"
    }

    private var gaugeValue: Double {
        min(max(altitude, 0), Atmosphere.everestHeightM)
    }

    var body: some View {
        Gauge(value: gaugeValue, in: 0...Atmosphere.everestHeightM) {
            Image(systemName: "mountain.2.fill")
                .font(.system(size: 8))
        } currentValueLabel: {
            VStack(spacing: -1) {
                Text(verbatim: heightText)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                Text(verbatim: heightUnitText)
                    .font(.system(size: 8))
            }
        }
        .gaugeStyle(.accessoryCircular)
        .tint(Gradient(stops: [
            .init(color: .green, location: 0.0),
            .init(color: .green, location: 4000.0 / Atmosphere.everestHeightM),
            .init(color: .orange, location: 5000.0 / Atmosphere.everestHeightM),
            .init(color: .orange, location: 7480.0 / Atmosphere.everestHeightM),
            .init(color: .red, location: 8480.0 / Atmosphere.everestHeightM),
            .init(color: .red, location: 1.0),
        ]))
    }
}

// MARK: - Inline Complication View

struct AltitudeInlineView: View {
    let altitude: Double
    let pressure: Double

    private var heightText: String {
        if abs(altitude) > 999 {
            return String(format: "%.1f km", altitude / 1000.0)
        }
        return String(format: "%.0f m", altitude)
    }

    private var pressureText: String {
        String(format: "%.0f mmHg", pressure * 7.50062)
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "mountain.2.fill")
            Text(verbatim: "\(heightText) · \(pressureText)")
        }
    }
}

// MARK: - Rectangular Complication View

struct AltitudeRectangularView: View {
    let altitude: Double
    let pressure: Double

    private var heightText: String {
        if abs(altitude) > 999 {
            return String(format: "%.1f km", altitude / 1000.0)
        }
        return String(format: "%.0f m", altitude)
    }

    private var pressureKPa: String {
        String(format: "%.2f kPa", pressure)
    }

    private var pressureMmHg: String {
        String(format: "%.0f mmHg", pressure * 7.50062)
    }

    private var gaugeValue: Double {
        min(max(altitude, 0), Atmosphere.everestHeightM)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "mountain.2.fill")
                    .font(.system(size: 12))
                Text(verbatim: heightText)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Spacer()
                Text(verbatim: pressureMmHg)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Gauge(value: gaugeValue, in: 0...Atmosphere.everestHeightM) {
                EmptyView()
            }
            .gaugeStyle(.linearCapacity)
            .tint(Gradient(stops: [
                .init(color: .green, location: 0.0),
                .init(color: .green, location: 4000.0 / Atmosphere.everestHeightM),
                .init(color: .orange, location: 5000.0 / Atmosphere.everestHeightM),
                .init(color: .orange, location: 7480.0 / Atmosphere.everestHeightM),
                .init(color: .red, location: 8480.0 / Atmosphere.everestHeightM),
                .init(color: .red, location: 1.0),
            ]))

            HStack {
                Text(verbatim: pressureKPa)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: "▲ 8848")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Widgets

struct AltitudeCornerWidget: Widget {
    let kind: String = "me.nettrash.Geo.Watch.Widget.Corner"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: GeoProvider()) { entry in
            AltitudeCornerView(altitude: entry.altitude, pressure: entry.pressure)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Altitude")
        .description("Shows current altitude")
        .supportedFamilies([.accessoryCorner])
    }
}

struct AltitudeCircularWidget: Widget {
    let kind: String = "me.nettrash.Geo.Watch.Widget.Circular"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: GeoProvider()) { entry in
            AltitudeCircularView(altitude: entry.altitude, pressure: entry.pressure)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Altitude")
        .description("Shows current altitude")
        .supportedFamilies([.accessoryCircular])
    }
}

struct AltitudeInlineWidget: Widget {
    let kind: String = "me.nettrash.Geo.Watch.Widget.Inline"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: GeoProvider()) { entry in
            AltitudeInlineView(altitude: entry.altitude, pressure: entry.pressure)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Altitude")
        .description("Shows current altitude and pressure")
        .supportedFamilies([.accessoryInline])
    }
}

struct AltitudeRectangularWidget: Widget {
    let kind: String = "me.nettrash.Geo.Watch.Widget.Rectangular"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: GeoProvider()) { entry in
            AltitudeRectangularView(altitude: entry.altitude, pressure: entry.pressure)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Altitude")
        .description("Shows altitude, pressure and gauge")
        .supportedFamilies([.accessoryRectangular])
    }
}

@main
struct Geo_Watch_Widget: WidgetBundle {
    var body: some Widget {
        AltitudeCornerWidget()
        AltitudeCircularWidget()
        AltitudeInlineWidget()
        AltitudeRectangularWidget()
    }
}

// MARK: - Previews

#Preview(as: .accessoryCorner) {
    AltitudeCornerWidget()
} timeline: {
    GeoEntry(date: .now, altitude: -4.0, pressure: 101.374)
    GeoEntry(date: .now, altitude: 0.0, pressure: 101.325)
    GeoEntry(date: .now, altitude: 1234.0, pressure: 87.5)
    GeoEntry(date: .now, altitude: 5300.0, pressure: 53.6)
    GeoEntry(date: .now, altitude: 8848.0, pressure: 35.4)
}

#Preview(as: .accessoryCircular) {
    AltitudeCircularWidget()
} timeline: {
    GeoEntry(date: .now, altitude: -4.0, pressure: 101.374)
    GeoEntry(date: .now, altitude: 0.0, pressure: 101.325)
    GeoEntry(date: .now, altitude: 1234.0, pressure: 87.5)
    GeoEntry(date: .now, altitude: 5300.0, pressure: 53.6)
    GeoEntry(date: .now, altitude: 8848.0, pressure: 35.4)
}

#Preview(as: .accessoryInline) {
    AltitudeInlineWidget()
} timeline: {
    GeoEntry(date: .now, altitude: -4.0, pressure: 101.374)
    GeoEntry(date: .now, altitude: 0.0, pressure: 101.325)
    GeoEntry(date: .now, altitude: 1234.0, pressure: 87.5)
    GeoEntry(date: .now, altitude: 5300.0, pressure: 53.6)
    GeoEntry(date: .now, altitude: 8848.0, pressure: 35.4)
}

#Preview(as: .accessoryRectangular) {
    AltitudeRectangularWidget()
} timeline: {
    GeoEntry(date: .now, altitude: -4.0, pressure: 101.374)
    GeoEntry(date: .now, altitude: 0.0, pressure: 101.325)
    GeoEntry(date: .now, altitude: 1234.0, pressure: 87.5)
    GeoEntry(date: .now, altitude: 5300.0, pressure: 53.6)
    GeoEntry(date: .now, altitude: 8848.0, pressure: 35.4)
}
