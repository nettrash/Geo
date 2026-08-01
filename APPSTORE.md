# App Store listing copy — Geo

Copy-paste source for App Store Connect. Field limits: Promotional Text ≤ 170
chars, Description ≤ 4000, What's New ≤ 4000. Current release: **1.2**.

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

## What's New in This Version (1.2)

The Nature view is rebuilt around one job: naming the peaks you can actually see.

• A clean horizon with N / E / S / W compass markers, and a clear label on every visible summit — pinned to the real mountain, not a modelled silhouette.
• Peaks hidden below your horizon are no longer shown, so the view isn't cluttered with summits you couldn't possibly see.
• A new minimum-altitude slider hides the small hills; your setting is remembered next time.
• A shutter button captures the camera view with the peak labels drawn on, ready to share or save to Photos.
• Offline areas are peaks-only now: smaller and faster to download, and they show peaks in the camera out to ~80 km with no signal. A downloaded area can be updated in place.
• Drag sideways to nudge the whole overlay onto the real mountains when the compass is a few degrees off.

A new Magnetic Conditions card on the Info tab tells you what a geomagnetic storm is doing to your compass, to your GPS and to your chances of seeing the aurora — from exactly where you're standing.

• It reads the planetary K index published by NOAA's Space Weather Prediction Center — measured by ground observatories, not by your phone — and works out the local consequences on the device: the storm level on the G scale, how far a storm can push your compass beyond its normal error, whether GPS may degrade at your latitude, and whether the auroral oval reaches you tonight.
• Your magnetic latitude, and the Kp the aurora would need to become visible from it ("needs about Kp 5+"), with tonight's darkness window and the bearing to look along.
• Aurora alerts are opt-in and off by default. Switch them on for a notification on nights the aurora could be visible from where you are, capped at one a night.
• Space weather without telling anyone where you are: the request is a fixed URL with no parameters — no coordinates, no identifiers, nothing about you at all — and every local figure is worked out on the phone from that one published number.
• With no signal the card keeps the half that never needed the network — magnetic latitude, the Kp threshold, the darkness window, the bearing — and says plainly that it has no space-weather data.
• A "What this means" sheet covers what a storm really does to a compass and to GPS, and why local iron — vehicles, rebar, a case magnet — routinely beats any storm.

Easier on the battery, and the widget is stale less often: the home-screen widget and the Watch complication now ask to refresh every 15 minutes instead of every 2 and 5 minutes. iOS only grants a few dozen widget reloads a day, so the old cadence spent that budget early and then left the widget stale for long stretches. Every refresh still takes a live barometer sample, and using the app still updates the widget straight away.

Also fixed: on the Stats tab, the live altitude graph keeps recording the barometer trace when GPS drops, instead of freezing.
