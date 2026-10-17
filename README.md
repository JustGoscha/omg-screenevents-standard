# ScreenEvents

An open standard for apps to send their touch, Apple Pencil and pointer input to screen recorders, so recordings can show touches and the Pencil with the right position, orientation, tilt and pressure.

iPadOS and iOS screen recordings contain pixels only. No recorder can see where you touched: input goes only to the app in front. ScreenEvents gives that app a simple way to tell any recorder, even one from another developer.

```
┌─────────── Source app ───────────┐            ┌──────── Recorder ────────┐
│ finger / Pencil / hover / pointer│  NDJSON    │ broadcast extension, app │
│ → fixed screen points, host clock│ ─────────▶ │ draws overlay on frames  │
│ only while screen is captured    │ 127.0.0.1  │ and/or saves a sidecar   │
└──────────────────────────────────┘   :47833   └──────────────────────────┘
```

## At a glance

- **Transport:** newline-delimited JSON over loopback TCP, port 47833. Same-developer apps can use an App Group socket instead.
- **Silent unless recorded:** Sources connect only while `UIScreen.isCaptured` is true.
- **Coordinates:** points in the screen's fixed (native) space, so they map straight onto ReplayKit frame buffers in any rotation, Split View or Stage Manager layout.
- **Time:** host clock seconds, the same clock as the video frames. No sync needed on-device.
- **Pencil:** force, altitude, azimuth, roll, hover height, estimated-value updates, double-tap and squeeze.
- **Sidecar:** the same stream saved next to the video (`.screenevents.ndjson`) for drawing overlays later.
- **Privacy:** user opt-in, paused during secure entry, geometry only.

## Contents

- [SPEC.md](SPEC.md): the specification (v0.1 draft)
- [schema/screenevents.schema.json](schema/screenevents.schema.json): JSON Schema for all messages
- [examples/session.ndjson](examples/session.ndjson): an example session (finger tap, then a Pencil stroke with hover)

## Status

Draft. Feedback, issues and implementations are welcome. Please open an issue or pull request.

## License

MIT. See [LICENSE](LICENSE).
