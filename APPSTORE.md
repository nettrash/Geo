# App Store listing copy — Geo

Copy-paste source for App Store Connect. Field limits: Promotional Text ≤ 170
chars, Description ≤ 4000, What's New ≤ 4000, Keywords ≤ 100. Current release:
**1.3**.

---

## Promotional Text

Point your camera at the skyline and Geo names the peaks you see — with live altitude, a storm-warning barometer and offline peak maps for the trail.

---

## Description

Geo turns your iPhone and Apple Watch into a mountain instrument. Point the camera at the skyline and it names the peaks in front of you; check the Info tab for your exact altitude and the air pressure around you; and let the barometer warn you when the weather is about to turn.

NAME THE PEAKS YOU SEE
Hold up the camera in the Nature view and every mountain gets a label — its name and height — pinned to the real summit. Only the peaks actually above your horizon are shown, and a minimum-altitude slider hides the small hills so you can keep just the big mountains. Tap any peak for its distance, bearing and directions. Download an area first and it all keeps working with no signal, out to ~80 km.

KNOW YOUR ALTITUDE
Geo reads height from the iPhone's barometric sensor and satellite GPS, and shows how far you are up "% of Everest". Standing at a marked elevation — a trailhead sign or summit marker? Calibrate to it in one tap and every reading, including the widget and the Watch, snaps into agreement.

A BAROMETER THAT WARNS YOU
A falling barometer is the classic sign of incoming weather. Geo watches the 3-hour pressure trend — corrected for the altitude you've gained, so an ordinary climb doesn't read as falling weather — and sends a single storm-warning notification when pressure drops sharply. Treat it as one more sign to read alongside the sky, not a forecast: the altitude correction leans on a recent GPS fix, and background timing is up to iOS, so the warning is best-effort.

RECORD THE TRIP
Start the trip recorder for total ascent and descent, distance, moving time and an elevation profile. Log the summits you reach in a trophy case. Everything syncs privately across your devices through your own iCloud.

SUN & SKY
The Sun panel computes sunrise, sunset, golden hour, blue hour and civil twilight for exactly where you are and how high — no connection needed.

ON YOUR WRIST & HOME SCREEN
An Apple Watch app with its own barometric altitude and history, plus home-screen and Watch widgets and complications that show your current altitude at a glance.

PRIVATE BY DESIGN
No account. No ads. No trackers. Your altitude and pressure history, trips and summits stay on your device and sync only through your own private iCloud — never to any server we run. The only network calls render the map, look up nearby peak names and ground elevation, and fetch the planetary K index from NOAA, in a request that contains nothing about you.

Requires an iPhone with a barometric sensor for altitude readings; the Nature view needs a device that supports ARKit and a clear view toward the horizon. English only.

---

## What's New in This Version (1.3)

Nearby peaks you can rely on, even when the map server is struggling.

• Geo now asks three OpenStreetMap servers for nearby peaks instead of one, and moves on when a server is busy or slow. A busy server's empty reply is no longer mistaken for "there are no peaks here".
• The peaks Geo already knows appear straight away: the built-in mountains and any offline area you've downloaded. They show before the network answers and stay put if the search fails, so with no signal an offline area's peaks are there at once.
• Your last good list of nearby peaks is remembered on your device for up to a week. Reopening Geo without signal still shows your peaks, marked "possibly outdated" until a fresh answer arrives.
• The peak count now says how many peaks your minimum-altitude setting hides. If it hides them all, a pill says so and resets the setting in one tap. The slider also needs a deliberate drag now, so a stray tap can no longer hide every peak.
• A failed offline-area download no longer saves an empty area that looks like "no peaks here". Nothing is saved, and Geo tells you why. A failed update keeps the area you already had.
• The same summit no longer appears twice after a connection problem, and large offline areas no longer make the screen stall.

---

## Keywords

Comma-separated, no spaces (spaces count against the 100). Singular forms only —
the App Store matches plurals and combinations itself. Terms already in the app
name ("Geo") or the subtitle are wasted here. No trademarks: "OpenStreetMap",
"Apple Watch" and "NOAA" must not appear (2.3.7).

```
altimeter,barometer,altitude,elevation,peak,summit,mountain,hike,compass,aurora,offline,trail
```

93 / 100 chars. Seven spare for a seasonal swap — `ascent` (+7) fits exactly.
Deliberately omitted: "GPS" and "map" (generic, heavily contested, and the
Description already carries them for search); "AR" (two chars, matched anyway by
"augmented" in the Description).

---

## App Review Notes

Paste into App Store Connect → App Review Information → Notes. **Section 2 is the
one that matters** — without it a reviewer indoors sees an apparently empty
Nature tab, which is correct behaviour but looks broken.

```
Geo names the mountain peaks in front of the camera, reads altitude from the
barometer, and reports what a geomagnetic storm is doing to the compass and to
aurora visibility. This update (1.3) makes the nearby-peak list reliable: three
OpenStreetMap servers instead of one, peaks from downloaded offline areas with no
signal, and a clear message when the minimum-altitude setting hides every peak.

1. ACCESS
No account, sign-in, registration, in-app purchase or subscription. Every feature
works the moment the app launches, so no demo credentials exist or are needed.

2. PLEASE READ - WHAT THE NATURE (AR) TAB NEEDS
The Nature tab overlays the names of real peaks on the live camera. It needs a
physical device (camera + ARKit; the Simulator has neither) and real mountains
within ~80 km.

Indoors, or anywhere without nearby named summits, the tab correctly shows the
horizon line and N/E/S/W compass markers but few or no peak labels. That is
expected behaviour, not a failure.

To see it working without travelling, set a simulated location from Xcode
(Debug menu, Simulate Location). Any of these puts large named peaks in view:
  Chamonix, France      45.9237, 6.8694  (Mont Blanc, 4808 m)
  Zermatt, Switzerland  46.0207, 7.7491  (Matterhorn, 4478 m)
  Lauterbrunnen, CH     46.5938, 7.9089  (Jungfrau, Eiger)

Two tabs show the same peak data with no camera and no mountains needed, from any
location: the Map tab shows nearby peaks as pins, and the Info tab shows "closest
mountain" and "highest mountain" cards with distance and bearing.

Altitude comes from the barometric sensor; without one the app falls back to
satellite altitude and says so on screen.

3. WHERE THE NEW THINGS ARE
Nature tab: the peak count now shows how many peaks the minimum-altitude slider
hides, e.g. "(3 hidden)"; when it hides every peak, a pill names the setting and
resets it in one tap; "possibly outdated" marks a remembered list while the
servers can't be reached. Info tab, "Manage offline areas": a download that no
server answered now says why instead of saving an empty area. Everything else
(peak labels, drag to align, the shutter button, the Magnetic Conditions card)
is unchanged from 1.2.

4. NETWORK
There are no servers of ours. No analytics, advertising, tracking or third-party
SDKs; the Privacy Nutrition Label answer is "Data Not Collected", and no App
Tracking Transparency prompt is shown because nothing is tracked.

Three services are contacted: OpenStreetMap Overpass (nearby peaks, from one of
three public servers), Open-Meteo (ground elevation, to tell which peaks rise
above the horizon), and the NOAA Space Weather Prediction Center (planetary K
index). Coordinates sent to the first two are rounded to a ~110 m grid. The
third carries none: a fixed URL with no query string, identical for every user.
Apple MapKit renders the Map tab.

5. PERMISSIONS
Location (When In Use), at first launch - the Info tab the app opens on is itself
a live position readout; Always/background location is never requested. Camera -
the Nature view's labelling and shutter. Motion & Fitness - the barometer, for
altitude, the pressure trend and the storm warning. Photos, add-only - only if
the user picks Save Image from the share sheet. Notifications - two local
advisories: a "pressure falling fast" storm warning, and an aurora alert that is
off by default, sits behind a switch in the Magnetic Conditions explainer, and
fires at most once in any 20 hours. Both are scheduled on the device; there is no
push server and no device token leaves the phone.

6. iCLOUD, CONTENT, ENCRYPTION
History, trips and the summit log sync through the user's own private CloudKit
database, visible only to them. Nothing is shared between users, so there is no
content to moderate. It behaves the same everywhere and is English only.

Magnetic Conditions reports a published index and computes local consequences -
it does not claim to detect geomagnetic storms, and contains no magnetometer code
for that purpose, because a phone's magnetometer cannot resolve the signal.

ITSAppUsesNonExemptEncryption is false; the app implements no encryption of its
own. Minimum system iOS 26 / watchOS 26. An Apple Watch app, widgets and Watch
complications are included. Source code and privacy policy are public.

Thank you for reviewing.
```
