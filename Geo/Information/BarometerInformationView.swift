//
//  BarometerInformationView.swift
//  Geo
//
//  Created by nettrash on 18/06/2024.
//

import SwiftUI

struct BarometerInformationView: View {
    @State var barometer: Barometer?;
    /// History supplies the de-trended 3-hour pressure tendency (M5a)
    /// rendered as the trend chip below; `nil` in previews.
    @State var history: History?
    @State private var showCalibrationSheet = false

    var body: some View {
        ZStack {
            Text("B A R O M E T E R")
                .opacity(0.2)
                .font(.title)
                .rotationEffect(.degrees(-25))
                .padding()

            VStack {

                HStack(alignment: .top) {
                    Text("Pressure")
                        .font(.subheadline)
                        .padding()
                    Spacer()
                    VStack {
                        Text(verbatim: "\(String(format: "%.4f", barometer?.pressure ?? 0.0)) kPa")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(verbatim: "\(String(format: "%.4f", (barometer?.pressure ?? 0.0) * 7.50062)) mm Hg")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(verbatim: "\(String(format: "%.4f", (barometer?.pressure ?? 0.0) / 101.325)) atm")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding()
                }

                if let trend = history?.latestPressureTrend, trend.classification != .unknown {
                    HStack(alignment: .top) {
                        Text("3 h trend")
                            .font(.subheadline)
                            .padding()
                        Spacer()
                        Text(Self.trendLabel(trend))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(Self.trendColor(trend.classification))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding()
                    }
                }

                HStack(alignment: .top) {
                    Text("Altitude")
                        .font(.subheadline)
                        .padding()
                    Spacer()
                    VStack {
                        Text(verbatim: "\(String(format: "%.0f", barometer?.height ?? 0.0)) m")
                        if barometer?.isManuallyCalibrated == true {
                            Text("calibrated")
                                .font(.caption2)
                                .foregroundStyle(Color.green)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        } else if let state = barometer?.calibrationState, state != .calibrated {
                            Text(state == .calibrating ? "calibrating…" : "uncalibrated")
                                .font(.caption2)
                                .foregroundStyle(state == .calibrating ? Color.orange : Color.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .padding()
                }

                HStack(alignment: .top) {
                    Text("% Everest")
                        .font(.subheadline)
                        .padding()
                    Spacer()
                    VStack {
                        Text(verbatim: "\(String(format: "%.4f", (barometer?.everest ?? 0.0) * 100.0)) %")
                    }
                    .padding()
                }
                
                Button {
                    showCalibrationSheet = true
                } label: {
                    Label(barometer?.isManuallyCalibrated == true ? "Recalibrate altitude" : "Calibrate altitude",
                          systemImage: "scope")
                        .font(.caption)
                }
                .padding(.bottom, 8)

                Spacer()
                    .frame(height: 5)
            }
            .background(
                Color.gray.opacity(0.3)
            )
            .fontDesign(.monospaced)
            .cornerRadius(15)
            .padding()
        }
        .sheet(isPresented: $showCalibrationSheet) {
            CalibrateAltitudeSheet(barometer: barometer)
        }
    }

    /// Short label for the de-trended 3-hour tendency, including the
    /// magnitude for the alert-worthy classes.
    private static func trendLabel(_ trend: PressureTrend) -> String {
        switch trend.classification {
        case .fallingFast:
            return String(format: "↓↓ Falling fast (%.0f hPa)", abs(trend.changeHPaOver3h))
        case .falling:
            return String(format: "↓ Falling (%.0f hPa)", abs(trend.changeHPaOver3h))
        case .steady:
            return "→ Steady"
        case .rising:
            return String(format: "↑ Rising (%.0f hPa)", abs(trend.changeHPaOver3h))
        case .unknown:
            return ""
        }
    }

    private static func trendColor(_ cls: PressureTrendClass) -> Color {
        switch cls {
        case .fallingFast: return .red
        case .falling:     return .orange
        case .rising:      return .green
        case .steady, .unknown: return .secondary
        }
    }
}

/// "I am at X m" sheet: pins the altimeter to a known elevation by storing a
/// decaying delta on `Barometer.height`. Reachable from the barometer card.
private struct CalibrateAltitudeSheet: View {
    let barometer: Barometer?
    @Environment(\.dismiss) private var dismiss
    @State private var input: String = ""

    private var parsed: Double? {
        guard let v = Double(input.replacingOccurrences(of: ",", with: ".")) else { return nil }
        return (v > -500 && v < 9000) ? v : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Current altitude",
                                   value: "\(Int((barometer?.height ?? 0).rounded())) m")
                    HStack {
                        Text("I am at")
                        TextField("metres", text: $input)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                        Text("m")
                    }
                    if barometer?.canCalibrate != true {
                        Label("Waiting for a barometer reading…", systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Pin the altimeter to a known elevation (a trailhead or summit marker) for instant, weather-proof, offline accuracy. The calibration decays over ~\(Int(Atmosphere.calibrationDecayHours)) h as weather drifts.")
                }

                if barometer?.isManuallyCalibrated == true {
                    Section {
                        Button("Clear calibration", role: .destructive) {
                            barometer?.clearCalibration()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Calibrate altitude")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Set") {
                        if let value = parsed {
                            barometer?.calibrate(toAltitude: value)
                            dismiss()
                        }
                    }
                    .disabled(parsed == nil || barometer?.canCalibrate != true)
                }
            }
        }
    }
}

#Preview {
    BarometerInformationView(barometer: nil, history: nil)
}
