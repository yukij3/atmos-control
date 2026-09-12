<p align="center">
  <img src="docs/assets/hero.svg" alt="atmos-control — personalized spatial audio for macOS" width="820">
</p>

<p align="center">English | <a href="README.ru.md">Русский</a></p>

# atmos-control

**Personalized spatial audio for macOS** — system-wide, head-tracked binaural sound with a full
manual control surface over Apple's own spatial renderer (`AUSpatialMixer`). It runs as a menu-bar
app and spatializes everything your Mac plays to your headphones in real time, with personalized
HRTF and AirPods head tracking. It is built for listeners who already understand spatial audio and
want the renderer controls the OS keeps hidden — output type, spatialization algorithm, per-source
azimuth/elevation/distance/gain, HRTF mode, and head tracking.

atmos-control is **not** a Dolby Atmos decoder. It is a PCM spatializer and stereo/surround upmixer
driven by the same Apple DSP engine that powers Spatial Audio — the one-sentence differentiator is
that it hands you manual control over Apple's spatial renderer, with personalized HRTF and head
tracking, instead of a single system on/off switch.

## How it works

atmos-control captures your system audio, feeds it into an app-hosted `AUSpatialMixer`, and sends
the spatialized binaural result to your headphones. The mixer is the same Apple engine behind
system Spatial Audio, so when you use AirPods with a scanned personal profile, personalized HRTF and
head tracking engage — and atmos-control exposes the full renderer surface that Apple normally
reduces to one switch.

<p align="center">
  <img src="docs/assets/signal-path.svg" alt="Signal path: system audio capture into AUSpatialMixer, personalized binaural output to headphones" width="820">
</p>

1. **Capture** — the system mix is read via a process tap (default) or routed through the
   atmos-control virtual audio device (loopback modes).
2. **Spatialize** — each channel or source is placed at its azimuth, elevation, and distance and
   rendered through Apple's `AUSpatialMixer` (personalized HRTF when available, generic HRTF
   otherwise).
3. **Track** — with AirPods, the head pose continuously updates so the soundstage stays fixed in the
   world while your head moves.
4. **Output** — the binaural result plays to your headphones. Nothing is sent anywhere; all capture
   and processing is local.

## Capture modes

atmos-control offers three ways to get audio into the engine. The default **Personalized** mode
needs no driver and is the only mode where personalized HRTF can engage; the two loopback modes
require the optional virtual audio device.

<p align="center">
  <img src="docs/assets/modes.svg" alt="The three capture modes: Personalized process tap, Surround 7.1.4, and Stereo virtual device" width="820">
</p>

| Mode | What it does | Driver needed | System Spatial Audio | Apple Music Dolby Atmos |
|---|---|---|---|---|
| Personalized (headphones) | Captures the system mix via a process tap and applies personalized, head-tracked binaural rendering. Default mode. | No | Off | Off |
| Surround 7.1.4 | Routes true 12-channel multichannel through the virtual device and places each channel at its canonical speaker angle. | Yes | Off | Automatic |
| Stereo (virtual device) | Routes all audio through the atmos-control virtual device. Works with any source, but rendering is generic (personalized HRTF cannot engage). | Yes | Off | Off |

Notes:

- The default Personalized mode needs no driver. Only Surround 7.1.4 and Stereo (virtual
  device) require the driver, because they capture through the virtual output device.
- Personalized HRTF only engages in Personalized mode with AirPods that have a scanned
  personal profile. The panel shows a "Personalized" status that reads active when the
  Apple engine confirms your personal HRTF is in use.

## Screenshots

<p align="center">
  <img src="docs/assets/panel.png" alt="atmos-control menu-bar panel with the spatial visualizer and stereo meters" width="360">
</p>

The compact menu-bar panel: a power toggle, live status strip (engine, output device, personalized
HRTF, head tracking), the spatial visualizer (azimuth radar + elevation gauge), stereo meters, and
quick controls.

<p align="center">
  <img src="docs/assets/settings.png" alt="atmos-control settings window with the draggable soundstage source and per-source controls" width="720">
</p>

The settings window: the full renderer surface — output device and algorithm, a draggable soundstage
source with per-source azimuth/elevation/distance/gain, personalization and head-tracking controls,
rendering flags, and full meters.

## Requirements

- Apple Silicon Mac (arm64).
- macOS 26 (Tahoe) or newer.
- Xcode command line tools (`xcode-select --install`) — provides `swift`.
- AirPods Pro (with a scanned Personalized Spatial Audio profile) for the personalized,
  head-tracked experience. Any headphones work with the generic HRTF.

## Install

Clone the repo and run the installer:

```bash
git clone <repo-url> atmos-control
cd atmos-control
./install.sh
```

`install.sh` is idempotent — re-running it rebuilds and replaces the installed app.
It builds the package, assembles `dist/atmos-control.app`, and copies it into
`/Applications`. It never changes your default output device and never touches system
audio locations.

To also install the optional audio driver (only needed for the two loopback capture
modes — see Capture modes), add the flag:

```bash
./install.sh --with-driver
```

The driver install is privileged: it copies the driver into
`/Library/Audio/Plug-Ins/HAL` and restarts Core Audio, which makes audio devices blink
out for about a second. You will be prompted for your admin password.

### Manual install (step by step)

If you prefer to run each step yourself instead of `./install.sh`:

| Step | Command |
|---|---|
| Build the package | `swift build -c release` |
| Build the app bundle | `bash App/build-app.sh release` |
| Install the app | `cp -R dist/atmos-control.app /Applications/` |
| (optional) Build the driver | `bash Driver/build.sh` |
| (optional) Install the driver | `sudo cp -R Driver/.build/atmos-control.driver /Library/Audio/Plug-Ins/HAL/` |
| (optional) Own it root:wheel | `sudo chown -R root:wheel /Library/Audio/Plug-Ins/HAL/atmos-control.driver` |
| (optional) Reload Core Audio | `sudo launchctl kickstart -k system/com.apple.audio.coreaudiod` |

## First run

```bash
open /Applications/atmos-control.app
```

atmos-control is a menu-bar app (`LSUIElement`) — it has no Dock icon. Look for its glyph
at the top-right of the menu bar and click it to open the control panel.

On the first engine start, macOS asks for the audio-capture permission (it appears as a
microphone/TCC prompt). Grant it — atmos-control needs this permission to read the system
audio it spatializes. Nothing is sent anywhere; capture is local.

## Before you listen

- Turn off system Spatial Audio. Control Center ▸ Sound ▸ AirPods ▸ Spatial Audio should be
  OFF while atmos-control runs — otherwise audio is spatialized twice (the OS and atmos-control
  both apply an HRTF).
- Apple Music ▸ Dolby Atmos setting. In Personalized / Stereo capture, set Music ▸ Settings ▸
  Playback ▸ Dolby Atmos to Off (atmos-control does the spatialization). In Surround 7.1.4
  capture, set it to Automatic so Music emits true multichannel for atmos-control to place.

## Update

```bash
git pull
./install.sh          # add --with-driver if you use the loopback modes
```

Re-running the installer rebuilds and replaces the installed app in place.

## Uninstall

```bash
./uninstall.sh                 # removes the app from /Applications
./uninstall.sh --with-driver   # also removes the driver (privileged; Core Audio restarts)
```

Nothing else is left behind: atmos-control installs no LaunchAgents or LaunchDaemons and
writes no preferences of its own (it only reads Apple Music's Dolby Atmos setting while
running, and never modifies it). There is no defaults domain to clean up.

## Troubleshooting

- No sound after quitting, or the default device is stuck on the virtual sink. If you used a
  loopback mode and audio is silent, your system default output may be stranded on the
  atmos-control virtual device. Set it back in Control Center ▸ Sound (or System Settings ▸
  Sound) to your headphones or speakers. atmos-control never changes your default device on
  its own.
- Driver not listed / loopback modes disabled. If Surround 7.1.4 or Stereo (virtual device)
  are unavailable, the driver is not installed. Install it:

  ```bash
  ./install.sh --with-driver
  ```

  or run the manual driver commands in the table above. A Core Audio restart is required for
  the system to see the driver.
- Personalized HRTF status. The panel's "Personalized" indicator reflects Apple's engine
  signal (property 3116). It reads active only in Personalized mode, with AirPods that have a
  scanned personal Spatial Audio profile, and while system Spatial Audio is off. If it reads
  inactive, rendering is still binaural but uses the generic HRTF.

## Development

The package builds several targets beyond the app (see `Package.swift`). These are the
CLI/debug harnesses kept from earlier phases.

Phase 0 spike — validates that personalized HRTF + AirPods head tracking engages inside an
app-hosted `AUSpatialMixer` for an unentitled/self-signed binary:

```bash
swift run Phase0Spike            # play test tone through the spatial mixer to default output
swift run Phase0Spike <file.wav> # spatialize a real audio file (subjective A/B listen test)
```

The spike prints whether `kAudioUnitProperty_SpatialMixerAnyInputIsUsingPersonalizedHRTF`
(3116) reads true — the programmatic signal that the user's personal HRTF profile is in use.

Environment variables (Phase0Spike / AtmosDaemon):

| Variable | Values (default in bold) | AU property |
|---|---|---|
| `SECONDS` | integer > 0 (**25**) | run duration |
| `SWEEP` | **0** / 1 | sweep azimuth -90 -> +90 degrees |
| `OUTPUT_TYPE` | **headphones** / builtin / external | `SpatialMixerOutputType` (3100) -> 1 / 2 / 3 |
| `HRTF_MODE` | **auto** / on / off | `SpatialMixerPersonalizedHRTFMode` (3113) -> 2 / 1 / 0 |
| `ALGO` | **useoutputtype** / hrtf / hrtfhq | `SpatializationAlgorithm` -> 7 / 2 / 6 |

Example invocations:

```bash
# Core-tier test — generic HRTF, any headphones (3116 should read NO; binaural still active)
HRTF_MODE=off swift run Phase0Spike

# Premium-tier test — personalized HRTF with auto fallback, AirPods connected
OUTPUT_TYPE=headphones HRTF_MODE=auto SECONDS=30 swift run Phase0Spike

# Speaker-virtualization test — built-in speakers or external (3116=NO is correct here)
OUTPUT_TYPE=builtin swift run Phase0Spike

# AirPods with personal profile, force personalization ON (no fallback)
OUTPUT_TYPE=headphones HRTF_MODE=on ALGO=hrtfhq swift run Phase0Spike
```

Other targets: `AtmosDaemon` (thin CLI over the engine, prints a 1 Hz diagnostic),
`TapSpike` (process-tap capture spike), `SpatialEngine` (the shared engine library).
Full architecture plan: [`docs/PLAN.md`](docs/PLAN.md).

The app bundle is produced by running `App/build-app.sh` (ad-hoc signed, `LSUIElement`); it writes
only to `dist/` and touches no system locations. Preview the panel in a window with
`ATMOS_PREVIEW=1 open -n dist/atmos-control.app`.
