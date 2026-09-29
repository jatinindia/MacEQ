# MacEQ

A free, open-source, system-wide equalizer for macOS. It lives in your menu bar
and shapes the sound of everything your Mac plays — music, YouTube, games, calls
— without installing a virtual audio driver, without an admin password, and
without breaking your volume keys.

Made by [Jatin Grewal](https://github.com/jatinindia). MIT licensed.

[![Download MacEQ.dmg](https://img.shields.io/badge/Download-MacEQ.dmg-blue?style=for-the-badge&logo=apple)](https://github.com/jatinindia/MacEQ/releases/latest/download/MacEQ.dmg)

**macOS 14.4 or later · Apple Silicon and Intel · 2.4 MB**

That link always serves the newest version. Open the DMG, drag MacEQ into
Applications, and see [Install](#install) — the first launch needs one extra
step, because the app isn't signed with a paid Apple certificate.

---

## What it is

Most macOS equalizers work by installing a virtual sound card and asking you to
switch your output device to it. That needs an admin password, it survives badly
across macOS updates, and it usually breaks the volume keys and AirPods
switching.

MacEQ uses the process-tap API Apple shipped in macOS 14.4 instead. It taps the
system audio mix, equalizes it, and plays the result straight back out to your
real output device. Your output stays your output — speakers stay speakers,
AirPods stay AirPods, volume keys keep working.

**Requirements:** macOS 14.4 or later, Apple Silicon or Intel (one universal
app covers both).

macOS 14.4 is a hard floor, not a recommendation. The process-tap API MacEQ is
built on didn't exist before Sonoma 14.4, so there's no version of MacEQ that
runs on Ventura (macOS 13) or earlier — the system calls it needs simply aren't
there. Equalizing system audio on those releases requires a virtual audio
driver instead, which is exactly the admin-password, broken-volume-keys
approach MacEQ was written to avoid.

## Install

1. [Download `MacEQ.dmg`](https://github.com/jatinindia/MacEQ/releases/latest/download/MacEQ.dmg)
   and double-click it.
2. Drag the MacEQ icon onto the Applications folder in the window that opens,
   then eject the disk image.
3. The first launch is blocked, because MacEQ isn't signed with a paid Apple
   certificate. This is expected — see
   [Why does macOS block it?](#why-does-macos-block-it) below. To get past it,
   **once**:
   - **macOS 15 and later:** double-click MacEQ and accept the warning. Then open
     System Settings → Privacy & Security, scroll down to the "MacEQ was blocked"
     line, and click **Open Anyway**. (The old right-click → Open trick no longer
     works — Apple removed it in macOS 15.)
   - **macOS 14:** right-click the app, choose **Open**, then confirm.
4. macOS asks for permission to record system audio. Say yes — this is the
   permission that lets MacEQ hear the audio it needs to equalize. It is
   required for the app to do anything at all.
5. A slider icon appears in your menu bar. Play music and drag a band.

There is no Dock icon and no main window. MacEQ is a menu-bar-only app.

## Features

- **Graphic EQ with editable bands** — the quick way to shape sound. Starts as
  the classic 10-band octave layout (31 Hz to 16 kHz, ±12 dB); add bands at any
  frequency with the **+** button (up to 16), click a band's frequency label to
  retune it, or right-click a band to remove it. Band layouts are saved per
  output device and inside named presets.
- **Full parametric EQ** — 12 filter types, unlimited bands, a draggable
  response curve with a live spectrum analyzer behind it.
- **AutoEQ and REW support** — free correction profiles for 5000+ headphone
  models, and Room EQ Wizard filter exports, import directly. Equalizer APO's
  `config.txt` is MacEQ's native preset format. Anything a preset needs that
  MacEQ can't do (per-ear filters, GraphicEQ, delays) is refused with an
  explanation rather than silently left out — see
  [Importing presets](#importing-presets).
- **Named presets** — save a tuning, switch between tunings in one click.
- **Per-device profiles** — your headphone tuning and your speaker tuning are
  remembered separately and swap automatically when you change output device.
- **Convolution / room correction** — load an impulse response (WAV/AIFF) for
  room correction, headphone correction, or reverb effects.
- **Safety limiter** — catches clipping from aggressive boosts.
- **Auto preamp** — automatically pulls gain back so boosted bands don't distort.
- **Global hotkey** — toggle the EQ from any app. Default `⌥⌘E`, rebindable.
- **App exclude list** — leave chosen apps unequalized.
- **Launch at login**, buffer-size control, live latency/CPU readout.
- **Self-healing** — follows default-device changes, sample-rate changes and
  Bluetooth renegotiation; a watchdog rebuilds the audio path if the system tap
  goes silent.

## Every control, explained

### Main panel

| Control | What it does |
| --- | --- |
| **Switch (top right)** | Master bypass. Off = your audio passes through untouched. Same as pressing the hotkey. |
| **Graphic / Parametric** | Switches editors. Each mode keeps its own settings, and only the active mode is applied to the audio. |
| **+** (graphic mode) | Adds a band at any frequency you type (20 Hz – 20 kHz, up to 16 bands). **Right-click a band to remove it.** |
| **Reset** (graphic mode) | Sets all bands back to 0 dB. Affects **only the current output device's** profile. |
| **Band sliders** | Boost/cut that frequency, ±12 dB. Drag snaps to 0.5 dB steps; **double-click a slider to reset it** to 0. |
| **Frequency labels** (graphic mode) | **Click the number under a slider** to retune that band. Press Return to apply, Escape to cancel. The band keeps its gain and moves into place if it passes a neighbour. |
| **Preamp** | Overall level before the EQ. Boosting bands adds energy and can clip; the preamp pulls it back. |
| **Auto** (next to Preamp) | Computes the preamp for you from the current band gains so nothing clips. Leave this on unless you want manual control — it disables the preamp slider while active. |
| **Status dot + line** | Green = engine running. Shows the output device, sample rate, round-trip latency, and CPU use. |
| **Diagnostics** | Expandable technical detail: callback counts, silent-buffer streak, watchdog restarts, convolution taps, multi-output compensation. Useful when reporting a bug. |

### Parametric mode

| Control | What it does |
| --- | --- |
| **Response curve** | The summed EQ curve. **Drag a dot** to move that band — horizontally changes frequency, vertically changes gain. The grey skyline behind it is a live spectrum of what's playing. |
| **Add Band** | Adds a new filter at a default frequency. |
| **Edit as text** | Swaps the band table for the raw Equalizer APO config. **This is where you paste an AutoEQ profile.** |
| **Band table checkbox** | Enables/disables that one band without deleting it. |
| **Type** | Filter type: `PK` peaking (the usual one), `LS`/`HS` low/high shelf, `LP`/`HP` low/high pass, `LSC`/`HSC` shelves with Q, `LPQ`/`HPQ` passes with Q, `NO` notch, `BP` band pass, `AP` all pass. |
| **Fc** | Centre (or corner) frequency in Hz. |
| **dB** | Gain. Greyed out for filter types that have no gain, like `LP` or `NO`. |
| **Q** | Bandwidth — higher Q is narrower/more surgical. Greyed out for types that don't use it. |
| **Trash** | Deletes that band. |

### The ⋯ menu

| Item | What it does |
| --- | --- |
| **Reset All Bands** | Same as the Reset button: all graphic bands to 0 dB, current device only. |
| **Restore Default Bands** | Puts the graphic EQ back to the classic 10-band octave layout. Gains carry over for frequencies present in both layouts. |
| **Safety Limiter** | Catches overshoots so a heavy boost distorts instead of blasting you. Recommended on. |
| **Launch at Login** | Starts MacEQ automatically when you log in. |
| **Change Hotkey…** | Records a new global shortcut. Must include ⌘, ⌥ or ⌃. Esc cancels. If the combo is taken by another app, MacEQ says so and keeps your current shortcut. |
| **Buffer Size** | Audio block size. Smaller = lower latency, more CPU, more risk of dropouts. Leave on Device Default unless you have a reason. |
| **Excluded Apps…** | Pick apps that should bypass the EQ entirely. |
| **Load / Replace / Clear Impulse Response…** | Loads a WAV/AIFF impulse response for convolution. It's resampled to your device rate automatically. Max ~1M samples (about 22 s at 48 kHz). |
| **Convolution (name)** | Toggles the loaded impulse response on/off. Stored per output device. |
| **Presets ▸** | Your saved tunings. Click a name to apply it, **Save Current as Preset…** to add one (an existing name is replaced), **Delete Preset ▸** to remove one. Presets are global — a tuning saved on speakers can be applied on headphones. They capture the EQ tuning (bands, mode, parametric chain, preamp) but not the bypass switch or the impulse response, which stay per-device. |
| **Import / Export Preset…** | Reads/writes Equalizer APO `config.txt` files. Import is how you load an AutoEQ `ParametricEQ.txt` from disk. Export writes the mode you're in: in Graphic mode, one peaking filter per band, with the preamp your settings call for. |
| **Stop / Start Audio Engine** | Tears down or rebuilds the audio path. The fix to try first if audio ever misbehaves. |
| **About MacEQ** | Version, author, project link. |
| **Quit MacEQ** | Quits. Your audio returns to normal immediately. |

## Using AutoEQ profiles

[AutoEQ](https://github.com/jaakkopasanen/AutoEq/tree/master/results) publishes
measured correction curves for thousands of headphones. Find your model, open
its `ParametricEQ.txt`, and either:

- copy the text, then in MacEQ: Parametric → **Edit as text** → paste, or
- download the file and use **⋯ → Import Preset…**

Your headphones now measure closer to a neutral target. Use the
`ParametricEQ.txt` file, not `GraphicEQ.txt`: MacEQ can't import graphic
curves.

## Importing presets

MacEQ reads Equalizer APO `config.txt` files, which is what AutoEQ, Room EQ
Wizard (**File → Export → Filter Settings as text**) and Peace produce. An import
never silently changes how a preset sounds:

- **Applied:** `Preamp` and `Filter` lines, all 12 filter types. REW's unused
  `None` filter slots are passed over. `Channel: all` (or `L R`) is fine.
- **Refused, naming the line:** anything whose absence would change the sound:
  `Channel:` sections for one ear only (MacEQ runs one filter chain on both
  channels), `GraphicEQ`, `Delay`, `Copy`, `Include`, `Convolution`, `Eval`,
  `If`/`Else`, `LoudnessCorrection`, `VSTPlugin`.
- **Skipped, and listed under the editor:** lines that don't affect the sound on
  a Mac, such as `Device:`, `Stage:` and REW's header lines.

Values are checked too: a filter with a Q of 0, a frequency of 0 or below, or a
value like `nan` is refused with its line number, since it would silence the
output.

## Privacy and security

The honest version, because this app asks for a powerful permission.

**What MacEQ does:** it receives the system audio mix, filters it, and writes it
straight back to your output device. Every sample stays in memory for the few
milliseconds it takes to process.

**What MacEQ does not do:**

- It has **no network code at all** — no telemetry, no analytics, no update
  check, nothing. It cannot send your audio anywhere because it has no code that
  can talk to a network.
- It **never writes audio to disk**. There is no record function.
- It does not read your keystrokes. The global hotkey uses the system's
  registration API, which only ever delivers the one combination you registered.
- It needs no admin password, installs no driver, and modifies no system
  settings.

**What it stores on your Mac:** your EQ settings, presets, per-device profiles,
excluded app IDs, and the path to your impulse response file — in MacEQ's own
preferences, nowhere else.

**The permission is genuinely powerful, though.** "Record system audio" means any
app holding it *could* record everything you hear, including calls. MacEQ
doesn't, and the source is right here for you to check — but that's the reason to
be careful about which apps you grant it to, this one included.

**The trust gap you should know about:** MacEQ is ad-hoc signed, not signed with
an Apple Developer ID and not notarized. Practically, that means macOS can't
verify who built the app, so it warns you on first launch. It also means a
released `.dmg` carries no signature proving it came from this repository. If you
want certainty, build it from source yourself — it's two commands, below. Signing
and notarizing properly needs a paid Apple Developer account and is on the list.

### Why does macOS block it?

Because of that missing paid signature, not because anything is wrong with the
app. Anything you download from the web gets a quarantine flag, and macOS
refuses to open quarantined apps it can't attribute to a known developer.
Approving it once in Privacy & Security clears that for good.

Do that because you trust the source, not because a README told you to — the
same caution applies to every unsigned app you download, this one included.

## Updating

MacEQ does **not** update itself. New versions are published on the
[releases page](https://github.com/jatinindia/MacEQ/releases) — download the
DMG, drag the new MacEQ onto Applications, and confirm the replacement. Quit
MacEQ from the menu bar first if it is running. Your settings and presets are
kept. Check your version in **⋯ → About MacEQ**.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| macOS won't open it at all, even via Open Anyway | Strip the download flag: `xattr -dr com.apple.quarantine /Applications/MacEQ.app`, then open it. |
| No sound at all | ⋯ → **Stop Audio Engine**, then **Start Audio Engine**. |
| No permission prompt appeared | System Settings → Privacy & Security → check MacEQ under audio recording. |
| Permission prompt returns after every rebuild | Expected with ad-hoc signing. Reset with `tccutil reset SystemAudioCaptureRequests com.jatingrewal.maceq`. |
| Distortion on heavy boosts | Turn on **Auto** preamp and **Safety Limiter**. |
| Everything gets quieter when the EQ is on | That's the **Auto preamp** doing its job: with boosted bands it lowers the overall level by the size of your largest boost so it can't clip. The exact cut is shown next to the Preamp slider. Uncheck **Auto** to keep loudness (the limiter still protects against clipping), or use cuts instead of boosts. With all bands flat, MacEQ is acoustically transparent — measurably identical to bypass. |
| Audio mutes right after first launch | Answer the system-audio permission dialog — audio stays muted while the prompt is open. |
| Crackles/dropouts | ⋯ → Buffer Size → a larger value. |
| Nothing is equalized | Check the master switch is on, and that the app isn't in the exclude list. |

## Build from source

Requires macOS 14.4+ and the Swift toolchain (Command Line Tools are enough —
full Xcode is not needed).

```sh
git clone https://github.com/jatinindia/MacEQ.git
cd MacEQ
scripts/build-app.sh
open build/MacEQ.app
```

Run the test suite with `swift run maceq-tests`, and package the release disk
image with `scripts/make-dmg.sh`.

The app icon and the installer backdrop are both generated rather than
hand-drawn — `scripts/generate-icon.swift` and
`scripts/generate-dmg-background.swift` are their editable sources, and each
carries its regeneration steps in the header.

## How it works

A **muted global process tap** captures and silences the system mix. A **private
aggregate device** pairs that tap with the real output device. One **IOProc**
then runs the chain — convolution → biquad cascade → preamp → limiter — and
writes to the output. The limiter sits last so it catches overshoots from every
stage before it.

Notable engineering details:

- The tap must exclude MacEQ's own process or it feeds back on itself.
- Convolution is uniform-partitioned overlap-save with a frequency-domain delay
  line, so a long impulse response costs a fixed, predictable amount of CPU with
  exactly one block of latency.
- All audio-thread work is allocation-free; filter swaps hand ownership back to
  the main thread so the audio thread never releases memory.
- Known platform quirks are handled rather than ignored: intermittent all-zero
  tap buffers after long uptime (watchdog rebuilds the path), level attenuation
  on multi-output devices (compensated in the IOProc), and sample-rate/Bluetooth
  renegotiation (rate listener rebuilds the path).

Source layout: `Sources/MacEQCore` is the portable, tested DSP (filters, kernel,
convolver, APO config parsing, spectrum). `Sources/MacEQ` is the macOS app
(Core Audio engine, SwiftUI). `Tests/MacEQTests` is a standalone test runner —
XCTest needs full Xcode, so MacEQ ships its own.

## Roadmap

- Developer ID signing + notarization, so macOS stops warning on first launch.
- Possibly automatic update checks — deliberately not done yet, since it would
  be the first network access in the app.

## License

MIT — see [LICENSE](LICENSE). Copyright © 2026 Jatin Grewal.
