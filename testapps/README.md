# ScreenEvents test apps

Two iOS/iPadOS apps that talk ScreenEvents 1.0 to each other, built on the Swift reference implementation in [`../swift/ScreenEventsKit`](../swift/ScreenEventsKit).

| App | What it does |
|---|---|
| **SE Source** | A drawing pad. Sends its finger, Pencil (force, tilt, azimuth, roll, hover, estimated updates, double-tap/squeeze) and pointer input while the screen is captured. Its status line shows capture state, the connected Recorder and the number of messages sent. A password field pauses events while editing (§10.3). |
| **SE Recorder** | Hosts a **broadcast upload extension**, the real system-wide recorder. The extension listens on `127.0.0.1:47833`, logs a sidecar file and measures clock skew and latency. The app shows those results and can share the sidecar. It also has an **in-app listener** that draws incoming events live (finger, Pencil barrel from azimuth/altitude, hover rings). |

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). Deployment target iOS 16.

## Simulator: two apps, real loopback

```sh
scripts/sim-test.sh            # or: scripts/sim-test.sh "iPad Air 11-inch (M3)"
```

This builds both apps, installs SE Recorder, and runs a UI test:
1. It launches SE Recorder with its in-app listener (kept running in the background with silent audio).
2. It launches SE Source with `-SEForceCapture`, because the simulator never reports a captured screen.
3. It draws real touches, rotates to landscape and draws again.
4. It checks the Recorder got every contact `began`→`ended`, plus `display` (with rotation 0, then 90) and `hints`.

The simulator can't run a ReplayKit broadcast or make Pencil touches. Those need a device.

## Device: the real test

```sh
scripts/device.sh <TEAM_ID>    # your Apple developer team id; signing is automatic
```

Or run `xcodegen generate`, open `ScreenEventsTestApps.xcodeproj`, and set your team on the three targets.

Then on the iPad:
1. Open **SE Recorder** and tap the record button (the broadcast picker), then **Start Broadcast**.
2. Open **SE Source**. The status line should say `captured: yes · connected to SE Recorder (broadcast) on :47833`.
3. Draw with a finger and the Pencil, hover, double-tap or squeeze, rotate, and use Split View or Stage Manager.
4. Stop the broadcast and go back to **SE Recorder**. The *Broadcast extension* panel shows what the extension saw. **Share last sidecar** exports the `.screenevents.ndjson` file.

What this checks (the spec's unverified device assumptions):

| Assumption | Where to look | Expected |
|---|---|---|
| A broadcast extension can listen on loopback | `listener:` | `listening :47833` |
| No local network permission prompt | — | no prompt in either app |
| `isCaptured` is true during a third-party broadcast | Source status | `captured: yes` |
| Touch times and frame PTS share the host clock (§7.1) | `clock skew` | about −0.1…0.1 s (a different clock would be off by minutes or more) |
| Frames come in native orientation (§8.1) | `buffer`, `orientation` | portrait-sized buffer; orientation changes when you rotate |
| Latency is fine for live overlays | `latency` | a few ms |
