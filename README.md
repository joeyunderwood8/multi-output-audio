# Multi-Output Audio

Made this for my girlfriend and I to watch the Duton Ranch finale during 4th of July weekend at a small cabin with my family. Updated it a bit afterwards later since it worked so well.

Play your Mac's audio to **several devices at once** — two or more AirPods,
headphones, or speakers all playing the same thing. macOS has no built-in "Share
Audio" like the iPhone does; this fills that gap with a small menu-bar app that
builds a CoreAudio multi-output ("aggregate") device — the same thing Audio MIDI
Setup does, but as one click.

Works with **any output device** — AirPods, other Bluetooth headphones/speakers
(Bose, Sony, JBL, Beats), the built-in speakers, USB/DAC, wired earbuds — in any
combination.

## Build

```sh
./build-app.sh
```

Compiles [`MultiOutputAudioApp.swift`](MultiOutputAudioApp.swift) and produces
`Multi-Output Audio.app`. Requires the Xcode command-line tools
(`xcode-select --install`) and macOS 13 or later.

## Run

```sh
open "./Multi-Output Audio.app"
```

Look for the **headphones icon in your menu bar** (top-right of the screen) and
click it to open the panel.

## What it does

- **Live device list.** Every output device appears, Bluetooth ones first. Connect
  a new device and the list updates instantly with a "🎧 *Name* connected" banner.
- **A checkbox per device.** Tick the ones you want to play to together — any
  number, any mix of types.
- **A volume slider per device**, with a live % readout, so you can set each
  device independently. Devices that don't expose Mac-controllable volume say so
  instead of showing a slider.
- **Combine / stop.** "Play to *N* devices" builds the mix and makes it your Mac's
  output; "Stop" tears it down and returns to a single output. The device currently
  receiving audio is tagged **output**.

## Stays out of the way

The app only touches your audio output when you explicitly combine devices. With a
single device connected it does nothing — macOS plays to it normally. And if a mix
is running but a device drops off (AirPods die or leave range), the app notices
there's nothing left to share, tears the mix down, and hands audio back to your Mac
automatically.

## Notes & limitations

- **How many devices?** There's no hard limit in the API. Two is rock-solid, three
  is usually fine, four works but is where Bluetooth radio strain starts causing
  dropouts and slight sync drift — especially across different brands. Wired and
  built-in outputs don't count against the Bluetooth budget.
- **The Mac volume keys don't work** while a multi-output device is active — this
  is a macOS limitation, not a bug. Use the app's per-device sliders, swipe the
  AirPods stems, or the sliders in Control Center → Sound.
- **A mix doesn't survive a reboot.** Re-combine after restarting.

## How it works

Uses public CoreAudio HAL APIs: `AudioHardwareCreateAggregateDevice` with a
*stacked* sub-device list (the same audio to every output), drift compensation on
the non-master devices to keep their clocks aligned, and
`kAudioHardwarePropertyDefaultOutputDevice` to route system audio into the combined
device. It registers CoreAudio property listeners to track device connect/disconnect
and volume changes live.
