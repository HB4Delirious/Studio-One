# Changelog

Everything that changed after the initial handoff, when the sources had never
been compiled.

## Build

The project originally had no build system at all.

**Added**

- `build.sh` — compiles, bundles, ad-hoc signs, and stamps the load-bearing
  settings (macOS 14.0 deployment target, Hardened Runtime, Apple Events
  entitlement, no App Sandbox). Builds into a staging bundle and swaps it in only
  on success, so a failed compile can't destroy a working app.
- `package.sh` — builds a drag-to-install DMG with a custom volume icon.
- `project.yml` — XcodeGen spec for building through Xcode.
- `Info.plist`, `Karaoke.entitlements` — including `NSAppleEventsUsageDescription`,
  without which the app crashes on first Spotify contact.
- `Icon/make-icon.swift` — generates the app icon from code; `iconutil` compiles
  the ten-resolution `.icns`.

**Fixed**

- `SpotifyController.swift` — the one genuine compile error. `AECreateDesc`
  returns `OSErr` (Int16) but the closure declared `OSStatus` (Int32).
- SDK selection: with Xcode installed, `xcrun --show-sdk-path` can return a stale
  Command Line Tools path. The script now lets `swiftc` pick its own SDK when
  Xcode is selected, which also retired an earlier workaround for the SwiftUI
  `@State` macro plugin missing from CLT.

## Lyrics

**Added**

- **Slide presentation.** One line owns the stage with the next previewed
  beneath. On a line change the sung line pans up and fades, the preview rises
  into place and grows, and a new preview fades in — a teleprompter push rather
  than a scroll.
- **Word-level timing.** LRCLIB files are mostly line-timed, so word onsets are
  estimated by distributing each line's duration across its words weighted by
  syllable count. Enhanced LRC files with real `<mm:ss.xx>` tags use their own.
- **Ghost asides.** Parenthetical text — backing vocals and ad-libs — is tagged
  during parsing and floated around the window at hashed positions, sizes and
  tilts, fading in on its own word timing instead of crowding the lead line.

**Removed**

- The scrolling lyric list (`ScrollViewReader` / `LazyVStack`).
- The glow on highlighted text.
- Transitions that cycled through four styles by line index.

**Fixed**

- **Words were spread across trailing silence.** A line's `end` is the *next*
  line's start, so a line sung in 2 seconds followed by an 8-second gap had its
  highlight moving at a fifth of the singer's pace. Lines now track when singing
  actually stops, separately from when the next line begins.
- **The sweep never finished.** Measured at 60fps it handed over at 0.949 on
  short words — the last 5% snapped in a single frame. It now completes a couple
  of frames early: 1.000 across every line shape tested.
- **Words rebuilt structurally as they were sung** (bare `Text` → `ZStack` →
  bare `Text`), forcing re-measurement and shifting the row by fractions of a
  point. Every phase now renders an identical view with only a fill fraction
  changing.
- `FlowLayout` measured every word twice per frame; it now caches between
  `sizeThatFits` and `placeSubviews`.

## Sync

**Added**

- **Automatic output-latency compensation.** macOS publishes the output device's
  latency (device + safety offset + stream); it's read via CoreAudio and applied
  continuously, refreshed twice a second so connecting headphones mid-song is
  picked up. This is the Bluetooth delay the original notes described as
  invisible to the app.

Per-track manual trim remains for LRC files mastered against a different
release — that error is in the data and can't be detected without hearing audio.

## Appearance

**Added**

- **Artwork-derived theming.** The cover is downsampled and its three dominant
  hues drive the background fields and tint the control window, cross-fading on
  track change. Falls back to the house palette when a cover yields nothing.
- **Ambient background** — drifting colour fields that swell on each word onset.
- **App icon** — microphone in the app's own amber on the stage backdrop.

**Removed**

- The Windows Media Player-style visualizer (spectrum bars, waveform ribbon).
- Full-bleed album artwork as a background.
- The particle field that briefly replaced it.

**Fixed**

- Panel tint is scaled by the accent's luminance. A flat opacity dropped the dim
  secondary text to 1.5:1 contrast on bright covers (against 3.5:1 untinted);
  every cover now lands near 3:1.
- Palette extraction has a relaxed second pass for dark covers — *Discovery*
  produced a palette from 13 usable pixels out of 1024 — plus a minimum bucket
  size so JPEG noise can't win, and derived companion hues for single-hue art.

## Windows

**Added**

- **Split into two windows.** Controls (artwork, scrubber, transport, key/tempo,
  sync, font) and a chrome-free lyrics display for a second screen or TV.
- Controls is the launch window; the lyrics display opens from a toolbar button,
  ⇧⌘L, or the Playback menu.
- The lyrics window hides its toolbar in full screen.
- The controls window resizes to any shape, with the artwork becoming the
  centrepiece when given height and the control row restacking when narrow.

**Fixed**

- Artwork as a `ZStack` sibling inflated the layout and pushed the control bar
  off-screen; backgrounds don't participate in parent layout.
- The control row jumped twice per track change — the key/tempo block vanished
  during the lookup, flipping `ViewThatFits` between layouts. It now holds a
  fixed slot.
- Only one lyrics window can open (`Window`, not `WindowGroup`), and it can
  full-screen properly (`.contentMinSize` plus `.fullScreenPrimary`).
- A window-configuration update loop made the green button strobe between zoom
  and full screen.
- **The app froze on launch on a Mac without automation consent.** The TCC
  permission check ran synchronously on the main thread and blocks until the user
  answers; it now runs off-main.

## Spotify and metadata

**Added**

- **Key and tempo** from GetSongBPM, cached per track, shown in the control bar
  and hidden entirely when unknown. Spotify's own `audio-features` endpoint
  returns 403 for any app created after November 2024.
- **Scrubbable progress bar** — drag or click to seek, committing on release so a
  drag doesn't flood Spotify with Apple Events.
- **Frame rate setting** — 60fps floor, adjustable up to the display's maximum.

**Fixed**

- **Search never worked.** `limit=25` is rejected by Spotify with
  `"Invalid limit"`; the maximum is 10, contrary to the documented 0–50.
- GetSongBPM returned the wrong song — matching on title alone gave *"Hello
  Babe"* by Madeleine Peyroux for Adele's *"Hello"*. Results are now verified by
  artist, using whole-word comparison (substring matching still accepted
  "m**adele**ine").

## MIDI to Logic

**Added**

- `MIDIBridge.swift` — publishes a virtual MIDI source named **Spot-a-oke** and
  sends on every track change: CC 20 key root, CC 21 major/minor, CC 22 tempo.
  Optional MIDI beat clock, off by default.
- **Send for Learn** buttons that sweep a CC on demand, so a host in learn mode
  has something to bind to without waiting for a track change.

**Fixed**

- A dangling pointer: `UnsafeMutablePointer(&packet)` is valid only for the
  duration of that call, so every MIDI message was built on freed memory.
- The endpoint claims a fixed unique ID. CoreMIDI otherwise assigns a random one
  per launch, so every rebuild looked like a new interface and Logic dropped its
  controller assignments.
- Tempo was truncated rather than rounded, landing Logic a BPM low.
- Tempo is encoded against Logic's actual 5–990 BPM parameter range. Logic maps
  the full CC range onto it and the narrowing fields are greyed out for
  Global → Tempo, so a nominal 40–220 encoding sent 130 BPM as 501.

## Known limits

- Tempo resolution is 7.76 BPM per step, imposed by a 7-bit CC spread across
  Logic's 5–990 range. A 14-bit pair would reach ~0.06 BPM.
- Word timing is estimated on line-timed LRC; held notes still drift within a
  line and re-anchor on the next.
- The background follows the vocal, not the audio — Apple Events expose position
  and transport, never samples.
- No vocal removal, deliberately: Spotify's Developer Terms prohibit modifying or
  separating their audio.
