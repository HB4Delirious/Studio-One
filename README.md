# Studio One

A karaoke host for macOS. It follows whatever Spotify or Apple Music is
playing, shows the lyrics with a sweep that follows the vocal, and sends each
song's key and tempo to Logic Pro as MIDI, so the pitch correction on every
mic retunes itself. A Stream Deck plug-in drives it — and Logic's mic
channels — from the stage, and guests can request songs from their phones.

## How it works

```
Spotify / Music ──Apple Events──▶ PlayerScripts ──▶ Spotify/AppleMusicController
                                                          │ position, track, transport
                                                     KaraokeModel ◀── PlaybackClock (2 Hz → frame rate)
                                                          │
   LRCLIB, NetEase ──▶ LyricsProvider ──▶ LRCParser ──▶ LyricsStage / LyricsPane
   ReccoBeats, GetSongBPM, the song's preview ──▶ TrackAnalysis (key, tempo)
                                                          │
                                   MIDIBridge ──CoreMIDI "Studio One"──▶ Logic Pro
   Stream Deck plug-in ──127.0.0.1──▶ ControlServer (HTTP + a UDP lane for dial ticks)
   Phones on the Wi-Fi ──▶ RequestServer ──▶ "Studio One Requests" playlist
```

A few decisions that aren't the obvious ones:

- **The players are driven over Apple Events.** Spotify's Web Playback SDK
  needs Widevine, which nothing on macOS outside a browser ships, and Music has
  no other API. Apple Events give the position as a float, which is what the
  sync needs. Every script for a player runs on that player's own serial queue
  (`PlayerScripts`), never the main thread.
- **Position is sampled twice a second and extrapolated between.**
  `PlaybackClock` free-runs from the last sample, absorbing a quarter of each
  new sample's error rather than snapping; more than 400 ms is taken as a seek.
  The output device's latency (CoreAudio publishes it — 150–200 ms over
  Bluetooth) is taken off automatically, and a per-song sync trim does the rest.
- **The key reaches the tuners as controller messages.** Plug-ins expose no
  key to a DAW, but anything automatable can be learned in Logic's Controller
  Assignments. See the MIDI map below.

## Build and run

    ./build.sh          # the app, into build/, with the Stream Deck plug-in inside it
    ./package.sh        # a DMG of that build, at build/StudioOne.dmg

Or open it in Xcode:

    python3 make-xcodeproj.py && open "Studio One.xcodeproj"

The project is generated — every `*.swift` at the top level is in the app
target — so after adding a file, re-run the script. It needs only Xcode, and
its settings mirror `build.sh`: hardened runtime with the Apple Events
entitlement, no sandbox (a sandboxed app can't script another app), Swift 5
mode. A second target builds the Stream Deck plug-in's executable.

On first launch, allow the automation prompt for the player you use. Missed it?
**System Settings › Privacy & Security › Automation › Studio One**.

## Accounts (all optional)

- **Spotify client ID and secret** — from an app at
  developer.spotify.com/dashboard. They enable Spotify search and sign-in, and
  are kept in the login keychain, never in source or `UserDefaults`.
- **Sign in to Spotify** — for your playlists, Liked Songs and queue. Add
  `http://127.0.0.1:8725/callback` as a Redirect URI in the dashboard first
  (Spotify no longer accepts `localhost`).
- **GetSongBPM API key** — free; fills in key and tempo where ReccoBeats has
  none.

## Using it

**Setup Assistant.** On a fresh install, Studio One opens with a short
assistant: the player, Logic's key and tempo with the tuner and mic count, the
lyrics screen and your venue's name, and breaks with the applause meter. It
ends at Rig check. Help › Setup Assistant… brings it back; a Mac already set
up doesn't see it.

| Key | Action |
|---|---|
| `Space` | Play / pause |
| `⌘←` `⌘→` | Previous / next track |
| `⌥⌘→` | Fade the song out, then on to the break or the next song |
| `[` `]` | Nudge lyrics 50 ms later / earlier |
| `\` | One-tap sync: press as a line starts, and the song lines up with it |
| `⌘0` | Reset sync |
| `⌘R` | Fetch this song's lyrics again |
| `⇧⌘L` | Lyrics window — drag it to a second screen and go full screen |
| `⌃⌘S` | Hide or show the Controls window's sidebar |

Click a lyric line to seek to it. Sync trim, a key or tempo set by hand, and
×2/÷2 are all remembered per song.

The Controls window: the sidebar has the player switch, search, Playlists,
Requested Songs (with how many) and History, and how Logic stands at the foot
— the plug-in panel appears under the playlists once Logic connects. The Now
Playing pane has the preview (lyric size on its corner), the song with its key
and BPM under it — click them to set them by hand — the transport, Fade Out,
and the song's own tools: Song Settings and Time Lyrics. With nothing playing,
it says why, with the one button that helps.

The lyrics window has no title bar: move the mouse over it and the window
buttons and a Controls button appear for a few seconds. The menu bar's key and
BPM open a small panel — the song, its key and tempo with ×2/÷2, the transport
and Fade Out — for running the night while Logic is in front. Up Next names
whoever requested each song.

The lyrics screen only ever shows the room something meant for it: with no
song, Studio One's mark, what's up next and the request code; while a song's
lyrics load, or when it has none, its title. What's wrong, and what to press,
is in the Controls window.

Settings are grouped — Music, Logic, The room, Help — and each setting's
explanation is behind the ⓘ beside it. Logic's and Mixer's settings appear
once "Send key and tempo as MIDI" is on; Rig check holds the test key, the
backups of Logic's assignments and the log.

## Before the night

Open a playlist and press **Prepare** (or right-click it › Prepare for
Tonight…). Studio One looks up every song's lyrics, key and tempo — the same
lookups as a song starting — and keeps them on the Mac, so each is there the
moment its song starts, even if the venue's Wi-Fi isn't. It then lists the
songs to look at: words with no timing, no lyrics at all, no key, or LRCLIB out
of reach. **Play** on a row starts that song, to time its lyrics or set its
key. Preparing runs on with the sheet closed (the button shows how far it's
got), and Prepare Again picks up anything missed, since what's found is kept.

Keys and tempos the services found are kept on disk as lyrics always were;
one worked out from a song's preview is kept only until Studio One quits, so
the services are asked again next time. Saving a new GetSongBPM key clears
them, to be looked up again with it.

## Lyrics

From [LRCLIB](https://lrclib.net), matched on a title cleaned of versions and
credits, choosing the recording closest in length. When LRCLIB has nothing
timed, NetEase Cloud Music is tried (often timed word by word; it can be
switched off in Settings › Display). Line-timed lyrics get word timings
estimated from syllables.

When nothing is right, **time them yourself**: Time Lyrics restarts the
song and you tap Space as each line starts. Your timing is kept per song in
`~/Library/Application Support/SpotifyKaraoke/Lyrics/Timed by you/`, used
ahead of anything downloaded, and can be shared on LRCLIB — only when asked.

**Duets.** When a line starts with a part marker — karaoke files' `F:` and
`M:`, or `V1:`/`V2:`, `P1:`/`P2:`, and `D:` or `Both:` for both together —
each part sweeps in its own colour (the first amber, the second cyan, both
pink) with a small label above the line being sung. A marker carries on to the
lines after it until the next. To mark a duet yourself, type the markers into
the words when you time a song.

## Party games

Toolbar › **Games**:

- **Song battle** — this song against the next. Each break's applause scores
  its singer; the first break shows the score to beat, the second the winner.
  Needs the break and the applause meter (Settings › Between Songs).
- **Finish the lyric** — later in the song, the end of up to three lines goes
  blank on the screen and on phones, for the singer to finish from memory;
  each fills in once it's sung.
- **Name that tune** — the song's title and lyrics are hidden from the room
  and phones. With the request line on, guests guess on the guest page; the
  first right answer (versions and credits ignored, small typos forgiven in
  longer titles) wins, and the screen shows who and how fast. Reveal shows the
  answer if nobody gets it.

## Venues

Settings › Venue keeps a theme per venue for the room's screens: the venue's
name and a message ("Tuesdays from 8") on the standby and break screens, its
logo in place of Studio One's, the colours the sung words and the second
singer light up in, the typeface, and the background — the song's cover
colours, or one colour. Add a venue, set it up once, and pick it on the night;
the Controls window keeps its own look.

## Difficulty and notes

Each song is rated **Easy**, **Medium** or **Hard** once its timed lyrics are
known — from how fast the words come, the longest held notes and the tempo —
when it plays or when a playlist is prepared. Guests see it beside songs as
they search and in "Sing one again"; you see it in Up Next, your playlists and
the Now Playing pane. The note button beside Time Lyrics keeps a note on the
song ("starts quiet", "great duet"), shown only to you, beside the song in Up
Next and your playlists.

## Between songs

Settings › Between Songs › **Break**: as a song plays to its end, the music
pauses and the lyrics screen shows who's up next — the guest's name when the
song was a request — with the request code to scan, and when the next song
starts. Choose 15 s, 30 s, 1 min, or Until Play. Play (in Studio One, on the
Stream Deck or the remote) starts the next song early; the Controls window has
Start Next Song and +30 s. Next, Previous or picking a song never starts a
break.

**Applause meter** (off until turned on): during the break Studio One listens
for eight seconds on the input you choose — the Mac's microphone or an
interface input — and scores the loudest stretch of the cheer out of 100. The
lyrics screen shows the meter rising, then the score and tonight's loudest
three; History keeps each song's score. Set "Quiet room" once, so the meter
rests at the left between songs. It listens only then and while its settings
are open, records nothing, and macOS asks once for the microphone.

**House music**: a playlist of your own between singers, quieter than the
singing (10–80% of its volume). During a break it starts once the cheer has
been heard; Studio One notes the next song in your queue first and plays it
when the break ends. When the queue runs dry it plays until a guest requests
a song, which then starts straight away. Choosing a song yourself takes over
at once, and Back to the Queue in the Controls window ends it early. It never
ends a break, isn't sent to Logic, isn't kept in History and doesn't show on
the lyrics screen. With Spotify, coming back to the queue needs you signed in.

**Fade out**: Fade Out under the position bar, `⌥⌘→`, the Stream Deck's Fade
Out key or FADE on the remote takes the player's volume down over 3, 5 or 8
seconds, pauses the song at silence and puts the volume back, then starts the
break or the next song. Play, Next or Cancel during a fade stops it with the
volume put back; if Studio One quits mid-fade, the volume is put back when it
next connects. A **time limit** (Off, or 3:00 to 6:00) does it for you: past
it, the song fades as the line being sung ends — the next line's start, up to
15 seconds on, or straight away between lines. A song less than 20 seconds
over is left to finish, and **Let It Play** in the Controls window keeps this
one going.

## Key and tempo

From [ReccoBeats](https://reccobeats.com) by Spotify track ID — songs from
Music are found on Spotify first, which needs the Spotify keys — and from
GetSongBPM by title and artist. Whatever both lack comes from the song's
30-second preview in Apple's or Deezer's catalogue, analysed on the Mac: the
key the notes most of four pitch-class readings name, and the tempo from where
the beats fall. On 37 test songs, where three or four readings agreed (30 of
them) the notes were right for 26. A song with no key at all bypasses the
tuners.

## Logic: the MIDI map

Studio One publishes a MIDI source called **Studio One**. Learn each control
once in Logic's Controller Assignments (⌥⇧K, or Logic Pro › Control
Surfaces); Settings › Logic has a Send for Learn button for every one, and
Settings › Rig check a rehearsal list.

| What | Channel | Controller | Values |
|---|---|---|---|
| Key root (Topline, Logic, Auto-Tune, Waves) | mic's (1–4) | CC 20 (85*) | root, per plug-in's menu |
| Scale | mic's | CC 21 (86*) | major/minor, per plug-in |
| MetaTune note switches | mic's | CC 102–113, C–B | 127 on, 0 off |
| Bypass while a song has no key | mic's | CC 114 | 127 bypass, 0 back on |
| Tempo | 16 | pitch bend | 0–16383 across 5–990 BPM, aimed at the whole BPM |
| Mic channel dials and mutes | 16 | CC 30 + 8 per mic | relative steps; mute toggles |
| Per-song plug-in settings | 16 | CC 70–77 | 0–127, per song |

\* With "Keep clear of Mackie Control" on: a Mackie Control reads CC 16–23 on
channel 1 as its knobs.

The tempo is pitch bend because it's one message with all fourteen bits:
Logic learns it whole (`EF Lo7 Hi7`) and scales it evenly across its tempo
range, where a pair of controllers learns as the coarse half alone. Logic
keeps a tempo from a controller to the whole BPM, so that is what's sent.
Learn Mode can't aim at the tempo, so the learned row is pointed at it in
Expert View — Class Global, Parameter Tempo. Settings › Logic, Show tip beside
Tempo, has the steps.

Logic's assignments are backed up to
`~/Library/Application Support/Studio One/Logic backups/` whenever they change.

## Stream Deck

Settings › Stream Deck installs the plug-in, and a ready-made Stream Deck +
page. It reaches Studio One on 127.0.0.1 with a token from a file only your
account can read. Its Logic and MIDI actions keep working with Studio One
closed: the deck then sends the same messages itself, under the same port name
and identity, so assignments answer either. Version 1.1 adds a Fade Out key;
install the plug-in again from Settings to get it.

## Plug-in display

The lower half of the Controls window shows the controls you pick from the
plug-ins on Topline's channel — Topline's, Vocal Bender's — live from Logic, so
there's no need to be in Logic on top of a plug-in to see where it's set.
Whatever moves them — the M-BRIO, the mouse, automation, a preset — shows at
once, and a control flashes as it changes. One plug-in to a page; the arrows in
the panel's header turn to the next.

Settings › Plug-ins picks them. "Read the Plug-ins from Logic" walks every page
of every plug-in on the channel Logic has locked (a few seconds a page) and
lists each control by Logic's short name, with its value; tick what to show.
The ticked ones are listed in the order the panel shows them: drag to reorder,
and type a name ("Tune amount") to use instead of Logic's ("Amount"). Studio
One reads by itself the first time Logic connects. Read again after adding,
removing or moving a plug-in on the channel: ticks, order and names are kept.

**This song's settings.** The pin in the panel's header remembers the values
shown, for the song playing. Next time it plays, each control shows its
remembered value beside the live one — amber until the M-BRIO brings it back,
then a tick. Studio One sends nothing to the plug-ins.

It works by being a Mackie Control. Logic tells one the names and values of the
plug-in it's editing, sixteen at a time — a page — as text in the plug-in's own
units, and Studio One presents itself as a Mackie Control and an extender
("Studio One Display" and "Studio One Display 2"). Ticks on one of Logic's
pages are live; ticks on several are taken in turn, under a second on each
(longer on one that's moving), so none is more than a second or two old.
Folding the panel stops the page turning. Studio One presses only the
surface's own buttons: Plug-In, a knob press on an insert that holds a
plug-in, the cursor keys.

Once, in Logic Pro › Control Surfaces › Setup…: the Mackie Control's ports are
"Studio One Display", the Extender's "Studio One Display 2" — never "Studio
One", which carries the key and tempo (Logic would give them to the Mackie
instead of your assignments), nor "Any". Studio One reads Logic's saved
control surface setup at launch: a surface on "Studio One" gets a banner in
the Controls window and a line in Rig check saying which, and what to set it
to (Logic saves this as it quits, so it's as of then). Untick Open/Close Plug-in Window and
Follows Focused View, select Topline's channel, and tick Track Lock.

**Logic's alerts.** While Logic has an alert open — a save prompt, "Number of
MIDI ports changed", the end of Scan All Models — it ignores every controller:
the key, the tempo and the M-BRIO. Logic shows the alert on a Mackie Control,
so Studio One spots it at once and puts it across the top of the Controls
window until it's closed, and presses nothing meanwhile.

**Key check** (Settings › Plug-ins, off until turned on). A second surface,
"Studio One Check" and "Studio One Check 2", in a control surface group of its
own locked to Mic 1's channel, keeps MetaTune's twelve switches in view. Each
key Studio One sends is held to what MetaTune then shows: a tick beside KEY
when it landed, "Not in Logic" — and what MetaTune shows instead — when it
didn't. Walk the Switches on Mic 1 is checked step by step in the log, so a
switch learned wrongly shows up by name. Setting up the group: Settings ›
Plug-ins › Key check lists the five steps.

**Mic meters** (Settings › Plug-ins › Mic meters, on by default). Logic also
sends a Mackie Control a level for each channel strip in its bank — eight on
the display, eight on its extender, strips 1 to 16 in the mixer's order. Set
which strip is each mic's channel, and the Controls window shows each mic's
level under the song's tools; on the lyrics screen, a duet's part labels glow
with their singer's mic (part 1 with mic 1, part 2 with mic 2). When lines are
being sung and no mic has been heard for twenty seconds, a warning asks
whether a mic is off or muted. If the meters stay still, bank the units in
Logic so the mic channels are among the sixteen shown.

## Lights

Settings › Lights runs the room's lights over DMX, through a USB interface:
an ENTTEC DMX USB Pro or one that speaks its protocol (DMXking ultraDMX,
Eurolite USB-DMX512 Pro…), or an Open DMX USB / plain FTDI cable, where the Mac
does the timing. Pick the interface's port (Refresh after plugging it in; an
FTDI-based one may want its maker's driver), then add each fixture: a name, its
DMX address as set on the fixture, and its channels — Dimmer, RGB, RGBW,
Dimmer + RGB or Dimmer + RGBW, in that order from the address. Find lights one
fixture in white for six seconds; the test colours light them all.

The show follows the night by itself:

- **A song**: low, in the cover's colours made vivid, so the screen still
  reads; a pulse on each beat when the song's tempo is known; the colours move
  one fixture along every four bars. Paused, they hold low.
- **A break**: bright warm white — and while the applause meter listens, the
  lights follow the cheer.
- **House music**: a gentle breathing in the last song's colours.
- **Nothing playing**: a slow drift round the colours.

Master scales everything; Blackout (Playback › Blackout, ⇧⌘B, while the
lights are on) puts them out until it's turned off. Quitting Studio One puts
them out too. If the interface is unplugged, Studio One keeps trying to open
it again every few seconds.

## Recordings

Settings › Recordings (off until turned on) records each song sung, from the
input you pick — your interface's mix, sent to a spare input, sounds best; the
Mac's microphone records the room. Pick the input's channels (two, or one in
mono). A file per song, stereo AAC, from when the song plays until it ends;
under thirty seconds isn't kept, and breaks and house music aren't recorded.
While it records, the lyrics screen shows **● REC** in its corner, and the
Controls window says who and for how long.

With **Take a photo of each singer**, the camera takes one photo about 45
seconds into the song (its light shows for a couple of seconds); point it at
the stage. macOS asks once for the microphone and once for the camera.

With the request line on, the break after a song shows a code for its
recording beside the request code, and the singer's phone lists theirs under
"Your recording": a page with the photo, a player and **Save the Recording**.
They're kept in `~/Library/Application Support/Studio One/Performances`, a
folder per night, named by time, song and singer, for 1, 3, 7 or 30 days or
until deleted; older ones go when Studio One starts. Settings lists tonight's
to play, show in Finder or delete.

## iPhone remote

Settings › iPhone Remote turns on the Studio One Remote app's access: the
port stays open and is advertised over Bonjour whether or not the request
line is on, with either player. Install the app from `iPhone/Studio One
Remote.xcodeproj` in Xcode onto your phone (a free Apple ID's install runs
seven days, then Run again), tap Pair and scan the code in that pane. It
shows the song, singer and controls, Up Next and Search, and keeps the song
on the Lock Screen as a Live Activity with play and skip buttons while you
use it. Reset the Code there if a phone goes missing.

## Request line

Toolbar › Request Line (Apple Music only). Guests on the same Wi-Fi scan the
code, search your library — Music's scripting can't reach the catalogue — and
their picks join a playlist called "Studio One Requests"; "Play the Requests"
starts it. A second code is your own remote, and not for the room. The server
runs only while switched on. macOS may ask once to allow incoming connections.

Guests can also **follow the lyrics on their phones**: a Lyrics tab on the
guest page, in time with the screen (sync trim included), lighting the line
being sung in its duet colour and showing who's up next during a break. It can
be switched off in the request line's sheet.

**Returning guests**: a phone remembers its guest's name from one night to the
next (filled in, to confirm), and anyone who has sung here before sees "Sing
one again" — their songs from History, most recent first, with how often and
their best cheer — each one tap to request again. Songs are found by the name
requested under, so two guests using one name share a list; the sheet's switch
turns it off.

## Troubleshooting

- **Lyrics drift steadily through a song:** they were timed against another
  release. Set the trim once (or tap `\`); it's remembered.
- **"Can't reach the player" after allowing automation:** macOS records the
  decision against the app's signature — see Signing.
- **One key never reaches the tuners, every other does:** Logic learned a
  whole key change as one control while Learn Mode was on, and now swallows
  that key. Settings › Logic and Rig check name the assignment to delete.
- **Logic doesn't move:** Settings › Rig check › Send a test key, Last sent,
  says what went out.
  Nothing there means MIDI is off; something there means the assignment isn't
  learned or is on the wrong port or channel.
- **Everything else:** Settings › Rig check › Log copies the log
  (`~/Library/Logs/Studio One/studio-one.log`) — track changes, lookups and
  errors; never credentials.

## Signing

An ad-hoc signature is a hash of the binary, so every rebuild is a new app to
macOS: the keychain asks again for the Spotify keys and automation permission
can reset. Any certificate fixes it. `build.sh` and `make-xcodeproj.py` pick
one automatically: `$STUDIOONE_SIGN_ID`; a certificate named **Studio One**
(Keychain Access › Certificate Assistant › Self Signed Root, Code Signing);
the **Apple Development** certificate a free Apple ID gets through Xcode; else
ad-hoc, with a warning. Switching identity prompts once more for the keychain
and automation — choose Always Allow.

## Updates and releases

Studio One checks the project's GitHub releases once a day when it opens
(Settings › Rig check › Updates turns that off; Studio One › Check for
Updates… checks now). A newer version gets a banner in the Controls window —
What's New, Install and Relaunch, Skip, Later. Installing downloads the DMG,
opens it, and installs the app inside only if it's Studio One and is signed by
the same certificate as the copy running: without notarization (a free Apple
ID can't notarize), that signature is the proof it's the same developer's
build. It's copied beside the running app, and once Studio One quits a small
script swaps the two — putting the old one back if that fails — and reopens
it. Updates need the folder Studio One is in to be writable, and both builds
signed with the same certificate (an ad-hoc copy can't update itself).

The repository is `StudioOneUpdateRepo` in Info.plist, as `owner/name`; until
it's set, no checks happen. To make a release:

```
./release.sh 2.0.1 owner/name
```

sets the version (and repository), builds, packages
`build/Studio-One-2.0.1.dmg`, commits and tags `v2.0.1`, then prints the two
steps to publish — push, and attach the DMG to a new GitHub release. It
publishes nothing itself.

## The icon

`./Icon/build-icon.sh` redraws it from `Icon/make-icon.swift`.
`./build.sh` gives the flat icon; `./build.sh --glass` adds a Liquid Glass one
for macOS 26 (it needs Xcode's `actool`). macOS has no appearance-aware app
icon otherwise, so `DockIcon.swift` swaps the Dock icon for dark mode while the
app runs; the Finder shows the light one.

## Credits

Lyrics: [LRCLIB](https://lrclib.net) and NetEase Cloud Music. Key and tempo:
[ReccoBeats](https://reccobeats.com), previews found through Apple's iTunes
Search API, and **powered by [GetSongBPM](https://getsongbpm.com)** — their
terms ask for this link, which also appears in Settings.

## What it doesn't do

No vocal removal. Spotify's terms forbid modifying their audio and Music's
streams are encrypted, so this is a sing-along over the original recording.
True instrumental karaoke would need local files and a separate playback path.
