//
//  SolarInformationView.swift
//  Geo
//
//  Created by Ivan Alekseev on 14/06/2026.
//

import SwiftUI

/// Today's solar windows for the user's exact position and altitude
/// (sunrise / sunset / solar noon / golden & blue hour / civil twilight)
/// with a live "X h to sunset" countdown. 100 % on-device via the shared
/// `Solar` (NOAA) math; the altitude horizon-dip shifts sunrise earlier
/// and sunset later from a summit.
struct SolarInformationView: View {
    @State var location: Location?

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    var body: some View {
        ZStack {
            Text("S U N")
                .opacity(0.2)
                .font(.title)
                .rotationEffect(.degrees(-25))
                .padding()

            // Recompute the day's windows on a 1-minute cadence so the
            // static rows roll over at local midnight even when no new
            // location fix arrives; the inner per-second TimelineView drives
            // only the live countdown (no per-second solar recompute).
            TimelineView(.periodic(from: .now, by: 60)) { minuteContext in
                content(now: minuteContext.date)
            }
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        VStack {
            if let loc = location?.location {
                let lat = loc.coordinate.latitude
                let lon = loc.coordinate.longitude
                let alt = loc.altitude
                let times = Solar.times(date: now, latitude: lat, longitude: lon, altitude: alt)

                // Live, per-second countdown to the next horizon crossing.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    countdownRow(times: times, now: context.date, lat: lat, lon: lon, alt: alt)
                }

                row("Dawn", Self.timeString(times.civilDawn))
                row("Sunrise", Self.timeString(times.sunrise))
                row("Golden AM", Self.rangeString(times.goldenDawn, times.goldenMorningEnd))
                row("Solar noon", Self.timeString(times.solarNoon))
                row("Golden PM", Self.rangeString(times.goldenEveningStart, times.goldenDusk))
                row("Sunset", Self.timeString(times.sunset))
                row("Dusk", Self.timeString(times.civilDusk))
                row("Day length", Self.durationString(times.dayLength))
            } else {
                HStack {
                    Text("Waiting for location…")
                        .font(.subheadline)
                        .padding()
                    Spacer()
                }
            }

            Spacer().frame(height: 5)
        }
        .background(Color.gray.opacity(0.3))
        .fontDesign(.monospaced)
        .cornerRadius(15)
        .padding()
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.subheadline)
                .padding()
            Spacer()
            Text(value)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding()
        }
    }

    private func countdownRow(times: Solar.Times, now: Date, lat: Double, lon: Double, alt: Double) -> some View {
        let (label, target) = Self.nextEvent(times: times, now: now, lat: lat, lon: lon, alt: alt)
        return HStack(alignment: .top) {
            Text("Countdown")
                .font(.subheadline)
                .padding()
            Spacer()
            Group {
                if let target {
                    Text("\(Self.countdownString(target.timeIntervalSince(now))) to \(label)")
                        .fontWeight(.semibold)
                } else if times.isPolarDay {
                    Text("Sun up all day")
                } else if times.isPolarNight {
                    Text("Polar night")
                } else {
                    Text("—")
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding()
        }
    }

    /// The next horizon crossing to count down to: today's sunrise, then
    /// today's sunset, then tomorrow's sunrise. `nil` target under the
    /// polar day/night degenerate cases.
    private static func nextEvent(times: Solar.Times, now: Date,
                                  lat: Double, lon: Double, alt: Double) -> (String, Date?) {
        if let sunrise = times.sunrise, now < sunrise { return ("sunrise", sunrise) }
        if let sunset = times.sunset, now < sunset { return ("sunset", sunset) }
        if times.isPolarDay || times.isPolarNight { return ("", nil) }
        // Advance one *local* day (DST-aware) rather than a fixed 86 400 s,
        // which would skip a day in the late evening before a spring-forward.
        let tomorrowDate = Calendar.current.date(byAdding: .day, value: 1, to: now)
            ?? now.addingTimeInterval(86_400)
        let tomorrow = Solar.times(date: tomorrowDate, latitude: lat, longitude: lon, altitude: alt)
        if let sunrise = tomorrow.sunrise { return ("sunrise", sunrise) }
        return ("", nil)
    }

    private static func timeString(_ date: Date?) -> String {
        guard let date else { return "—" }
        return timeFormatter.string(from: date)
    }

    private static func rangeString(_ a: Date?, _ b: Date?) -> String {
        guard let a, let b else { return "—" }
        return "\(timeFormatter.string(from: a))–\(timeFormatter.string(from: b))"
    }

    private static func durationString(_ interval: TimeInterval?) -> String {
        guard let interval, interval > 0 else { return "—" }
        let total = Int(interval)
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }

    private static func countdownString(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m \(sec)s"
    }
}
