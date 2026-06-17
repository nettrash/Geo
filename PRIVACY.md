# Privacy Policy

**Effective date:** 17 June 2026
**Applies to:** Geo — the iOS app (with Apple Watch companion) published by nettrash on the App Store. This policy is versioned alongside the app's source code; the most recent commit on `main` is authoritative.

## TL;DR

Geo doesn't collect any personal information about you, doesn't create accounts, and doesn't use analytics, advertising, or trackers. The only data that ever leaves your device is what's necessary to render the things you ask the app to render: a few network requests to display the map, and an approximate-location query to OpenStreetMap when the app looks up nearby mountain peaks. Nothing is sent to servers operated by us — we have no servers.

## What the app accesses, and what each access does

**Location — when in use** (`NSLocationWhenInUseUsageDescription`). Granted via the system Location Services prompt the first time you open the Map or Nature tab. Used exclusively to:

1. Show your current position on the in-app map.
2. Compute distances and bearings to known peaks for the AR view and the "Nearby" list.
3. Build the Overpass / elevation queries described below.

The app uses *when-in-use* only — it does not request "Always" / background location.

**Camera** (`NSCameraUsageDescription`). Used by the AR view to overlay peak names on the camera feed. Frames are processed entirely on-device by ARKit; nothing is recorded or transmitted.

**Motion & Fitness** (`NSMotionUsageDescription`). Reads the device's barometer and motion sensors so the app can compute altitude (from atmospheric pressure) and stabilise AR peak labels. Sensor values stay on the device.

The Apple Watch companion app and Watch widget request only **Motion & Fitness** to read the Watch's barometer.

## What goes over the network

**OpenStreetMap Overpass API** (`https://overpass-api.de/api/interpreter`). When you open the Nature tab, the app sends an HTTPS request containing your approximate latitude/longitude and a search radius (typically 25–50 km) to fetch the list of nodes tagged `natural=peak` near you. The request body contains *only* those coordinates and the radius — no device identifiers, no IDFA, no account information. The Overpass API is a free, public service hosted by OpenStreetMap volunteers and governed by the [OpenStreetMap Foundation Privacy Policy](https://osmfoundation.org/wiki/Privacy_Policy).

**Apple MapKit.** The Map view uses MapKit to render map tiles and your-location pin. Apple is the data controller for those requests; data flow and Apple's use of it are governed by the [Apple Privacy Policy](https://www.apple.com/legal/privacy/) and the on-device privacy preferences you control in *Settings → Privacy & Security → Location Services → Maps*. MapKit on iOS doesn't require an API key and routes all requests through Apple's privacy-preserving infrastructure — Apple does not share your queries with third parties for advertising.

**Open-Meteo API** (`https://api.open-meteo.com`). The Nature/AR view fetches terrain elevation to draw the horizon skyline. Each request sends only approximate latitude/longitude (rounded to a ~110 m grid) — no device identifiers, no IDFA, no account information. Open-Meteo is a free, open API; its handling is governed by the [Open-Meteo Terms](https://open-meteo.com/en/terms).

That's the entire list. There are no other servers contacted. There is no telemetry, no crash reporter, no advertising network, no attribution provider, no remote analytics.

## Data stored on your device

**Pressure history** — the device's barometer is sampled periodically and the readings are stored in a local Core Data store inside the app's sandbox so the Stat tab and the home-screen widget can show altitude trends. This data never leaves the device, is not synced to iCloud, and is removed when you uninstall the app.

The Apple Watch companion stores its own pressure-history database locally on the Watch.

## App Tracking Transparency

Geo does not "track" you in the sense Apple's *App Tracking Transparency* framework defines: it does not link any data collected in the app with data from other apps, websites, or offline sources to build a user profile, and it does not share any data with data brokers. Geo therefore does not present an ATT prompt and is declared with an honest, narrowly-scoped privacy nutrition label on its App Store listing — see "Third-party services" below for the full picture.

## Third-party services

| Service | What it sees | Whose policy applies |
|---|---|---|
| Apple MapKit | Coarse position + viewport requests for tile rendering | Apple's |
| OpenStreetMap Overpass API | Approximate coordinates + search radius | OpenStreetMap Foundation's |
| Open-Meteo API | Approximate coordinates (~110 m grid) for terrain elevation | Open-Meteo's |
| Apple ARKit | Camera frames + IMU data, **on-device only** | Apple's |

Specifically NOT used: any third-party analytics SDK (Firebase, Mixpanel, Sentry, etc.), any advertising SDK (AdMob, Meta, AppLovin, etc.), any attribution / install-tracking SDK, any social-media SDK, any IDFA-consuming network.

## Children's privacy

Geo is rated **4+** and is suitable for all ages. We do not knowingly collect personal information from children, because we do not collect personal information from anyone.

## International data transfers

The Overpass API endpoint is a global service; requests may transit servers in any country. The data sent (coordinates + radius) does not contain personal data under GDPR Article 4(1) when used in this app — it's not combined with any identifier we hold. MapKit requests are routed through Apple's infrastructure under Apple's standard privacy controls.

## Your rights

Because we hold no data about you:

- There is no record to access under GDPR Article 15 / CCPA "right to know".
- There is no record to delete under GDPR Article 17 / CCPA "right to delete" (the local pressure history is yours alone — uninstalling the app removes it entirely).
- There is no record to correct under GDPR Article 16.
- There is nothing being sold or shared under CCPA / CPRA, so no opt-out is required.

For data flowing through the third-party services listed above, the respective providers' privacy operators are the right point of contact.

## Changes to this policy

If a future version of Geo changes any of the above — adds analytics, integrates a third-party SDK, adds a new network endpoint, or starts using a permission for a new purpose — this document will be updated *in the same release* and the *Effective date* will be bumped. Full history: <https://github.com/nettrash/Geo/commits/main/PRIVACY.md>.

## Contact

Privacy questions: **nettrash@nettrash.me**.
