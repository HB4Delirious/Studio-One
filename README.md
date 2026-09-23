# Studio One for macOS

A SwiftUI sing-along display. Spotify plays the track; this app shows the lyrics and
sweeps a highlight across each line in time with the vocal.

## How it works

```
Spotify desktop app ──Apple Events──▶ SpotifyController   (position, track, transport)
                                             │
                                        PlaybackClock     (smooths 2 Hz samples to 30 fps)
                                             │
LRCLIB ──HTTPS──▶ LyricsProvider ──▶ LRCParser ──▶ LyricsStage
                                             │
Spotify Web API ──▶ SpotifyAPI (search only, client credentials)
```

Three decisions worth knowing about, because they're not the obvious ones:

**Playback runs through Apple Events, not the Web Playback SDK.** The SDK needs
Widevine DRM, which neither Electron nor WKWebView ships on macOS. Driving the
Spotify desktop app sidesteps DRM entirely and gets you `player position` as a
float, which is what the sync engine actually needs.

**Position is sampled at 2 Hz and extrapolated in between.** Each Apple Event costs
10–20 ms, so polling at frame rate would be wasteful and jittery. `PlaybackClock`
anchors to the last sample and free-wheels off `CACurrentMediaTime()`, nudging 25%
of the error per sample instead of snapping. Errors over 400 ms are treated as a
seek and snapped immediately. Round-trip latency is halved and added back to the
sample, since the reading was true somewhere in the middle of the call.

**Search uses client credentials, not OAuth.** Search hits the public catalogue, so
no user login is needed and there's no local redirect server to run. If you later
want your own playlists or library, that's the point where you'd add Authorization
Code + PKCE — note the redirect URI has to be `http://127.0.0.1:PORT/callback`,
because Spotify rejects the literal hostname `localhost` now.

## Setup

### 1. Create the Xcode project

New project → **macOS → App**, interface **SwiftUI**, language **Swift**.
Set the deployment target to **macOS 14.0** (the code uses the two-parameter
`onChange` and `NSRunningApplication.activate()`).

Delete the generated `ContentView.swift` and `<Name>App.swift`, then drag in:

```
SpotifyKaraokeApp.swift
KaraokeModel.swift
Services/PlaybackClock.swift
Services/SpotifyController.swift
Services/LRCParser.swift
Services/LyricsProvider.swift
Services/SpotifyAPI.swift
Services/Credentials.swift
Views/Theme.swift
Views/LyricsStage.swift
Views/ContentView.swift
Views/Sheets.swift
```

### 2. Turn off App Sandbox

Target → **Signing & Capabilities** → remove the **App Sandbox** capability.

A sandboxed app can only send Apple Events to another app with a
`com.apple.security.temporary-exception.apple-events` entitlement, which is a
dead end for App Store distribution anyway. For a personal build, off is simpler.

Leave **Hardened Runtime** on, but tick **Apple Events** under its checkboxes
(that's `com.apple.security.automation.apple-events`) — without it the Apple
Event is blocked before TCC even asks.

### 3. Add the usage string

Target → **Info** tab → add key:

| Key | Value |
|---|---|
| `NSAppleEventsUsageDescription` | Studio One reads the current track and playback position from Spotify to keep the lyrics in sync. |

macOS shows this text in the consent dialog. If it's missing, the app crashes
the first time it talks to Spotify.

### 4. Get Spotify keys (optional)

Only needed for in-app search. Everything else works without it — the app follows
whatever you play in Spotify directly.

1. developer.spotify.com/dashboard → **Create app**
2. Any name; the redirect URI field is required by the form but unused here —
   put `http://127.0.0.1:8888/callback`
3. Copy the client ID and secret into the app's Settings sheet

They go into your login keychain, not into source or `UserDefaults`.

### 5. Run

Launch Spotify, start a track, then run the app. Approve the automation prompt
on first launch. If you dismiss it by mistake:
**System Settings → Privacy & Security → Automation → Studio One → Spotify**.

## Using it

| Key | Action |
|---|---|
| `Space` | Play / pause |
| `⌘←` `⌘→` | Previous / next track |
| `[` `]` | Nudge lyrics 50 ms later / earlier |
| `\` | Sync: press as a line starts to be sung, and the song's lyrics line up with it |
| `⌘0` | Reset sync |
| `⌘R` | Re-fetch lyrics for this track |

Click any lyric line to seek there. The sync trim is saved per track, so once
you've dialled a song in it stays dialled in.

## Lyrics quality

LRCLIB is community-contributed, so coverage varies: strong on popular Western
tracks, thinner on new releases and non-English catalogues. Some entries carry
word-level timing (`<mm:ss.xx>` tags) and get a true per-word sweep; the rest are
line-timed and sweep at a constant rate across the line.

The provider strips the noise Spotify puts in titles before searching —
`- 2011 Remaster`, `(feat. …)`, `- Radio Edit` — and falls back from the exact-match
endpoint to a search that picks whichever result's runtime is closest to what's
playing. When the match is still wrong, `⌘R` clears the cache and tries again.

Cached `.lrc` files live in
`~/Library/Application Support/SpotifyKaraoke/Lyrics/`.

When LRCLIB has nothing timed, NetEase Cloud Music is tried next — it often
has timing word by word (Settings › Display can turn it off). For lyrics that
are right but early or late, press `\` as a line starts and the song lines
up with it.

When neither has timed lyrics, the timing drifts, or there are no words at all,
**time them yourself**: the hand button in the Controls window restarts the
song and you press Space as each line starts (paste the words in first if
there were none). Your timing is saved per song in `Lyrics/Timed by you/`,
used ahead of LRCLIB, and left alone by `⌘R`. Tick "Also share it on
LRCLIB" to publish it for everyone else — only ever when you ask.

## Before a party

Settings › **Rig check** shows what's connected right now and walks through a
rehearsal on the rig: MetaTune's switches, song changes, playlists, the
request line, the Stream Deck with Studio One open and closed, and a backup of
Logic's assignments once everything is learned (Settings › Logic keeps
automatic copies too).

## Troubleshooting

**Lyrics drift steadily over a song.** That's an LRC file mastered against a
different release. Set the trim once; it's remembered.

**Lyrics are right but lag ~200 ms.** Bluetooth headphones. AirPods add roughly
150–200 ms of audio latency that the app can't see, so trim negative.

**"Studio One can't reach Spotify" after granting permission.** Check the Apple Events
box under Hardened Runtime, then delete derived data and rebuild — TCC caches the
decision against the code signature.

**Nothing happens when you pick a search result.** Playback via `play track` needs
the Spotify app running and signed in.

## The icon

`./Icon/build-icon.sh` redraws it from `Icon/make-icon.swift`, producing both
forms at once.

| Build | Icon |
|---|---|
| `./build.sh` | Flat: gradient plate, white mark. Identical on every macOS. |
| `./build.sh --glass` | Liquid Glass on macOS 26 and later, falling back to the flat icns below that. Needs Xcode — `actool` doesn't ship with the Command Line Tools. |

Liquid Glass changes who owns what. The system supplies the background and
lights your artwork as a glass material, which makes a translucent white mark
almost invisible — so in that build the gradient moves into the mark itself,
on the system's dark ground. It is a different-looking icon, not the flat one
with an effect applied.

`--glass` adds `Assets.car` and `CFBundleIconName` to the bundle. The full
ten-size `.icns` stays alongside them, so older macOS still gets a sharp icon at
every size.

### Dark mode

In dark mode the plate goes black and the gradient moves into the mark itself.

macOS has no appearance-aware app icon to hang that on. An `.icns` holds one
image, and the asset-catalog route means Liquid Glass, which renders its own way
— `is-glass: false` is ignored and the appearance specializations compile but
change nothing, both checked by compiling them and asking macOS to render the
result. So `DockIcon.swift` sets the icon at runtime instead, and follows
`AppleInterfaceThemeChangedNotification`.

That reaches the Dock icon and the app switcher while the app is running. The
Finder icon, and the Dock icon before launch, still come from the `.icns` named
in Info.plist — always the light artwork. In a `--glass` build this steps aside
entirely and lets the system do it.

## Request line

Toolbar → the QR button. Guests scan, search this Mac's Apple Music library, and
what they pick is added to a playlist called "Studio One Requests"; "Play the
requests" starts it, and Up Next then shows the queue.

Everyone has to be on the same Wi-Fi. The link carries a random token, but
anyone holding it can add a song — that is the point at a party, and the reason
not to pass it beyond the room. The server runs only while it is switched on.

Guests can request only what is already in your library. Apple Music's scripting
interface searches your library and never the catalogue.

macOS may ask whether to allow incoming connections the first time. That prompt
needs a human click.

## Opening it in Xcode

    python3 make-xcodeproj.py && open "Studio One.xcodeproj"

The project is generated rather than kept by hand, so adding a Swift file to
the folder is all it takes — re-run the script and it is in the target. It
needs nothing installed beyond Xcode itself. (`project.yml` is the older
XcodeGen spec, kept because it documents the same settings; XcodeGen isn't
needed.)

Two targets:

- **Studio One** — the app. Press Run. Its build settings mirror `build.sh`, so
  an Xcode Release build and a `./build.sh` build produce the same thing:
  ad-hoc signed, hardened runtime, the Apple Events entitlement, no sandbox,
  Swift 5 mode. A build phase also builds the Stream Deck plug-in and puts it
  inside the app, as `build.sh` does.
- **StudioOneDeck** — the Stream Deck plug-in's executable, so its source gets
  the same editor checking as the app. The installable plug-in itself is built
  by `StreamDeck/build.sh`, which the app target runs.

Debug builds are signed without the hardened runtime — Xcode's own doing, for
Previews — so they will differ from `build.sh`'s output in that one respect.
Release builds match.

To sign with your Apple Development certificate instead of ad-hoc, set
`CODE_SIGN_IDENTITY` on the target (or in `make-xcodeproj.py`, so it survives
regeneration). That also stops the keychain asking again after every rebuild,
since the ACL follows a stable signature.

## Signing

An ad-hoc signature is identified by `cdhash`, a hash of the compiled binary, so
every rebuild is a different application to macOS: the login keychain asks again
for the Spotify keys, and automation permission can reset too.

Any certificate fixes it, because the signature then names the app and the
certificate instead of hashing it. `build.sh` and `make-xcodeproj.py` both pick
one up automatically, in this order:

1. `$STUDIOONE_SIGN_ID`, if set.
2. A certificate named **Studio One** (made in Keychain Access → Certificate
   Assistant → Create a Certificate, Self Signed Root, Code Signing).
3. The **Apple Development** certificate a free Apple ID gives you — Xcode
   creates it when you add your Apple ID in Settings → Accounts.
4. Ad-hoc, and a warning that the keychain will keep asking.

The difference is visible in what macOS records as the app's identity:

    # ad-hoc — changes on every rebuild
    designated => cdhash H"5b885b2f8b53428519b98fdbdc452f342c8dd986"

    # signed — the same after every rebuild
    designated => identifier "com.logan.SpotifyKaraoke" and anchor apple generic
                  and certificate leaf[subject.CN] = "Apple Development: …"

Switching identity prompts **once** for each thing that trusts the app — the
keychain, and automation for Music or Spotify — because it genuinely is a new
identity. Choose **Always Allow**, and rebuilds stop asking.

Xcode needs the team from the certificate's OU field, not the code in its name;
those look alike and are different things. `make-xcodeproj.py` reads the OU.

## Credits

Timed lyrics come from [LRCLIB](https://lrclib.net).

Key and tempo come from two sources, tried in order. Spotify's own
`audio-features` endpoint returns 403 for any app created after November 2024,
so it isn't usable.

1. [ReccoBeats](https://reccobeats.com) — keyed by Spotify track ID, so there's
   no title matching to get wrong, and it needs no API key.
2. **Powered by [GetSongBPM](https://getsongbpm.com)** — covers what ReccoBeats
   is missing, matched on title and artist. Free, and asks only for a visible
   link back to their site in return; that link appears in the app's Settings
   sheet, and above.

Either alone leaves gaps. Together they answered every track tested.

## One thing this deliberately doesn't do

There's no vocal removal. Spotify's Developer Terms prohibit modifying or
separating their audio, so this is a sing-along over the original recording, the
same as Spotify's own lyrics view. If you want true instrumental karaoke, that has
to run on local audio files — Demucs handles the separation well — and would be a
separate playback path from the Spotify one.
