//
//  MagneticInformationView.swift
//  Geo
//
//  The Magnetic Conditions card and its "What this means" explainer sheet,
//  both in one file (the `CalibrateAltitudeSheet` precedent in
//  `BarometerInformationView`). Five rows: Field, Compass, GPS, Aurora,
//  Magnetic lat — against the app's verified 8-row ceiling on `SolarInformationView`.
//
//  Everything on the card except the Kp number itself is computed on-device by
//  `Geomagnetic` from the user's own position, which is why the card still
//  says something useful with the network gone: "you are at 53.3° magnetic
//  latitude, the aurora needs about Kp 5+ here" never needed the network.
//
//  So the card degrades by row, not as a block. The three rows that exist only
//  because a Kp arrived — Field, Compass, GPS — go together when there is none;
//  the rows that describe the PLACE stay.
//
//  The copy is bound by the honesty contract at the top of `Geomagnetic.swift`.
//  In particular: no brightness adjective anywhere, no decimal Kp threshold,
//  no GPS error in metres, no aurora verdict at all when the correction grid
//  failed to load, and nothing on this card is ever presented as something
//  this handset measured.
//
//  Mirrored by Android `ui/info/MagneticSection.kt`.
//

import SwiftUI
import CoreLocation

struct MagneticInformationView: View {
    @State var location: Location?
    /// Owner of the one network call and the bundled correction grid. `nil` in
    /// previews, which is a supported state: the card then renders exactly what
    /// it renders offline.
    var weather: SpaceWeatherService?
    /// Handed upward so the peak-bearing rows on the mountain cards can show
    /// the G3+ heading caption without a second fetch and without a second
    /// copy of this state. Fires on load and when the fix moves — not on the
    /// minute tick, because neither G nor the compass band depends on the
    /// clock.
    var onConditionsChange: ((MagneticConditions) -> Void)?

    @State private var series: KpSeries?
    @State private var grid: MLatDeltaGrid?
    /// Distinct from `grid == nil` only in intent: false means the shipped
    /// asset did not decode, which suppresses the Aurora and Magnetic-lat rows
    /// rather than falling back to the raw dipole.
    @State private var gridDecoded = true
    /// True only while our own `refreshIfStale` is awaiting. Combined with an
    /// empty `series` it is the card's "loading" tier — one extra line, never
    /// a spinner and never a block.
    @State private var isRefreshing = false
    @State private var showExplainer = false

    var body: some View {
        ZStack {
            Text("M A G N E T I C")
                .opacity(0.2)
                .font(.title)
                .rotationEffect(.degrees(-25))
                .padding()

            // Minute cadence, as on the Sun card: it rolls the "fetched 9 h ago"
            // footer and tonight's darkness window over without a new fix, and
            // without recomputing the oval math once a second.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                content(now: context.date)
            }
        }
        .task { await load() }
        .onChange(of: fixKey) { _, _ in publish() }
        .sheet(isPresented: $showExplainer) {
            MagneticConditionsSheet()
        }
    }

    // MARK: - State

    /// Coarse identity of the current fix on the same ~110 m grid the peak and
    /// elevation lookups use, so the mountain cards are re-published when the
    /// user actually moves rather than on every GPS jitter.
    private var fixKey: String? {
        guard let coordinate = location?.location?.coordinate else { return nil }
        return TerrainElevationService.gridKey(coordinate)
    }

    private func load() async {
        guard let weather else { return }
        apply(await weather.snapshot())
        publish()

        isRefreshing = true
        await weather.refreshIfStale()
        isRefreshing = false

        apply(await weather.snapshot())
        publish()
    }

    private func apply(_ snapshot: SpaceWeatherSnapshot) {
        series = snapshot.series
        grid = snapshot.grid
        gridDecoded = snapshot.grid != nil
    }

    private func publish() {
        onConditionsChange?(evaluate(now: Date()))
    }

    /// The whole card in one pure call. Cheap enough to run per minute: the
    /// only unbounded part is the polar-summer "when does darkness return"
    /// search, and that only runs where there is no dark window at all.
    private func evaluate(now: Date) -> MagneticConditions {
        let coordinate = location?.location?.coordinate
        return Geomagnetic.conditions(series: series,
                                      latitude: coordinate?.latitude,
                                      longitude: coordinate?.longitude,
                                      grid: grid,
                                      now: now)
    }

    // MARK: - Card

    @ViewBuilder
    private func content(now: Date) -> some View {
        let conditions = evaluate(now: now)
        VStack(spacing: 0) {
            Spacer().frame(height: 10)

            fieldRow(conditions)
            compassRow(conditions)
            gpsRow(conditions)
            auroraRow(conditions)
            magneticLatitudeRow(conditions)
            footer(conditions)

            Spacer().frame(height: 5)
        }
        .background(Color.gray.opacity(0.3))
        .fontDesign(.monospaced)
        .cornerRadius(15)
        .padding()
    }

    private func row(_ label: String, _ value: String,
                     tint: Color? = nil, caption: String? = nil) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.subheadline)
                .padding(.horizontal)
                .padding(.vertical, 4)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: value)
                    .foregroundStyle(tint ?? Color.primary)
                if let caption {
                    Text(verbatim: caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .multilineTextAlignment(.trailing)
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Rows

    /// Whether the storm-derived rows — Field, Compass, GPS — have anything to
    /// say. All three read off the fetched Kp, so all three go together when
    /// there is none: `compass` and `gnss` fall back to the `.normal` and
    /// `.nominal` DEFAULTS on `MagneticConditions`, which read as a verdict
    /// rather than as the absence of one, and the reader they would reassure is
    /// the one offline in a G4 storm. The rows that describe the PLACE —
    /// magnetic latitude, the Kp the aurora needs here, tonight's darkness
    /// window, the bearing to the pole — never needed the network and stay.
    /// Android gates the same three rows on the same value.
    static func showsStormDerivedRows(_ conditions: MagneticConditions) -> Bool {
        conditions.kpNow != nil
    }

    /// Hidden entirely when there is no Kp. An em dash on a row labelled
    /// "Field" would read as a measurement we failed to take, and there is no
    /// measurement here at all — the number comes from NOAA's ground
    /// observatory network.
    @ViewBuilder
    private func fieldRow(_ conditions: MagneticConditions) -> some View {
        if let kp = conditions.kpNow {
            row("Field",
                Self.fieldValue(kp: kp, gScale: conditions.gScale),
                tint: Self.severityTint(conditions.gScale),
                caption: Self.fieldCaption(conditions))
        }
    }

    /// Hidden with the Field row. "Compass: Normal" printed above a footer that
    /// says there is no space-weather data is reassurance from data we do not
    /// have.
    @ViewBuilder
    private func compassRow(_ conditions: MagneticConditions) -> some View {
        if Self.showsStormDerivedRows(conditions) {
            row("Compass",
                Self.compassValue(conditions.compass),
                caption: Self.compassCaption(conditions.gScale))
        }
    }

    /// Hidden with the Field row, and for the same reason: the GNSS advisory
    /// reads the G scale, which is G0 whenever there is no Kp — so "Nominal"
    /// offline is the default speaking, not a verdict.
    @ViewBuilder
    private func gpsRow(_ conditions: MagneticConditions) -> some View {
        if Self.showsStormDerivedRows(conditions) {
            row("GPS", Self.gnssValue(conditions.gnss))
        }
    }

    @ViewBuilder
    private func auroraRow(_ conditions: MagneticConditions) -> some View {
        if !gridDecoded {
            // Never-claim item 12: no verdict at all rather than one from the
            // raw dipole, which is +5.63° in London — two and a half whole Kp
            // steps of over-promising, in the direction that costs the user a
            // night out on a cold hill.
            row("Aurora", "Unavailable — data file missing")
        } else if location?.location == nil {
            row("Aurora", "Waiting for location…")
        } else if !conditions.aurora.hasDarkness,
                  let returns = conditions.aurora.nextDarknessDate {
            // Polar summer. The oval may well be overhead; it is also broad
            // daylight, so the verdict is the one fact that matters.
            row("Aurora", "No astronomical darkness here until \(Self.dayFormatter.string(from: returns))")
        } else {
            row("Aurora",
                Self.auroraValue(conditions),
                caption: Self.auroraCaption(conditions))
        }
    }

    /// The row that explains why two users see different verdicts at the same
    /// Kp. Needs no network, so it survives every degraded state — but it is
    /// hidden along with the aurora verdict when the grid failed, because the
    /// only number we could print there would be the wrong one.
    @ViewBuilder
    private func magneticLatitudeRow(_ conditions: MagneticConditions) -> some View {
        if gridDecoded, let mlat = conditions.magneticLatitudeDeg {
            row("Magnetic lat", String(format: "%.1f° %@", abs(mlat), mlat >= 0 ? "N" : "S"))
        }
    }

    private func footer(_ conditions: MagneticConditions) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if isRefreshing && series == nil {
                Text("Checking…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: Self.footerText(conditions))
                Spacer(minLength: 8)
                Button {
                    showExplainer = true
                } label: {
                    Text("What this means ›")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    // MARK: - Field

    private static func fieldValue(kp: Double, gScale: GScale) -> String {
        let kpText = String(format: "Kp %.1f", kp)
        guard let name = severityName(gScale) else { return "\(kpText) · below storm levels" }
        return "\(kpText) · G\(gScale.rawValue) \(name)"
    }

    /// NOAA's own names for the G levels. G0 has none — it is the 93 % of days
    /// on which nothing is happening, and the card says so in words rather
    /// than inventing a label for calm.
    private static func severityName(_ g: GScale) -> String? {
        switch g {
        case .g0: return nil
        case .g1: return "Minor"
        case .g2: return "Moderate"
        case .g3: return "Strong"
        case .g4: return "Severe"
        case .g5: return "Extreme"
        }
    }

    /// Severity ramp, the same five colours the Android card uses so a
    /// screenshot from either platform reads identically. Deliberately not the
    /// system semantic colours: this is a scale, not a good/bad verdict.
    private static func severityTint(_ g: GScale) -> Color {
        switch g {
        case .g0: return Color(red: 0.690, green: 0.745, blue: 0.773)   // #B0BEC5
        case .g1: return Color(red: 0.263, green: 0.627, blue: 0.278)   // #43A047
        case .g2: return Color(red: 1.000, green: 0.757, blue: 0.027)   // #FFC107
        case .g3: return Color(red: 1.000, green: 0.596, blue: 0.000)   // #FF9800
        case .g4, .g5: return Color(red: 0.898, green: 0.224, blue: 0.208)   // #E53935
        }
    }

    private static func fieldCaption(_ conditions: MagneticConditions) -> String? {
        guard let provenance = conditions.kpProvenance,
              let start = conditions.binStart else { return nil }
        return "\(provenanceWord(provenance)), \(binRange(start))"
    }

    /// SWPC's `predicted` is surfaced as "forecast" — the word a hiker reads
    /// without a glossary, and the one that conveys "this is not final" in the
    /// same breath as the number.
    private static func provenanceWord(_ provenance: KpProvenance) -> String {
        switch provenance {
        case .observed:  return "observed"
        case .estimated: return "estimated"
        case .predicted: return "forecast"
        }
    }

    /// "21–00 UT": the 3-hour bin the value came from. UTC because that is the
    /// frame SWPC publishes in and the only one that means the same thing to
    /// every reader of the same number.
    private static func binRange(_ start: Date) -> String {
        let end = start.addingTimeInterval(Geomagnetic.kpBinHours * 3600)
        return "\(utcHourFormatter.string(from: start))–\(utcHourFormatter.string(from: end)) UT"
    }

    // MARK: - Compass

    private static func compassValue(_ band: CompassBand) -> String {
        switch band {
        case .normal:    return "Normal"
        case .underOne:  return "Storm adds under 1° here"
        case .oneToTwo:  return "Storm adds 1–2° here"
        case .twoToFive: return "Storm adds 2–5° here"
        case .overFive:  return "Storm adds over 5° here"
        }
    }

    /// The caption is the point of this row at G3+: the figure beside it is
    /// smaller than the error the phone's own compass already carries, and the
    /// copy has to say so rather than let the reader assume otherwise
    /// (never-claim item 9). At G5 it is replaced by NOAA's own statement
    /// about its model, which is a stronger and more specific warning.
    private static func compassCaption(_ g: GScale) -> String? {
        if g >= .g5 { return "NOAA advises the magnetic model should not be used during a G5 event." }
        if g.rawValue >= Geomagnetic.compassAdvisoryMinG { return "Your compass's own error is larger than this." }
        return nil
    }

    // MARK: - GPS

    /// Directional, never a number: every iPhone since the XS is
    /// dual-frequency and cancels first-order ionospheric delay, so NOAA's
    /// single-frequency "tens of metres" figures are simply wrong for most
    /// readers. The metres live in the explainer with their conditions
    /// attached (never-claim item 10).
    private static func gnssValue(_ advisory: GNSSAdvisory) -> String {
        switch advisory {
        case .nominal:    return "Nominal"
        case .mayDegrade: return "May degrade — trust the barometer for altitude"
        case .degraded:   return "Degraded — trust the barometer, and carry a map"
        }
    }

    // MARK: - Aurora

    private static func auroraValue(_ conditions: MagneticConditions) -> String {
        let aurora = conditions.aurora
        let threshold = conditions.magneticLatitudeDeg
            .flatMap { Geomagnetic.requiredKpLabel(magneticLatitudeDeg: $0) }

        switch aurora.visibility {
        case .overhead:
            return "Oval overhead — look up"
        case .ovalReaches:
            return aurora.isNorthernHemisphere
                ? "Oval reaches you — look north"
                : "Oval reaches you — look south"
        case .horizonGlow:
            // "Possible", and no brightness adjective: the model is a
            // geometric reachability check with no brightness term at all.
            return aurora.isNorthernHemisphere
                ? "Possible glow low on the northern horizon"
                : "Possible glow low on the southern horizon"
        case .notVisible:
            guard let threshold else { return "Not visible from here at any Kp" }
            return "Not visible from here — needs \(threshold)"
        case .unknown:
            // No current Kp — an expired cache, or none fetched yet. The
            // threshold does not depend on Kp, so this half of the card
            // survives going offline, which is the whole reason the row stays.
            guard let threshold else { return "Not visible from here at any Kp" }
            return "Needs \(threshold) from here"
        }
    }

    private static func auroraCaption(_ conditions: MagneticConditions) -> String? {
        let aurora = conditions.aurora
        var line: [String] = []

        if let start = aurora.windowStart, let end = aurora.windowEnd {
            line.append("\(timeFormatter.string(from: start))–\(timeFormatter.string(from: end))")
        }

        let reachable = aurora.visibility != .unknown && aurora.visibility != .notVisible
        if reachable, let bearing = aurora.poleBearingDeg {
            // Which way to face, not where the aurora is: this is the bearing
            // to the magnetic pole of the observer's own hemisphere.
            var look = "look \(compassPhrase(bearing))"
            if aurora.visibility == .horizonGlow { look += ", low" }
            line.append(look)
        }

        var caption = line.joined(separator: " · ")

        if aurora.visibility == .horizonGlow, let rangeKm = aurora.rangeKm {
            // Rounded to 10 km. A metre-precise distance to a modelled oval
            // edge that ignores magnetic local time would be false precision.
            let rounded = Int((rangeKm / 10).rounded()) * 10
            let direction = aurora.isNorthernHemisphere ? "north" : "south"
            let note = "~\(rounded) km \(direction) of you — needs a clear, open horizon"
            caption = caption.isEmpty ? note : caption + "\n" + note
        }

        return caption.isEmpty ? nil : caption
    }

    /// "N 15° W" — the deviation from the nearer of true north or true south,
    /// so a southern-hemisphere reader gets "S 9° E" rather than a bearing in
    /// the 180s they have to subtract in their head.
    private static func compassPhrase(_ bearing: Double) -> String {
        let wrapped = bearing.truncatingRemainder(dividingBy: 360)
        let positive = wrapped < 0 ? wrapped + 360 : wrapped
        let southerly = positive > 90 && positive < 270
        var offset = positive - (southerly ? 180 : 0)
        if offset > 180 { offset -= 360 }
        if offset < -180 { offset += 360 }

        let letter = southerly ? "S" : "N"
        let degrees = Int(abs(offset).rounded())
        if degrees == 0 { return letter }
        return "\(letter) \(degrees)° \(offset > 0 ? "E" : "W")"
    }

    // MARK: - Footer

    /// Always NOAA SWPC and the payload's OWN timestamp — never our fetch time
    /// dressed up as an observation, and never the word "official".
    private static func footerText(_ conditions: MagneticConditions) -> String {
        switch conditions.freshness {
        case .live:
            guard let start = conditions.binStart else { return noDataFooter }
            return "NOAA SWPC · \(utcTimeFormatter.string(from: start)) UTC"
        case .cached:
            // A cached tier only exists because a bin still CONTAINS now, and
            // a bin that covers now in a copy fetched hours ago was a forecast
            // row when it was fetched. So the footer says forecast: it is what
            // the reader is looking at, and "cached 61 h ago" reads like a
            // stale observation of something that has not happened yet.
            guard let age = conditions.dataAge else { return noDataFooter }
            return "NOAA SWPC forecast · fetched \(agePhrase(age)) ago"
        case .expired, .none:
            return noDataFooter
        }
    }

    /// "9 h" inside the first day, "3 d" after it. A cached copy can now be
    /// days old — its own forward coverage is what expires it, not the clock —
    /// and "61 h" is a number the reader has to divide before it means
    /// anything.
    private static func agePhrase(_ age: TimeInterval) -> String {
        let hours = age / 3600
        if hours < 24 { return "\(Int(hours.rounded())) h" }
        return "\(Int((hours / 24).rounded())) d"
    }

    /// The offline tier says what it is: this is a network feature with an
    /// offline fallback, and the copy never claims "no network required"
    /// (never-claim item 16).
    private static let noDataFooter = "No space-weather data — showing what Geo computes on-device"

    // MARK: - Formatters

    /// Local clock, `.short` like the Sun card, so both cards render times the
    /// same way and both honour the user's 12/24-hour preference.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let utcHourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH"
        return formatter
    }()

    private static let utcTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter
    }()
}

// MARK: - Explainer

/// "What this means": the long-form honesty surface for the card. Everything
/// the card cannot say in a row without over-claiming lives here, including
/// the one sourced sentence about health — which stays in this sheet and is
/// never promoted to a readout (never-claim items 6 and 7).
///
/// It also carries the one control the feature has: the opt-in aurora alerts
/// toggle. It lives behind the explainer on purpose — somebody who has read
/// what the verdict is and is not is the right person to be offered a
/// notification about it.
private struct MagneticConditionsSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Opt-in aurora alerts, default OFF — which is what makes "background
    /// network activity only ever happens after you ask for it" a true
    /// sentence about a fresh install. Written here, read by
    /// `GeoAppDelegate.evaluateAuroraAlert` on the app-refresh task, so the
    /// key and the store must be the same on both sides.
    ///
    /// Same deliberate `?? .standard` fallback as the alert cooldown: the flag
    /// is read and written only in the main app process, so it needs no
    /// cross-process sharing — and a nil store would silently drop the user's
    /// choice rather than persist it somewhere.
    @AppStorage(GeoAppDelegate.auroraAlertsEnabledKey,
                store: UserDefaults(suiteName: SharedSnapshotStore.appGroupID) ?? .standard)
    private var auroraAlertsEnabled = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    paragraph("""
                    Geomagnetic storms are disturbances in Earth's magnetic field driven by the \
                    solar wind. Geo shows only the three things a storm changes for a navigator.
                    """)

                    heading("COMPASS")
                    paragraph("""
                    Your compass points at magnetic north. The correction to true north — \
                    declination — comes from a model of the quiet field, and storms are not in \
                    that model. NOAA states its World Magnetic Model "should not be used during \
                    a G5 event". The figure on the card is a banded estimate of how far a storm \
                    can push your heading beyond normal declination error, at your magnetic \
                    latitude. It is an estimate, not a measurement, and below G5 it is smaller \
                    than the error your phone's compass already has.
                    """)
                    paragraph("""
                    Kp is quasi-logarithmic. Its linear equivalent, ap, runs from 48 at Kp 5 to \
                    400 at Kp 9.
                    """)
                    paragraph("""
                    Local iron routinely causes larger errors than any storm: ore bodies, \
                    vehicles, rebar, a pack frame, a phone case magnet. Declination anomalies of \
                    3–4 degrees from local geology are not uncommon and can exceed 10. That is \
                    not space weather.
                    """)

                    heading("GPS")
                    paragraph("""
                    Storms disturb the ionosphere. NOAA: single-frequency GPS errors "can \
                    increase to tens of meters or more" during a severe storm. Measured \
                    dual-frequency errors rose from about 0.16 m in quiet conditions to about \
                    1.05 m in super storms at high latitude, with far more cycle slips; at mid \
                    and low latitudes the same measurements stayed under 0.32 m throughout. \
                    Vertical error is typically 1.5 to 3 times the horizontal error — so during \
                    a storm your barometric altitude is the better number.
                    """)

                    heading("AURORA")
                    paragraph("""
                    The auroral oval moves roughly 2 degrees of magnetic latitude equatorward \
                    per step of Kp. Geo compares your magnetic latitude against that edge, then \
                    checks whether it gets dark enough where you are. A display 1000 km further \
                    poleward can still be seen as a glow on the horizon from an open summit — \
                    which is why the verdict has two levels.
                    """)
                    paragraph("""
                    The rule ignores magnetic local time, and the real oval dips further \
                    equatorward around magnetic midnight. Treat the Kp figure as plus or minus \
                    one Kp step, and expect the best displays within an hour or two of midnight. \
                    Cloud, light pollution and terrain are not modelled at all.
                    """)

                    heading("WHAT GEO DOES NOT DO")
                    // One verb off the design doc's draft, on purpose. The
                    // honesty contract bars that verb from the whole feature —
                    // copy, identifiers and log messages alike — so the
                    // sentence carries the same meaning without the word a
                    // later reader could take as licence to go and build it.
                    paragraph("""
                    Geo does not read a storm off your phone's magnetometer, and no app can. \
                    A phone magnetometer's noise floor is about 200 nT and does not average down \
                    with more samples; a G1 storm is about 100 nT at mid-latitude. A phone \
                    cannot tell a solar storm from a parked car. The Kp number here comes from \
                    NOAA's ground observatory network, not from this device.
                    """)
                    paragraph("""
                    Geo makes no health claims. The largest study of the question — 63 million \
                    posts across a solar maximum — found no link between geomagnetic activity \
                    and headaches.
                    """)

                    paragraph("""
                    Data: NOAA Space Weather Prediction Center (public domain). Geo is not \
                    affiliated with, or endorsed by, NOAA.
                    """)
                    .foregroundStyle(.secondary)

                    Divider()

                    // No permission prompt here, on purpose: authorization is
                    // asked for once at launch alongside the pressure warning,
                    // and if it was denied this toggle simply produces nothing
                    // rather than nagging. Turning it on arms no new task
                    // either — the check rides the app-refresh task the app
                    // already schedules, and stays a no-op while this is off.
                    Toggle(isOn: $auroraAlertsEnabled) {
                        Text("Aurora alerts")
                            .font(.callout)
                    }
                    paragraph("""
                    Off by default. When on, Geo checks the forecast a few times a day in the \
                    background and notifies you when the aurora could be visible from your \
                    location tonight.
                    """)
                    .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Magnetic conditions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.subheadline)
            .fontWeight(.semibold)
            .fontDesign(.monospaced)
    }

    private func paragraph(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    MagneticInformationView(location: nil, weather: nil)
}
