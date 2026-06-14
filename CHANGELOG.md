# Changelog — Geo (iOS + watchOS)

All notable changes to Geo are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/). Versions are
`MARKETING_VERSION`; the build number auto-increments per build.

## [1.1] — 2026-06-14

A correctness, accuracy and reliability release: the calibrated altitude now
agrees across the phone, the home-screen widget, the Watch screen and the Watch
complication, plus 39 verified bug fixes and 24 improvements.

### Added
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
