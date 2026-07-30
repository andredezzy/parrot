# Input device picker in the menu bar

## Goal

Choose which microphone parrot records from, in the tray, without touching the
system default input. Other apps keep using whatever macOS is set to.

## Constraint that shapes the design

`AudioDeviceID` is an ephemeral integer: CoreAudio reassigns it across reboots
and reconnects. A persisted id can silently point at a different microphone, so
the preference is stored as the device **UID** (`kAudioDevicePropertyDeviceUID`,
a stable string) and resolved to an id for every recording.

## Components

- `InputDeviceStore` (new, `Sources/parrot/Audio/InputDeviceStore.swift`) — owns
  the whole concept of "which input":
  - `available() -> [Device]` — every device with input channels, `id`/`uid`/`name`.
  - `selectedUID: String?` — persisted in `UserDefaults` under `inputDeviceUID`;
    `nil` means follow the system default.
  - `resolved() -> Device?` — the device to record from now; `nil` when following
    the system default *or* when the remembered device is currently absent.
- `AudioCapture.start(device:)` — binds the engine's input node via
  `auAudioUnit.setDeviceID(_:)` **before** reading the input format, because the
  node reports the format of whichever device it is bound to. A throw is logged
  and the recording proceeds on the system default.
- `MenuBarController` — an `Input` submenu, rebuilt in `menuWillOpen`:
  `Automatic (follow system)` plus one row per device, checkmark on the active
  one. Selecting a row only writes the preference; the next recording resolves
  it, so there is nothing to notify.

## Data flow

Menu writes `selectedUID` → next Fn press calls `devices.resolved()?.id` →
`AudioCapture.start(device:)` binds that device on a fresh engine → format read
reflects the bound device → tap installed with that format.

## Decisions

- **No protocol or registry.** One implementation, no test target upstream; a
  fake-injection seam would be machinery for a future nobody asked for.
- **Rebuild the list on menu open** instead of observing
  `kAudioHardwarePropertyDevices`. Always current, no listener lifecycle.
- **Fresh engine per recording** (existing change) is what makes device binding
  safe: the format is read after the bind, so a device switch cannot leave a
  stale format behind.
- **First `UserDefaults` use in the project.** A device choice that does not
  survive a login-launched daemon's restart would be useless.

## Out of scope

Live device-change notifications, input gain, output device selection, per-app
profiles.

## Verification

`swiftc` harness compiling the real `InputDeviceStore.swift` (no copy):
enumeration, preference round-trip, unknown-UID fallback to nil, and
`setDeviceID` followed by a valid format read (48000 Hz, 1 ch) — all pass.
Switching between two devices is unverified: only one input device was connected.
