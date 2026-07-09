# dualaudio

Play your Mac's audio to **two AirPods (or any two outputs) at once**, from one
command. macOS has no "Share Audio" feature like iOS does — this fills that gap
by creating a CoreAudio multi-output ("aggregate") device, the same thing Audio
MIDI Setup does, but scriptable.

## Build

```sh
swiftc -O dualaudio.swift -o dualaudio -framework CoreAudio
```

Produces a `dualaudio` binary in the current directory. Requires the Xcode
command-line tools (`xcode-select --install`).

## Usage

```
dualaudio list                  Show output devices
dualaudio on                    Combine the two connected Bluetooth outputs
dualaudio on "Name A" "Name B"  Combine two specific devices (partial names ok)
dualaudio off                   Remove the combo, back to built-in output
dualaudio vol                   Show volume of both AirPods
dualaudio vol 40                Set both to 40%  (also: vol up / vol down)
dualaudio watch                 Keep the combo as output when macOS switches away
dualaudio install               Run the watcher in the background at login
dualaudio uninstall             Remove the background watcher
```

### Typical flow

1. Connect both AirPods in System Settings → Bluetooth (both must show "Connected").
2. `dualaudio on` — auto-detects the two Bluetooth outputs and makes the combo
   your Mac's active output.
3. `dualaudio off` when you're done.

### The auto-switch problem

When AirPods detect they're in your ears, macOS auto-connects them and steals the
output away from the combo. There's no macOS setting to disable this. The watcher
fixes it: it listens for output changes and switches back to the combo whenever
macOS grabs it away.

```sh
dualaudio install     # runs the watcher now and at every login
dualaudio uninstall   # stop it
```

## Notes & limitations

- **The Mac volume keys don't work** while a multi-output device is active — this
  is a macOS limitation. Use `dualaudio vol`, swipe the AirPods stems, or the
  per-device sliders in Control Center → Sound.
- Combo devices don't survive a reboot; re-run `dualaudio on` after restarting.
- While the watcher is running and a combo exists, switching output to anything
  else needs `dualaudio off` first — the watcher fights other switches by design.

## How it works

Uses public CoreAudio HAL APIs: `AudioHardwareCreateAggregateDevice` with a
*stacked* sub-device list (same audio to every output), drift compensation on the
secondary device, and `kAudioHardwarePropertyDefaultOutputDevice` to route system
audio into it. The watcher registers `AudioObjectPropertyListenerBlock`s on the
default-output and device-list properties.
