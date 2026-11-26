# atmos-control

A macOS menu-bar app that plays all system audio through Apple's spatial audio renderer, with
your personalized HRTF and AirPods head tracking, and exposes the renderer settings macOS hides.

macOS gives you one Spatial Audio switch per device. atmos-control runs Apple's `AUSpatialMixer`
itself, feeds it everything your Mac plays, and sends the binaural result to your headphones. You
choose how the source is laid out and where it sits (azimuth, elevation, distance, width), plus
the output type, spatialization algorithm, HRTF mode, room reverb and head tracking. Audio is
processed on your Mac; the app makes no network connections.

It renders stereo and 7.1.4 audio binaurally. It does not decode Dolby Atmos.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/panel-dark.png">
    <img src="docs/assets/panel-light.png" alt="The atmos-control menu-bar panel: engine on, AirPods Pro output, personalized HRTF, head tracking, the soundstage radar and level meters" width="332">
  </picture>
</p>

## Requirements

- Apple Silicon Mac with macOS 26 (Tahoe) or newer.
- Headphones. Personalized HRTF needs AirPods with a Personalized Spatial Audio profile (scanned
  on an iPhone); head tracking needs AirPods that support it. Other headphones get Apple's generic
  HRTF.

## Install

With [Homebrew](https://brew.sh):

```bash
brew install --cask yukij3/tap/atmos-control
```

The app is self-signed and not notarized; the cask clears its quarantine flag, so it opens
without a Gatekeeper prompt. `brew upgrade --cask atmos-control` updates it.

Without Homebrew, download `atmos-control-<version>-macos-arm64.zip` from
[Releases](https://github.com/yukij3/atmos-control/releases), unzip it and move
`atmos-control.app` to `/Applications`. macOS blocks its first launch: close the warning, go to
System Settings ▸ Privacy & Security, click "Open Anyway" next to the atmos-control message and
confirm. (Right-click ▸ Open no longer skips this on macOS 15 and later.) Or clear the
quarantine flag instead:

```bash
xattr -dr com.apple.quarantine /Applications/atmos-control.app
```

### First launch

1. The app lives in the menu bar and has no Dock icon. Click the menu-bar icon to open the
   panel. The first time you turn the engine on, macOS asks for permission to capture audio,
   and the panel shows "Awaiting capture permission…" until you answer. Allow it. If
   you deny it, the panel offers Open Privacy Settings and Try Again.
2. Turn off Spatial Audio for your AirPods in Control Center ▸ Sound. Otherwise the audio is
   spatialized twice.

### Optional: the loopback driver

You only need the driver for the Surround 7.1.4 and Stereo modes.

```bash
brew install --cask yukij3/tap/atmos-control-driver   # asks for your admin password
```

Without Homebrew, download `atmos-control-driver-<version>.zip` from the same release, unzip it,
and run:

```bash
cd ~/Downloads/atmos-control-driver-<version>
bash install-driver.sh --dry-run   # print the commands it will run
bash install-driver.sh             # asks for confirmation and your admin password
```

Either way, `atmos-control.driver` is copied to `/Library/Audio/Plug-Ins/HAL` and `coreaudiod`
restarts, so audio drops out for about a second. An output device named "atmos-control" should
then appear in System Settings ▸ Sound.

The driver has only been tested with System Integrity Protection disabled. Whether it loads with
SIP on has not been verified yet. Don't disable SIP for it; if the device doesn't appear, open an
issue with your macOS version.

## Using it

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/signal-path-dark.svg">
  <img src="docs/assets/signal-path-light.svg" alt="System audio is captured by a process tap (Personalized mode) or the atmos-control virtual device (Surround 7.1.4, Stereo), rendered by AUSpatialMixer with AirPods head pose, and played on headphones" width="820">
</picture>

| Mode | Driver | HRTF | Use it for |
|---|---|---|---|
| Personalized (headphones), the default | no | personalized when available, otherwise generic | everyday listening on headphones |
| Surround 7.1.4 | yes | generic | 12-channel audio from Apple Music; each channel is placed at its speaker position |
| Stereo (virtual device) | yes | generic | any output device |

- Pick the mode under Audio capture in Settings (Settings… in the panel, or ⌘,).
- Personalized HRTF engages only in Personalized mode, with AirPods that have a profile, output
  type set to headphones and the automatic algorithm. The app shows whether Apple's renderer
  reports your profile in use. If it doesn't, you still get binaural sound with the generic HRTF.
- With AirPods, head tracking keeps the soundstage fixed in the room while you turn your head.
- Apple Music's Dolby Atmos setting (Music ▸ Settings ▸ Playback): set it to Off for Personalized
  and Stereo, and to Automatic for Surround 7.1.4 so Music sends real multichannel audio.
- Surround 7.1.4 and Stereo switch the system output to the atmos-control device while they run
  and switch it back when you turn the engine off or quit.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/settings-dark.png">
    <img src="docs/assets/settings-light.png" alt="The top of the atmos-control Settings window: the engine switch, output settings and the soundstage radar with its elevation gauge" width="560">
  </picture>
</p>

## Troubleshooting

- No sound after atmos-control crashed or was force-quit in Surround or Stereo mode: the system
  output is still set to "atmos-control". Pick your headphones or speakers again in Control
  Center ▸ Sound.
- Surround 7.1.4 and Stereo are greyed out ("driver not installed"): the driver isn't installed
  or didn't load. Check with `system_profiler SPAudioDataType | grep -i atmos`, and see the SIP
  note above.
- The panel says "Audio capture isn't allowed": the permission was denied earlier. Click Open
  Privacy Settings, allow atmos-control, then click Try Again.
- Sound seems spatialized twice: system Spatial Audio is still on for your AirPods. Turn it off in
  Control Center ▸ Sound.

## Uninstall

With Homebrew: `brew uninstall --cask atmos-control`, and `brew uninstall --cask
atmos-control-driver` if you installed the driver.

Otherwise quit atmos-control and delete `/Applications/atmos-control.app`. To remove the driver:

```bash
sudo rm -rf /Library/Audio/Plug-Ins/HAL/atmos-control.driver
sudo killall coreaudiod
```

From a source checkout, `./uninstall.sh --with-driver` does both. atmos-control installs no
LaunchAgents, daemons or login items.

## Build from source

You need the Xcode Command Line Tools (`xcode-select --install`) and a Rust toolchain
([rustup](https://rustup.rs)).

```bash
git clone https://github.com/yukij3/atmos-control.git
cd atmos-control
./install.sh                    # builds the app and copies it to /Applications
./install.sh --with-driver      # the same, plus the driver (asks for your admin password)
```

rustup downloads the pinned toolchain on the first build. `App/build-app.sh` only builds
`dist/atmos-control.app`, without installing it. Background notes are in
[`docs/PLAN.md`](docs/PLAN.md) and [`docs/PHASE0-RESULTS.md`](docs/PHASE0-RESULTS.md).

## License

[MIT](LICENSE)
