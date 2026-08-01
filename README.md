# Geo

![build](https://github.com/nettrash/Geo/actions/workflows/ios.yml/badge.svg)

iOS + Apple Watch app for tracking your geographical state in real time: GPS coordinates, satellite (GPS) altitude, barometric altitude, atmospheric pressure, and an augmented-reality view of nearby mountain peaks.

All sensor history stays on your device. There are no analytics, no accounts, no servers operated by us — see [PRIVACY.md](PRIVACY.md) for the full breakdown. The only outbound calls are to public peak/elevation services (OpenStreetMap Overpass, Open-Meteo) and to NOAA SWPC for the planetary K index — a fixed URL with no parameters, carrying nothing about you. Your coordinates are quantised to a ~110 m grid before any peak or elevation request, and are not part of the NOAA request at all.

## Features

- **Info** — current coordinates, satellite altitude, barometer altitude, pressure and "% Everest". When the altitude is the weather-biased pressure estimate rather than Apple's calibrated value, a small **calibrating… / uncalibrated** cue says so.
- **Stat** — on-device history of pressure and altitude, plotted over time (anchored to a rolling 30-day window). Old points are auto-pruned and a **Clear history** action wipes it on demand.
- **Map** — your position on an Apple MapKit map with pins for nearby peaks, history points, the Seven Summits and the Snow Leopard peaks.
- **Nature** — AR view that overlays the names of nearby mountain peaks on the camera feed against a horizon line with cardinal (N/E/S/W) markers, showing only the summits actually above your horizon. A min-altitude slider hides smaller hills, and a shutter button captures the labelled view. Peak data comes from the OpenStreetMap Overpass API and ground elevations from Open-Meteo; downloaded offline packs let peaks appear out to ~80 km with no signal.
- **Apple Watch companion** — barometer-driven altitude (calibrated against the iPhone's reference) with its own on-device history.
- **Home-screen & Watch widgets** — current altitude and pressure at a glance, with a staleness cue when the data is old.

The app ships in **English only**.

## Platforms

- iOS 26+ (iPhone with barometer recommended)
- watchOS 26+ (Apple Watch with barometer recommended)
- Built with SwiftUI, Core Data (+ your private CloudKit), Core Location, Core Motion, MapKit and ARKit.

## Build

Open [Geo.xcodeproj](Geo.xcodeproj) in **Xcode 26 or newer** (the project targets the iOS 26 SDK) and build the `Geo` scheme for an iPhone, or the `Geo Watch App` scheme for an Apple Watch. A physical device is required to exercise the barometer, AR and location features.

```sh
# build
xcodebuild build -project Geo.xcodeproj -scheme Geo \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
# unit tests
xcodebuild test  -project Geo.xcodeproj -scheme Geo -only-testing:GeoTests \
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
```

## Calculation

When the device and OS provide a **weather-calibrated absolute altitude** — Apple's `CMAltimeter` absolute-altitude stream on a barometer-equipped iPhone — Geo uses it directly; it already compensates for the day's weather. Otherwise it derives altitude from raw atmospheric pressure.

The starting point is the hydrostatic/barometric relation:

$$P = P_0\, e^{\,-\frac{M g h}{R T}}$$

| Symbol | Meaning | Value / Unit |
| --- | --- | --- |
| $P_0$ | Pressure at sea level | Pa |
| $P$ | Pressure at height $h$ | Pa |
| $h$ | Altitude above sea level | m |
| $M$ | Molar mass of dry air | $0.029\ \mathrm{kg/mol}$ |
| $g$ | Gravitational acceleration | $9.81\ \mathrm{m/s^2}$ |
| $R$ | Universal gas constant | $8.31446\ \mathrm{J/(mol\,K)}$ |
| $T_0$ | Sea-level temperature | $288.15\ \mathrm{K}\ (15\ \mathrm{°C})$ |
| $L$ | Tropospheric lapse rate | $0.0065\ \mathrm{K/m}$ |

For the pressure-derived fallback Geo uses the **international barometric (lapse-rate) formula**, which models a troposphere whose temperature falls linearly with height rather than assuming a constant temperature. Solving that model for altitude gives:

$$h = \frac{T_0}{L}\left(1 - \left(\frac{P}{P_0}\right)^{\frac{R L}{g M}}\right) = 44330\left(1 - \left(\frac{P}{P_0}\right)^{\frac{1}{5.255}}\right)$$

with $T_0/L = 44330$, the exponent $\frac{R L}{g M} = \frac{1}{5.255}\approx 0.1903$, and $P_0 = 101.325\ \mathrm{kPa}$ (standard sea-level pressure, replaced by a fetched **QNH** when available). This is materially more accurate at altitude than the older constant-temperature approximation.

Before the calculation, incoming pressure is **clamped to 300–1100 hPa** so a single bad sensor sample can't produce a NaN or wildly out-of-range value. The same helper is used on every surface — app, widget, Watch screen and complication — so they always report the same altitude. "% Everest" is simply $h / 8848.86\ \mathrm{m}$.

## Compass Points

Bearings (degrees clockwise from true north) are bucketed into eight points:

| Point | From (°) | To (°) |
| --- | --- | --- |
| North | 338 | 22 |
| North-East | 23 | 67 |
| East | 68 | 112 |
| South-East | 113 | 157 |
| South | 158 | 202 |
| South-West | 203 | 247 |
| West | 248 | 292 |
| North-West | 293 | 337 |

The North bucket wraps across 360°/0°. Each bucket spans 45°, centred on its cardinal or inter-cardinal direction.
