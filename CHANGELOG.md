# Changelog — Geo (iOS + watchOS)

All notable changes to Geo are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/). Versions are
`MARKETING_VERSION`; the build number auto-increments per build.

## [Unreleased]

### Changed
- **History points are no longer shown in the AR (Nature) scene** — they cluttered
  the camera view, so the AR overlay now shows only peaks and the skyline. Your
  recorded history is unchanged and still appears on the Map and Stat tabs. (Also
  drops their AR markers, tap targets, occlusion work and the on-screen counter.)

### Added
- **Peak labels welded to the terrain skyline** — in the Nature (AR) view, named
  peaks that form the horizon silhouette now float their name + elevation ("Mont
  Blanc 4808 m") right on the green ridge line, turning the abstract skyline into
  an **identified panorama**. Each peak is matched to the silhouette by apparent
  elevation angle — so peaks hidden behind nearer, higher terrain are skipped —
  and its label floats just clear of the ridge, joined to the exact silhouette
  point by a thin **leader line** (with a dot marking the spot) so the name reads
  cleanly off the line; nearer peaks win when labels would overlap. Tapping a
  floating label opens the peak's detail card — the tap target tracks the lifted
  pill, not the ridge underneath it. Reuses the skyline + peak data already
  computed (no new network), and the freeze-frame share card carries the labels
  (and leaders) too.
- **Summit log — auto-detect arrival at a known peak** — walk within ~500 m of a
  Seven Summit / Snow Leopard / other known peak and Geo offers to log the ascent
  (date, the peak's elevation, your measured barometric altitude, an optional note)
  — proximity-triggered with a manual confirm, never auto. A "Summits" trophy case
  on the Stat tab lists your logged ascents; each opens a detail with an editable
  note, Directions, Delete, and a **shareable summit card**. 100 % on-device,
  CloudKit-synced (new `SummitLog` Core Data entity, additive lightweight
  migration); only the peak's public location is stored or shared, never yours.
- **Tap-to-identify AR markers + freeze-frame share** — the Nature (AR) view is now
  explorable: tap any peak or history marker to open a detail card (name, altitude,
  distance, bearing, coordinates, plus a Directions button), via a screen-space
  nearest-marker hit-test against the same live projection that places the markers.
  A shutter button captures a **frozen, annotated panorama** — the live camera frame
  with the markers and skyline composited on top and a small "Geo" footer — and hands
  it to the system share sheet. 100 % on-device (`ARSCNView` snapshot + SwiftUI
  `ImageRenderer`); nothing is uploaded.

## [1.1] — 2026-06-14

A correctness, accuracy and reliability release: the calibrated altitude now
agrees across the phone, the home-screen widget, the Watch screen and the Watch
complication, plus 39 verified bug fixes and 24 improvements.

### Added
- **Known-elevation manual calibration** — pin the altimeter to a trailhead or
  summit marker ("I am at X m") from the Info barometer card for instant,
  weather-proof, offline accuracy. Inverts the barometric formula to back-solve
  the sea-level reference pressure; since `CMAltimeter` has no altitude setter the
  correction is stored as a decaying delta on the reading (in the app group, so the
  widget agrees). The pin decays over ~6 h as weather drifts and then reverts to the
  system value, so a stale calibration can't silently re-bias the altitude. A green
  "calibrated" badge shows while it's active. 100 % on-device.
- **Trip Recorder** — one tap on the Stat tab wraps the always-on sample stream
  into a named outing. Each trip shows total ascent/descent (with sub-3 m noise
  smoothed so the number doesn't inflate), max/min altitude, distance, moving time,
  and an elevation profile. 100 % on-device — the new `Trip` store auto-syncs via
  your private CloudKit, no server. A recording survives an app restart.
- **Peak bearing & compass arrow** — the closest- and highest-mountain cards now
  show the true bearing to the peak ("117° SE") with an arrow that rotates to your
  live heading, so it always points at the summit — a low-power, AR-free
  "point me toward it" finder. Includes a "calibrate compass" hint when the
  magnetometer drifts; the compass runs only while the Info tab is open.
- **Sun panel** — today's solar windows for your exact position **and altitude**:
  dawn, sunrise, golden hour (AM/PM), solar noon, sunset, dusk and day length, with
  a live "X h to sunset" countdown (rolling on to tomorrow's sunrise after dark).
  100 % on-device (NOAA solar algorithm); the altitude horizon-dip makes the sun
  rise earlier and set later from a summit. Polar day/night handled. For
  alpine-start planning, turning around before dark, and golden-hour photography.
- **Storm warning** — the classic mountaineering/sailing barometer use: a single
  advisory "pressure falling fast" local notification when the barometer drops
  sharply (the leading above-tree-line storm indicator). The 3-hour tendency is a
  least-squares fit over raw station pressure, **de-trended by GPS altitude** so a
  climb — which also drops pressure — never false-fires; it alerts once per onset
  (3-hour cooldown). A live 3-hour trend chip also appears on the Info barometer
  card. Notification permission is requested at first launch and a denial degrades
  silently; background timing is OS-throttled, so the alert is best-effort.
- Persistent, LRU-bounded on-device elevation cache — the AR terrain skyline now
  appears instantly on cold start and on offline revisits.
- "Calibrating… / uncalibrated" indicator on the barometer card, so you can tell
  when the altitude is the weather-biased estimate versus the calibrated value.
- History retention: automatic prune of points older than ~1 year, plus a
  **Clear history** action on the Stat tab.
- One jittered retry/backoff and request spacing on the public elevation/peak
  services (respecting `Retry-After`).

### Changed
- Altitude is derived with the international lapse-rate formula (materially more
  accurate at altitude) via a single shared helper, and one precise Everest
  constant (8848.86 m) is used everywhere.
- Live pressure is clamped to a sane window (300–1100 hPa) before deriving
  altitude, so a bad sensor sample can't produce NaN/huge values.
- Stat day-buckets are anchored to today; altitude-graph padding unified/tightened.
- AR internals: one shared GPS→ENU→world projection (renderer + occlusion), the
  camera matrices are no longer republished every frame, and the Overpass decode
  runs off the main actor.
- The app is **English-only**.

### Fixed
- Watch screen showed an **uncalibrated** altitude that contradicted its own
  complication — now uses the calibrated value handed to the callback.
- AR terrain skyline was computed at sea level until the first barometer sample
  (and permanently on non-barometer devices); AR marker occlusion used the wrong
  world point (camera offset omitted).
- Stat graphs went stale on tab re-entry; the below-sea-level reference line was
  gated on the wrong field; flat datasets caused a divide-by-zero; the Watch
  graph was seeded with ~19 zero points.
- The ~1 Hz Watch→phone barometer stream that flooded history (and CloudKit) is
  now throttled.
- `recordDate` is pinned to epoch-milliseconds on the wire (byte-compatible with
  the Android/Wear apps; legacy snapshots still decode), with a `recordDate`
  Core Data fetch index.
- Stale/low-quality first GPS fixes and phantom `(0,0)` points are no longer
  recorded; coordinate-less peaks are skipped in the nearest-search.
- Networking etiquette: descriptive `User-Agent` and a client-side timeout on the
  Overpass request; Open-Elevation responses are validated (implausible
  `≤ -430 m` / `0.0` rejected).
- …and the rest of the 39 verified fixes (dead-code removal, nil-guards,
  background sensor pausing, tracking/throttle-clock split, and more).

### Removed
- Russian localization — the app is English-only.

### Security
- (Android-only, tracked in that repo) the committed Google Maps API key was
  removed; not applicable to iOS, which uses MapKit.

[1.1]: https://github.com/nettrash/Geo
