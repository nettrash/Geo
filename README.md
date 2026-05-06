# Geo

![build](https://github.com/nettrash/Geo/actions/workflows/ios.yml/badge.svg)

iOS + Apple Watch app for tracking your geographical state in real time: GPS coordinates, satellite altitude, barometric altitude, atmospheric pressure, weather, reverse-geocoded address, and an augmented-reality view of nearby mountain peaks.

All sensor history stays on your device. There are no analytics, no accounts, no servers operated by us — see [PRIVACY.md](PRIVACY.md) for the full breakdown.

## Features

- **Info** — current coordinates, satellite altitude, barometer altitude, pressure, weather and the reverse-geocoded place name.
- **Stat** — local history of pressure and altitude readings, plotted over time.
- **Map** — your position on an Apple MapKit map with pins for nearby peaks, history points, the Seven Summits and the Snow Leopard peaks.
- **Nature** — AR view that overlays the names of nearby mountain peaks on the camera feed, plus a "Nearby" list with distance, bearing and elevation. Peak data is fetched on demand from the OpenStreetMap Overpass API.
- **Apple Watch companion** — barometer-driven altitude with its own on-device history.
- **Home-screen & Watch widgets** — current altitude and pressure at a glance.

## Platforms

- iOS 17+ (iPhone with barometer recommended)
- watchOS 10+ (Apple Watch with barometer recommended)
- Built with SwiftUI, Core Data, Core Location, Core Motion, MapKit and ARKit.

## Build

Open [Geo.xcodeproj](Geo.xcodeproj) in Xcode 15 or newer and build the `Geo` scheme for an iOS device, or the `Geo Watch App` scheme for an Apple Watch. A physical device is required to exercise the barometer, AR and location features.

## Calculation

Altitude is derived from atmospheric pressure using the barometric formula:

$$P = P_0\, e^{\,-\frac{M g h}{R T}}$$

| Symbol | Meaning | Value / Unit |
| --- | --- | --- |
| $P_0$ | Pressure at sea level | Pa |
| $P$ | Pressure at height $h$ | Pa |
| $h$ | Altitude above sea level | m |
| $M$ | Molar mass of dry air | $0.029\ \mathrm{kg/mol}$ |
| $g$ | Gravitational acceleration | $9.81\ \mathrm{m/s^2}$ |
| $R$ | Universal gas constant | $8.31446\ \mathrm{J/(mol\,K)}$ |
| $T$ | Absolute air temperature | $T = 273.15 + t\ (\mathrm{K})$ |
| $t$ | Air temperature | °C |

Solving for the altitude at a known pressure:

$$\frac{P}{P_0} = e^{\,-\frac{M g h}{R T}}\ \Rightarrow\ \ln\frac{P}{P_0} = -\frac{M g h}{R T}\ \Rightarrow\ h = \frac{R T}{-M g}\,\ln\frac{P}{P_0} = \frac{R T}{M g}\,\ln\frac{P_0}{P}$$

A common engineering approximation (valid in the troposphere, around standard temperature) is:

$$P_h = P_0 \cdot 10^{-0.000052\,h}$$

which inverts to:

$$h = \frac{\lg \frac{P_0}{P_h}}{0.000052} = \frac{\ln \frac{P_0}{P_h}}{0.000052 \cdot \ln 10} \approx \frac{\ln \frac{P_0}{P_h}}{0.00012}$$

using the identities $\lg x = \dfrac{\ln x}{\ln 10}$ and $\log\dfrac{x}{y} = -\log\dfrac{y}{x}$.

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
