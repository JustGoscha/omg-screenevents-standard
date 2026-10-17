# ScreenEvents — specification

**Version 1.0** · Status: stable · Wire version: `"1.0"`

ScreenEvents is a small protocol that an app being recorded uses to send its touch, Apple Pencil and pointer input to a screen recorder. The recorder can then draw that input as an overlay with the right position, orientation, tilt and pressure.

The words MUST, SHOULD and MAY are used as in RFC 2119.

---

## 1. Why

On iPadOS and iOS, a screen recording contains pixels only:

- The system recorder (ReplayKit) has no "show touches" option.
- A broadcast upload extension receives video and audio sample buffers. It never receives input events, because input is delivered only to the foreground app.
- The keyboard and system UI run in other processes, and their input is invisible to everyone else.

The only process that knows where the finger or Pencil is, is the app being touched. ScreenEvents gives that app a standard way to tell any recorder, without the two apps having to come from the same developer.

## 2. Roles

| Role | What it is |
|---|---|
| **Source** | The app being used and recorded. It captures its own input and sends events. |
| **Recorder** | A broadcast upload extension, an in-app recorder, or a desktop tool. It receives events and draws or stores them. |
| **Sidecar** | A file holding a recorded event stream next to a video, for drawing the overlay later (§9). |

There is at most one Recorder per Source connection. A Recorder MAY accept several Sources at once, for example two apps in Split View.

## 3. Design principles

1. **Silent unless recorded.** A Source sends nothing while the screen is not being captured.
2. **Raw input, not pictures.** Sources send samples. Recorders decide how to draw them.
3. **One clock.** Timestamps use the clock the video frames use, so events line up with frames without guessing.
4. **One coordinate space.** Positions are in the screen's fixed (native) space, so windows, Split View, Stage Manager and rotation never need special cases on the Recorder side.
5. **Plain text.** The wire format is newline-delimited JSON. It is easy to implement, debug and store.
6. **Ignore what you don't know.** Unknown message types and fields MUST be ignored. This keeps the protocol extensible.

## 4. Transport

### 4.1 Loopback TCP (default, cross-developer)

- The Recorder listens on `127.0.0.1`, TCP port **47833**. If that port is taken, it tries **47834**, **47835** and **47836**, in that order.
- A Source connects only while the screen is being captured (`UIScreen.isCaptured == true`, or `UITraitCollection.sceneCaptureState == .active` on iOS 17+). It disconnects when capture ends.
- A Source tries the ports in order and uses the first one that completes the handshake (§6.1).
- If no Recorder answers, the Source retries with exponential backoff (start at 0.5 s, cap at 10 s) for as long as capture lasts. Failing to connect MUST NOT affect the app in any way the user can see.
- Loopback-only. A Recorder MUST NOT listen on any other interface for this binding. Loopback does not trigger the iOS local network permission prompt.

### 4.2 App Group (same developer)

If the Source and Recorder share an App Group, they MAY use a Unix domain socket at `<group container>/ScreenEvents/events.sock` instead. The messages are the same.

### 4.3 Network (optional, for recording on another device)

For a recorder on a Mac or another device (for example a cable or AirPlay capture), a Recorder MAY advertise `_screenevents._tcp` over Bonjour. This requires the local network permission on both sides, and a clock sync (§7.2). It is optional and not needed for on-device recording.

## 5. Framing

- Each message is one UTF-8 JSON object, followed by `\n` (0x0A).
- A message MUST NOT be larger than 64 KiB.
- Every message has a `"type"` string.
- Numbers are JSON numbers. Times are seconds (floating point). Angles are radians.

## 6. Messages

### 6.1 Handshake

The Source sends `hello` first:

```json
{"type":"hello","protocol":"screenevents","version":"1.0",
 "source":{"id":"com.example.sketch","name":"Sketch","version":"2.3.0","pid":4211},
 "clock":"host",
 "capabilities":["touch","pencil","hover","pointer","estimated","predicted","pencil-actions"]}
```

The Recorder answers with `welcome`:

```json
{"type":"welcome","version":"1.0",
 "recorder":{"id":"com.example.recorder.broadcast","name":"Recorder"},
 "want":["touch","pencil","hover","pointer","estimated","pencil-actions"],
 "maxRate":240}
```

- `version`: the Recorder answers with the highest version both sides support. If none, it closes the connection.
- `want`: the capabilities the Recorder wants. A Source MUST NOT send event kinds that are not in `want`. Leaving out `predicted` means: don't send predicted samples.
- `maxRate`: the highest number of samples per second per contact the Recorder wants. A Source MAY drop samples to stay below it. It MUST NOT drop `began`, `ended` or `cancelled`.

A Source MUST NOT send anything except `hello` until it has received `welcome`.

### 6.2 `display` — screen and window geometry

Sent after the handshake, and again whenever any field changes (rotation, window resize, Stage Manager moves, an external screen appears).

```json
{"type":"display","t":81234.512,
 "screen":{"id":"main","size":[1024,1366],"scale":2,"rotation":90},
 "windows":[{"id":"w1","frame":[0,0,1024,1366],"key":true}]}
```

- `screen.size`: the screen size in **points** in its fixed (native) orientation. On iPad and iPhone that is portrait.
- `screen.scale`: pixels per point.
- `screen.rotation`: how far the interface is rotated from the native orientation, in degrees clockwise: `0`, `90`, `180` or `270`. This is given in degrees so it can't be mixed up with UIKit's `landscapeLeft`/`landscapeRight` naming.
- `windows`: optional. The Source's window frames in fixed screen points, as `[x, y, width, height]`. Recorders can use this to clip the overlay or to tell two Sources apart.

### 6.3 `touch` — contact samples

One message per contact per input event. It carries all the coalesced samples the system delivered for that event.

```json
{"type":"touch","id":7,"kind":"pencil","phase":"moved","screen":"main",
 "samples":[
  {"seq":1041,"t":81234.5161,"x":512.25,"y":700.75,"force":0.42,"altitude":0.91,"azimuth":2.31,"estimated":["force","azimuth"]},
  {"seq":1042,"t":81234.5203,"x":513.10,"y":701.90,"force":0.44,"altitude":0.90,"azimuth":2.30}
 ]}
```

**Message fields**

| Field | Meaning |
|---|---|
| `id` | Integer, unique per contact for as long as the connection lasts. A new contact gets a new `id`. Don't reuse ids within a connection. |
| `kind` | `"finger"`, `"pencil"` or `"pointer"` (mouse or trackpad). |
| `phase` | `began`, `moved`, `stationary`, `ended`, `cancelled`, `hover-began`, `hover`, `hover-ended`. |
| `screen` | The `screen.id` from `display`. |
| `samples` | One or more samples, oldest first. |
| `predicted` | Optional array of predicted samples (only if the Recorder asked for them). Predicted samples are never final. Each new message replaces earlier predictions. |
| `buttons` | `pointer` only: bitmask of pressed buttons (1 = primary, 2 = secondary). |

**Sample fields**

| Field | Kinds | Meaning |
|---|---|---|
| `seq` | all | Integer, increasing per contact. Used by `update` (§6.4). |
| `t` | all | Timestamp on the session clock (§7). |
| `x`, `y` | all | Position in fixed screen points (§8), sub-point precision. Use the precise location (`preciseLocation(in:)`) when the platform offers it. |
| `force` | finger*, pencil | 0 to 1: force divided by the maximum possible force. Leave it out if the device has no pressure sensing. |
| `altitude` | pencil | 0 = Pencil lying flat on the screen, π/2 = upright. |
| `azimuth` | pencil | Direction the Pencil's barrel points **away from the tip**, projected onto the screen, in fixed screen space (§8.2). 0 = +x, increasing toward +y (clockwise on screen). |
| `roll` | pencil | Barrel roll, if the hardware reports it (Apple Pencil Pro). |
| `z` | pencil (hover) | Height above the screen, 0 to 1, as the platform reports it (`zOffset`). |
| `radius` | finger | Approximate contact radius in points (`majorRadius`). |
| `radiusTolerance` | finger | The ± accuracy of `radius`. |
| `estimated` | pencil, finger | Names of fields in this sample that are estimates and may be refined by an `update`. |

Rules:
- A contact starts with `began` (or `hover-began`) and ends with exactly one `ended`, `cancelled` or `hover-ended`.
- A pencil can go `hover-began → hover → hover-ended → began → … → ended → hover-began …`. Each touchdown is a new `id`; hover is its own contact with its own `id`.
- If the connection closes, the Recorder MUST treat all open contacts as cancelled.

### 6.4 `update` — refined estimates

The Pencil reports some values (force, azimuth, altitude) a little after the position. When the refined value arrives, the Source sends:

```json
{"type":"update","id":7,"seq":1041,"force":0.47,"azimuth":2.29,"final":true}
```

- `final: true` means no more updates will come for that sample.
- Recorders drawing live MAY ignore updates. Recorders storing a sidecar SHOULD apply them.

### 6.5 `action` — Pencil actions

```json
{"type":"action","t":81240.1,"name":"pencil-double-tap"}
{"type":"action","t":81241.7,"name":"pencil-squeeze","phase":"ended","hover":{"x":300.5,"y":420.0}}
```

Names: `pencil-double-tap`, `pencil-squeeze`. A `hover` position is included when the Pencil was hovering at the time. Recorders MAY show these as short visual cues.

### 6.6 `hints` — how the Source wants to be drawn

```json
{"type":"hints","selfRendered":["finger"],"suppress":false}
```

- `selfRendered`: kinds the Source already draws its own indicators for. The Recorder SHOULD NOT draw those, so they don't appear twice.
- `suppress: true`: the Source asks the Recorder not to draw any overlay for it, for now. The Source still keeps the connection.

### 6.7 `privacy` — paused on purpose

```json
{"type":"privacy","state":"paused","reason":"secure-entry"}
{"type":"privacy","state":"resumed"}
```

A Source sends `paused` before it stops sending events for privacy reasons (§10), so the Recorder can tell a deliberate gap from a lost connection. When it pauses, all open contacts MUST be ended or cancelled first.

### 6.8 `ping` / `pong` and `bye`

```json
{"type":"ping","n":3,"t":81250.0}
{"type":"pong","n":3,"t":81250.0,"rt":81250.0004}
{"type":"bye"}
```

- Either side MAY send `ping`. The other side answers with `pong`, echoing `n` and `t`, and adds `rt`: its own clock at the moment it received the ping. This is used for clock sync (§7.2) and to check the connection is alive.
- `bye` closes the session cleanly. Either side MAY send it before closing.

## 7. Time

### 7.1 Host clock (on-device)

`"clock":"host"` means: seconds since boot on the system's monotonic host clock, **the same clock video frames are timestamped with**.

On Apple platforms:
- `UITouch.timestamp` and `ProcessInfo.systemUptime` are in this clock.
- ReplayKit video sample buffers are timestamped on the host time clock (`CMClockGetHostTimeClock()`), which uses the same time base.
- So a Recorder can compare `t` directly with a frame's presentation timestamp (converted to seconds), without any sync step.

Sources MUST use the event's own timestamp, not the time the message was sent.

### 7.2 Remote clock

If the Recorder is on another device (§4.3), the Source sends `"clock":"source"` and the Recorder estimates the offset with `ping`/`pong`, NTP-style: offset ≈ `rt − (t + rtt/2)`. Recorders SHOULD ping at least once per second during the first 5 seconds and keep the lowest-round-trip estimates.

## 8. Coordinates

### 8.1 Positions

All positions are in **fixed screen space**:

- Units: points (multiply by `screen.scale` for pixels).
- Origin: top-left of the screen **in its native orientation**. On iPad and iPhone that is the top-left corner in portrait, with the home button (or camera) at the bottom.
- This space does not rotate with the interface, and does not move with the window.

On UIKit, this is `UIScreen.fixedCoordinateSpace`:

```swift
let fixed = window.screen.fixedCoordinateSpace
let p = window.convert(touch.preciseLocation(in: window), to: fixed)
```

Why fixed space: ReplayKit delivers frames in the screen's native buffer orientation, along with the frame's orientation (`RPVideoSampleOrientationKey`). Positions in fixed space map onto the raw frame buffer directly:

```
pixelX = x * bufferWidth  / screen.size[0]
pixelY = y * bufferHeight / screen.size[1]
```

The Recorder then rotates the composited frame (or tags the output video) the same way it would without an overlay. Touches and video can't drift apart, whatever the interface orientation, window position or Stage Manager layout.

### 8.2 Pencil azimuth

The azimuth has to be in fixed screen space too. Converting the angle with `azimuthAngle(in:)` and then adding the interface rotation is easy to get wrong. Convert the direction vector as two points instead:

```swift
let loc = touch.preciseLocation(in: window)
let v = touch.azimuthUnitVector(in: window)
let p0 = window.convert(loc, to: fixed)
let p1 = window.convert(CGPoint(x: loc.x + v.dx, y: loc.y + v.dy), to: fixed)
let azimuth = atan2(p1.y - p0.y, p1.x - p0.x)
```

UIKit's azimuth points along the barrel, away from the tip. That matches §6.3.

### 8.3 Drawing the Pencil (non-normative)

To draw a Pencil shadow:
- The tip is at `(x, y)`.
- The barrel is drawn from the tip in direction `azimuth`.
- The projected length is `L * cos(altitude)`, where `L` is the Pencil's drawn length. An upright Pencil (altitude π/2) has no length on screen; a flat one has its full length.
- `force` can scale the tip, `z` can fade or grow a hover marker, and `roll` can rotate a barrel texture.

## 9. Sidecar files

A Recorder MAY store the received stream next to the video, so the overlay can be drawn later in any style.

- Extension: `.screenevents.ndjson` (example: `recording.mov` + `recording.screenevents.ndjson`).
- Format: the same messages as on the wire, one per line, in the order received, with `update`s applied or kept as received.
- The first line is a `sidecar` header:

```json
{"type":"sidecar","version":"1.0","clock":"host","videoStart":81230.0,"recorder":{"id":"com.example.recorder"}}
```

`videoStart` is the host-clock time of the first video frame, so `t − videoStart` is the time offset in the video.

- If several Sources were connected, each line from a Source carries `"source":"<source.id>"`, and each Source's `hello` is kept.

## 10. Privacy and security

The event stream is input data, so it is sensitive. Touch positions over an on-screen keypad can reveal a PIN.

**Threat model.** Any process that can listen on loopback while the Source is in front could receive events. On iOS, only extensions and apps allowed to run in the background can do that. ScreenEvents cannot authenticate the Recorder across sandboxes. These rules limit what a rogue listener can get:

1. **Only while captured.** A Source MUST NOT connect or send events while the screen is not being captured. A listener alone gets nothing; the screen must also be recording or mirroring.
2. **User control.** A Source MUST let the user turn ScreenEvents off. It SHOULD be off by default, and SHOULD be clearly labelled (for example: "Share touches with screen recorders").
3. **Secure entry.** A Source MUST pause (§6.7) while a secure text field is first responder, and while any of its own PIN, password or payment views are on screen. The system keyboard runs in another process, so its touches are never visible to the Source anyway.
4. **No content.** Messages carry geometry only. Never text, view hierarchy, accessibility labels or screen content.
5. **Recorder identity.** The Source SHOULD show the user which Recorder connected (`welcome.recorder.name`), for example the first time a new Recorder id is seen.
6. **Loopback only.** The default binding listens on `127.0.0.1` only (§4.1). Network recording (§4.3) needs the user's explicit setup.

## 11. Conformance

**Source, minimum:** §4.1 transport, §6.1 handshake, `display`, `touch` with `x`, `y`, `t` and `phase`, and all of §10.

**Source, full:** also Pencil fields, `update`, `hover`, `action`, `hints`.

**Recorder, minimum:** listen per §4.1, answer `hello`, accept `display` and `touch`, cancel open contacts on disconnect, ignore unknown types and fields.

## 12. Versioning

`version` is `major.minor`. Minor versions only add optional fields and message types, so older peers keep working by ignoring them. A major version change may break compatibility and is negotiated in the handshake.

## 13. Future work (1.x and later)

- Should there be a pairing step (for example the Recorder showing a short code) so Sources can authenticate it?
- A binary encoding (CBOR) for high-rate multi-touch, negotiated in `hello`?
- Android binding: `InputEvent` timestamps use `SystemClock.uptimeMillis`; MediaProjection frames use `System.nanoTime`. Map both into one clock.
- Is a standard port registry entry (IANA) worth requesting?
