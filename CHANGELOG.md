# Changelog

Everything that changed after the initial handoff, when the sources had never
been compiled.

## Better-timed lyrics without tapping

- **NetEase Cloud Music as a fallback.** When LRCLIB has nothing timed, the
  lyrics come from NetEase — often timed word by word. Tested on four songs,
  all word-timed; wrong-length versions and unknown songs are turned down
  rather than guessed. Its lookups use a session with cookies off: once
  NetEase's cookie was sent back it answered every search with unrelated
  filler, so only the first song of a session ever worked. Not an official
  API; it can be switched off in Settings › Display.
- **Share your timing on LRCLIB**, opt-in when saving a tapped timing or
  afterwards with a confirmation. Solves LRCLIB's proof-of-work check the
  way its reference client does (tested against a real challenge).
- **One-tap sync.** Press `\` — or tap the Stream Deck's Lyric Sync strip —
  as a line starts being sung, and the song's lyrics line up with it. Holding
  the strip now reloads the lyrics.
- Backing vocals from word-timed files no longer show doubled spaces.

## Timing, song settings, singers, history and rehearsal

- **Tap-to-time lyrics.** The hand button restarts the song; Space as each
  line starts, G for an instrumental break, Delete to undo. Paste lyrics in
  for songs with none. Times are what's heard (the output delay comes off),
  saved per song apart from the download cache, and used ahead of LRCLIB.
- **Per-song plug-in settings.** Eight named controls (channel 16, CC 70–77)
  — MetaTune's retune speed per mic, say — that each song remembers and sends
  as it starts. Tested on the wire: sweep, then the song's own value.
- **Up next.** The lyrics screen shows who's singing (first seconds of a
  requested song) and who's next (last thirty seconds); guests' phones show
  where their requests stand.
- **History.** Every song played for thirty seconds, with singer and key,
  night by night (6 am to 6 am). Copy a night, delete it, or queue its Apple
  Music songs again.
- **Logic's assignments backed up** automatically at launch when changed, and
  on demand, with restore (refused while Logic runs; it rewrites the file as
  it quits).
- **Auto-quitters named.** Another app quitting Studio One with no window
  open is remembered and explained next launch — verified against Vorssaint.
- **Mackie-safe numbers** for key, scale and tempo (CC 85/86/87/119), opt-in.
- **Stream Deck + page**, generated in the app's own profile format and
  installed from Settings › Stream Deck. Not yet tried on hardware.
- **Rig check** tab: live status and the rehearsal checklist.

## Lyrics: highlight, follow, or the whole page

Settings › Display › Lyrics chooses how timed lyrics are shown:

- **Highlight as sung** — as before: each word swept in amber as it's sung,
  the line lifting on the beat, lines moving on with the song.
- **Follow, no highlight** — lines still move on with the song, in plain
  white: no sweep, no lift, no beat swell. Runs at 30 fps, since nothing is
  animating word by word any more.
- **Full lyrics** — the whole song on one still page to scroll through.
  Instrumental gaps show as verse breaks.

The thumbnail in the controls window follows the choice. Checked by
rendering each style offline and by switching them live with a song loaded.

**Also fixed: long lines ran into the next one.** The preview line always sat
at 76% of the height, so a sung line that wrapped to three rows — at the 80 pt
size, "And catch my / breathing even closer / behind" — ran down into it and
the two were drawn over each other. Each row is measured now; the preview
sits below the sung line's real bottom edge, and at extreme sizes both rise
together rather than running off the screen. Ordinary lines are unchanged.

## Second hardening pass

**Idle CPU: 12–15% → 0%.** Every poll reassigned the track, the play state
and the connection whether or not they had changed, and a published value
announces a change on any assignment — so both windows rebuilt twice a
second, forever, with nothing playing. Measured before and after with both
windows open. Only real changes are published now; the lyric view, which no
longer redraws for free while paused, is told when a paused position moves.

**Lyrics jumped back after every seek.** A poll already in flight returned
the old position and the clock snapped to it, then forward again. Readings
taken before a seek lands are now ignored.

**A player behind a dialog froze the controls for two minutes.** That is
AppleScript's default timeout, and every button pressed meanwhile queued
behind it. The status check now gives up after 4 seconds and commands after
10, with "isn't answering — close any dialog" rather than a raw error.

**Apple Music playlists addressed by position.** Adding or removing a
playlist — including the requests playlist this app creates — shifted every
position after it, so a click could open or play from the wrong one. Music's
dictionary does give playlists a persistent ID (a note here said it didn't);
they are addressed by it now, and a track is found by its database ID at the
moment it's played rather than by where it sat when the list was read.

**"Play the requests" stopped after one song.** It used `play track 1 of p`,
which this file's own verified note says leaves Up Next empty. It plays the
playlist itself now, and says so when nothing has been requested.

**Keys written out in full read as major.** "A minor", "E♭ minor", "G min"
all came out major — three wrong notes sent to the tuners. Every source's
key so far has been short ("Bm"), so this hadn't bitten, but the reader now
takes any spelling; tested on 30. The key editor seeded "Eb" as a plain E and
used its own reading; it uses the shared one now.

**Smaller things.**
- A typo or "120,5" in the BPM box erased any tempo set earlier; it is now
  read either way and kept to 20–400, the same bounds the nudges use (they
  stopped at 250, so +1 from 300 dropped to 250).
- The sync trim is kept within ±10 s; a Stream Deck dial spun hard went
  anywhere.
- A quickly spun volume dial lost ticks to a race; fixed.
- The request line stops, and says why, if the source is switched away from
  Apple Music — it went on filling a playlist nobody was playing.
- Keychain writes update in place. Delete-then-add lost the value if the add
  failed, and the Spotify refresh token is rewritten hourly.
- Phone pages: a dropped request no longer freezes the seek or volume
  slider; an old search can't overwrite a newer one; failed Queue/Play
  buttons re-enable with a message.
- The MIDI action's settings save as you type, not only on leaving a field.
- The lyrics window said "Looking for Spotify…" on Apple Music.
- `NSLocalNetworkUsageDescription`, so a macOS network prompt says why.
- `package.sh` retries a busy volume instead of failing, and cleans up.

## Polish and hardening pass

A review of the whole app for things that could break mid-show, each proved
before it was fixed.

**Could send the wrong key.** A song change restored its saved values one at
a time, and each re-sent MIDI as it landed — the first while the previous
song's hand-set key was still in place. With key changes swept out to every
tuner, the old key reached them; if the new song had no key of its own, it
stayed. A song change now restores quietly and sends once, when its analysis
arrives.

**Froze the window.** Play, pause, next, previous and seek ran their
AppleScript on the main thread, and starting a library track took about a
second there (it skips through the playlist). They also ran beside the
snapshot on the polling queue, which NSAppleScript does not allow. All of it
now runs on each player's serial script queue, and failures show in the
status line instead of vanishing.

**Signed out of Spotify an hour in.** When the hourly token expired, the
library's burst of requests each refreshed it with the same refresh token;
Spotify may rotate that token on use, and the losers' 400 was read as
"revoked". One refresh now runs and everyone waits for it.

**Ports that looked open and weren't.** `NWListener` never refuses a busy
port when created — it fails a moment after starting. The request line and
the Stream Deck's control port walked their ranges by catching an error that
never comes, so with the first port taken they published it and died.
Verified with 8730 and 8740 held: the app now lands on 8731 and 8741.

**Wrong lyrics, wrong key.** Lookups cut the artist to its first name before
searching, so "Earth, Wind & Fire" became "Earth" — a different band on both
LRCLIB and GetSongBPM — and "Daryl Hall & John Oates" found only untimed
lyrics. The full name is tried first. The two lyric lookups also run at once
now instead of one after the other.

**Regions that write 213,5.** AppleScript writes decimals the Mac's way, so
under a German or French region every duration and position read as 0 and
the lyrics never moved. Verified under de_DE and fr_FR; parsed either way now.

**Smaller things.**
- Reload lyrics refetches the lyrics only; it used to rewind the lyric clock
  and resend the key.
- Opened before the player, the library stayed empty all session. It loads
  when the player answers, and says why it's empty until then, with a button.
- Clicking two playlists quickly could show the first one's songs under the
  second's name; switching sources could paint old covers on new playlists.
- Settings: "Cancel" cancelled nothing — everything but the keys applies at
  once. The footer is now "Done", with Discard/Save only after editing a key,
  and only changed keys are written (rewriting one can re-raise its keychain
  prompt). A new GetSongBPM key took a relaunch to work; it doesn't now.
- Guest requests didn't reach the remote's Up Next until the song changed; a
  "+" in a search became a space; the remote's volume never refreshed.
- The request server caps request bodies at 16 KB instead of buffering
  whatever a declared length promised, and skips 169.254 addresses.
- The scrubber showed 0:00 of 0:01 with a knob when nothing played.
- The lyrics window's "Open Apple Music" button greyed out whenever that
  window wasn't the active one — which on a second screen is always.
- VoiceOver read the transport buttons backwards ("Go To End" for previous);
  the text-size buttons had 6×7-point targets.
- Stream Deck tab: port shown as "8,730"; the Logic and MIDI actions were
  missing from its list. "Add a key below" pointed at a field on another tab.
- The Xcode project left the plug-in's `midi.swift` out, so the plug-in
  target no longer built there. Both targets build again.
- Lines sharing a timestamp keep their order; lyric cache names are safe for
  titles containing "/"; a stale "isn't running" clears once the player is up.
- No compiler warnings, including under strict concurrency checking.

## Three pitch plug-ins on offer

The picker now lists Slate Digital MetaTune, Topline Vocal Suite and Logic
Pitch Correction, in that order — the rig's first choice, second choice and
backup. Auto-Tune Access and
Waves Tune Real-Time are no longer offered, but nothing about them was
removed: whichever is already chosen stays listed and keeps working, and drops
out of the list once something else is picked. "Topline / key + major-minor"
is now just "Topline Vocal Suite".

## Dial ticks have their own lane: under a millisecond

Measured by a bench that plays the Stream Deck and listens on the MIDI port at
once, timing forty ticks 15 ms apart. With Studio One running, each tick used
to open a connection to the control port, wait its turn on the main thread —
the one drawing the lyrics — and carry the whole state back: **3 ms typically,
40 ms at worst**, with the app idle. That is a fader visibly trailing the hand.

Now each tick is one datagram to a port beside the control port (8740–8749,
127.0.0.1 only, listed in `control.json` as `midiPort`). It carries the token
and the three bytes of a controller message; Studio One checks both and puts
it on the MIDI port from the network thread as it lands. No connection, no
reply, no main thread. **0.8 ms typically, 7 ms at worst** — unchanged with the
main thread deliberately kept busy. Studio One shut: 0.6 ms, as before.

The "Last sent" line still follows the dial, updated with the latest message
at most ten times a second rather than once per tick. Anything that isn't a
controller message, or lacks the token, is dropped. If the lane can't open,
the deck falls back to the control port.

Also: Logic's Controller Assignments shortcut is ⌘K. The app and the deck's
settings panel said ⌘L.

## The deck sends its own MIDI, so Studio One needn't be running

The Logic controls now work with Studio One shut. They are MIDI, and the deck
can send MIDI; only the actions that drive the app itself need the app.

**One port, two possible senders.** Logic ties an assignment to the port a
message came from, so the plug-in claims the same name *and* the same pinned
identity Studio One's port uses ("SPOK"). Learn a control once and it answers
whichever sent it. The plug-in holds that identity only while Studio One is
away and lets go within a poll of it reappearing; when Studio One is up,
everything routes through the app as before, so its "Last sent" line still
tells the whole story.

Two sharp edges came out of testing that, both fixed:

- **A launch race.** Studio One claimed its identity once, at startup. Launched
  while the deck held it, it took a random one instead — and every assignment
  Logic knew would have gone deaf for that whole session, silently. It now
  watches until it has the identity: one property read every three seconds,
  which nothing can outlast. Caught by holding the port deliberately and
  launching into it; before the fix the app kept the wrong identity, after it
  the app took over the moment the port was released.
- **A silent failure.** If the port couldn't be created — seen when the previous
  instance is still letting go — `start()` returned without a word, which looks
  exactly like "MIDI does nothing". It now says so in the log and tries again.

**Two freely assignable actions**, MIDI Dial and MIDI Button, for everything
beyond the mic table: any controller number, any channel, nudge or absolute
value, with its own settings panel. Useful for whatever else you have learned
in Logic, and the reason the plug-in no longer needs Studio One to reach it.

**The key-and-tempo switch no longer gates them.** That switch is about
publishing key and tempo by itself; a dial being turned is not that, and it
made no sense that a dial worked with the app closed and not with it open.

Verified on the wire in both directions: with Studio One running, mic level +2
→ CC 30 = 2 on channel 16, dial press → CC 37, and the app's log records it;
with Studio One quit, byte-identical messages from the deck's own port. Both
with the key/tempo switch off.

## Four plug-in parameters per mic, and a channel of their own

Asked for volume *and* AU plug-in parameters on a Stream Deck+ page. There was
one plug-in slot per mic, so now there are four — Level, Send A, Send B,
Plug-in 1–4, Mute. The slots are deliberately unnamed: whatever you learn them
to, a tuner's correction amount, a gate threshold, anything Logic can learn.

**The mixer moved to MIDI channel 16.** With eight controls per mic and up to
four mics the numbering would have run into the tempo's fine half (CC 54); on
its own channel it can't collide with the key, the scale or MetaTune's note
switches however far either set grows. Verified on the wire: mixer traffic on
channel 16 while a key change goes out on channels 1–2 in the same breath.

A ready-made page was not shipped. A plug-in can carry one for Stream Deck+
(device type 7), but Elgato makes them with the Stream Deck app's Export
button, the file format isn't documented to write by hand, and there is no
Stream Deck app here to test an import against. Exporting one from the rig and
bundling that is the honest route.

## Stream Deck dials for the mic channels in Logic

Route A of the two we weighed: MIDI, learned in Logic, rather than emulating a
Mackie Control. Logic can aim an assignment at a numbered channel strip, so a
dial owns Mic RED whatever is selected, and it takes MIDI in the background, so
Studio One can be the front app.

**Dials send steps, not positions.** A position would be a number this app
invented, and Logic's Pickup mode ignores a controller until it reaches the
parameter's current value — what stopped key changes reaching Waves Tune. A
step says "up one" and Logic moves the fader from wherever it is: nothing to
catch up with, and no fader sweeping across the room to get there. The cost is
that nothing here knows a fader's real position, so the dial shows what it sent
("▲ 3"), not where the fader is, and the touch strip uses a layout with no
position bar rather than drawing one that would be fiction.

**Controls**, five per mic, following "Mics with a tuner": Level, Send A, Send
B, Plug-in, Mute — CC 30–49, clear of the key (20, 21), tempo (22, 54) and
MetaTune's notes (102–113). Studio One sends them on the "Spot-a-oke" port
Logic already knows, so there is no second MIDI device to set up, and each has
a Learn button in Settings › Logic. A dial's learn burst moves both ways, since
Logic can't recognise an encoder from one direction; a button's is press,
release, press, release.

**Two step formats**, sign magnitude and two's complement, because Logic reads
either once its Expert view is told which, and which one a setup wants isn't
knowable from here.

**In the plug-in**: one "Logic Mic Dial" and one "Logic Mic Mute", each with a
settings panel listing the controls — so four dials can be whatever you want
rather than four things I guessed. Pressing a dial mutes its own mic. An action
with nothing chosen shows Stream Deck's warning rather than sending something
arbitrary.

**Tested end to end**, Stream Deck event → plug-in → Studio One → MIDI port,
with a listener on the port: up 3 → CC 30 = 3; down 1 → CC 30 = 65 (and 127 in
two's complement); press → CC 34, the mic's mute; the mute key → CC 39; an
unset dial warns and sends nothing; both settings panels receive all ten
controls. Learn bursts and both step formats were checked on the wire
separately.

**Not tested:** Logic itself — it isn't on this Mac. Whether Logic's Learn
takes the encoder as Relative on its own, or needs Mode and Format set by hand
in Expert view, is the thing to watch.

## Errors named Spotify while Apple Music was playing

From a log: "Spotify isn't running. Open Spotify and start a track" and
"Spotify didn't respond: Music got an error: Can't get current track" — both
while the source was Apple Music, the second one quoting Music's own error in
the same sentence.

One error type is shared by both controllers, and its messages hard-coded
Spotify. They now name whichever source is driving. Checked for both sources
against all four messages.

## The keychain stops asking after every rebuild

The app was ad-hoc signed, and an ad-hoc signature *is* a hash of the binary:

    designated => cdhash H"5b885b2f8b53428519b98fdbdc452f342c8dd986"

Every rebuild changed that hash, so every rebuild was a new application to
macOS, and "Always Allow" on the keychain prompt applied to a build that no
longer existed. `build.sh` already preferred a certificate, but only one named
"Studio One", which was never created; this Mac's free **Apple Development**
certificate was sitting unused.

Both builds now take whatever certificate exists — `$STUDIOONE_SIGN_ID`, a
"Studio One" certificate, an Apple Development one, ad-hoc only as a last
resort. The identity becomes:

    designated => identifier "com.logan.SpotifyKaraoke" and anchor apple generic
                  and certificate leaf[subject.CN] = "Apple Development: …"

**Verified** by building twice and comparing: the two binaries differ (different
SHA-256) and the designated requirement is identical, where the ad-hoc one was a
hash of the binary itself. The Xcode project produces the same requirement as
`build.sh`, so the two routes are interchangeable to the keychain.

Xcode rejected the certificate twice before this worked. It wants the generic
kind ("Apple Development") rather than the full certificate name, and the team
from the certificate's OU field — not the ten-character code inside the
certificate's name, which looks exactly like a team ID and is not one.

One more prompt each for the keychain and for automation, since the app really
is newly identified; after that they stop.

## An Xcode project

`make-xcodeproj.py` writes `Studio One.xcodeproj`. XcodeGen would have done this
from the `project.yml` that was already here, but it isn't installed and
installing it means downloading a toolchain, so the project file is written
directly — Xcode is the only requirement.

Two targets: the app, and the Stream Deck plug-in's executable so its source is
checked in the editor too. The app target carries a build phase that runs
`StreamDeck/build.sh` and puts the packaged plug-in in Resources, matching what
`build.sh` does.

Settings mirror `build.sh` so both routes produce the same app. Verified:
`xcodebuild` Debug and Release both succeed, both targets build, the Release
app's signature reads `flags=0x10002(adhoc,runtime)` — identical to the
script's, and universal where the script builds arm64 only — and the built
bundle contains the icons, the entitlement and the Stream Deck plug-in. A zip
of the folder, unpacked elsewhere, builds from scratch, so nothing depends on
where it lives.

The built app was not launched: a second copy would start its own control port
and rewrite the file the running app and the Stream Deck plug-in share.

## Stream Deck and Stream Deck+ plug-in

Settings › Stream Deck › **Install the Stream Deck plug-in**. The plug-in is
built with the app (`StreamDeck/build.sh`, run by `build.sh`) and carried in its
Resources; installing hands it to the Stream Deck app, after checking that the
Stream Deck app is what would open it.

**Keys:** Play/Pause (shows its state), Next, Previous, Now Playing (the album
art; opens the lyrics), Key & BPM (sends the key to Logic), Lyrics Full Screen,
Switch Source, Reload Lyrics.

**Dials, with the touch strip:** Key (turn to transpose, press to reset, touch
to send to Logic), Tempo (±1 BPM; tap ×2, hold ÷2), Lyric Sync (±50 ms; touch
reloads the lyrics), Volume (±2, press mutes), Seek (±5 s, with the album art;
tap next, hold previous), Lyric Size (±2 pt).

**How it's built.** A native Swift executable, not Node: Elgato supports native
plug-ins (their own examples include one), and it builds with the same
toolchain as the app — no Node on this Mac to build a TypeScript plug-in with.
It registers over Stream Deck's WebSocket, polls Studio One twice a second while
anything is on screen, and sends a title, image or touch-strip update only when
it differs from what that key or dial last showed.

**Studio One's side** is a control port (`ControlServer.swift`): always on,
bound to 127.0.0.1, answering only requests that carry a token. The token is
there because any web page in a browser on the same Mac can send requests to
127.0.0.1; a custom header can't be attached cross-site without a permission
check this server never grants. Port and token are in
`~/Library/Application Support/Studio One/control.json`, readable only by the
owner, which is where the plug-in finds them.

Spotify gained a real volume (read and set through its scripting) so the volume
dial works on both sources.

**Tested:**
- The control port, live: 401 without the token and with a wrong one; refused
  on the network address; every reversible command round-tripped and undone.
- The plug-in, through a stand-in for the Stream Deck app. It launches the plug-in
  exactly as Stream Deck does, puts a full Stream Deck+ of actions on screen,
  turns and presses the dials, and records everything drawn, all against the
  running app: registration; a first draw of all ten; each dial's change shown
  at once and then undone; the warning triangle when a key can't be sent; a
  redraw after paging away and back (which found and fixed a bug where it would
  have stayed blank); no messages at all in three idle seconds; and a clean exit
  when Stream Deck goes away.
- The installer: the .sdPlugin at the archive's root, the binary universal,
  signed and executable, all 31 images present at 1× and 2×.

**Not tested:** the Stream Deck app itself, which isn't on this Mac; nor
play/pause, skip, seek, source switching or the lyrics window — music was
playing on this Mac at the time.

## Keys now get past Logic's Pickup mode

From the rig: pressing Send for Learn › Root makes Waves Tune run through every
key — so the port, the channel, Logic's assignment and Waves' Root all work —
while a song change moves nothing. The two sends differ in one way. Learn sweeps
0 → 127 and then lands on the key; a song change sent the key alone, one jump.

Logic's controller assignments have a Pickup mode, in which a controller is
ignored until it "reaches" the parameter's current value. A sweep passes
through every value and always reaches it; a lone jump almost never does. That
is the symptom exactly.

So every key change now goes out the way Learn sends it: 0, 21, 42 … 127, then
the value, 40 ms apart — about a third of a second, at the top of a song. Each
send cancels whatever is left of the previous one, so skipping tracks quickly
can't leave a late value from the song before. Verified on the wire: a skip 60
ms into a sweep stops the old one after two steps and ends on the new key, on
both mics' channels. "Sweep before each key change" in Settings › Logic turns it
off, for a setup where Pickup mode is off anyway.

Not verified against Logic itself: the evidence is the rig's behaviour and
Apple's description of Pickup mode, not a look at the assignment's setting.

## "Last sent", so a silent Logic can be diagnosed

Reported: after learning both mics, nothing reaches Waves Tune. That has three
possible causes, on a Mac this was not built on, and nothing distinguished them:
Studio One not sending (a song with no key used to be skipped silently);
sending, but Logic's assignment bound to a different control; or Logic
delivering it and Waves ignoring it.

Settings › Logic now shows what last left the app — "A♯ minor (song) → CC 20 =
15 on channels 1–2, one per mic", or "No key for this song, so no key was sent"
— and each is also written to the diagnostics log. **Send this song's key**
pushes the current song's key immediately, rather than waiting for the next
track, which is also the moment a freshly learned assignment would first move.

## Two mics, and the real key in Waves Tune

Two problems reported from the rig: one controller would not drive both mics'
Waves Tunes at once, and the key arriving in Waves Tune was not the song's.

**One channel per mic.** Settings › Logic › "Mics with a tuner" (1–4). Every key
is sent once per mic, Mic 1 on MIDI channel 1, Mic 2 on channel 2, and Send for
Learn has a mic picker so each plug-in learns its own channel. Logic can drive
several parameters from one assignment, but it did not hold in practice on the
rig; separate channels make it unnecessary. Tempo stays on channel 1. The setup
note no longer suggests the shared assignment.

**Read the plug-in instead of assuming its menus.** "Read Waves Tune Real-Time on
this Mac" loads the installed plug-in out of process — a plug-in that crashes
on load takes only the helper with it — finds its Root and Scale controls, and
measures which controller value selects each root and each of Major and Minor.
Two layouts could be reasoned about only from the plug-in itself: a root menu
listing C♯ and D♭ as separate entries (17 long), where twelve equal steps pick
the wrong key for most notes; and a scale menu of forty-odd entries, where
Minor's position is unknown. Menus with named values are read directly;
continuous controls are swept across their range and cut wherever the
displayed text changes, which is exactly how the plug-in reads what Logic
sends. The full parameter list goes to the diagnostics log.

**With a reading, keys go out as they are** — D minor as D Minor, not F Major.
The relative-major fallback stays only until a plug-in has been read, because
before that the scale menu's layout is unknown and the relative major is the one
thing that is certain to give the right notes. Topline and Auto-Tune Access can
be read the same way; Logic's Pitch Correction exists only inside Logic, and
MetaTune's key is twelve switches rather than a menu.

**Tested:** against built audio-unit parameters for the layouts that could be on
the rig — a 17-entry root menu with sharps and flats, a 12-entry menu numbered
from 1, a 45-entry scale menu with Harmonic, Melodic and Pentatonic minors
around the plain ones, Topline-style names, and continuous controls that only
name their values. Every root lands on its own entry whether the value is
rounded or truncated, and Major and Minor are found among the look-alikes.
Against a live unit — Apple's AUNBandEQ, loaded out of process in 0.17 s — all
11 entries of its Type menu were selected correctly, including writing each
value into the running unit and reading it back. On the wire, with two mics:
D minor before a reading goes out as F on channels 1 and 2; after one, as the
read D and Minor values on both; Learn for Mic 2 sweeps channel 2 only.

**Not tested:** reading Waves Tune itself, which is only on the rig.

**Also:** a Spotify playlist with an empty name showed as a blank row in the
sidebar; it now reads "Untitled". Seen once the library loaded after sign-in.

## What the karaoke Logic project showed about the pitch plug-ins

Read from `Kareoke.logicx` (Logic Pro 12.3.1): the mixer image Logic saves in
the bundle, and the nine plug-in states embedded in `ProjectData`.

- **The mics run Waves Tune Real-Time (s)** — AU `aumf`/`LVLS`/`ksWV`,
  version 13.0.0.129 — on Mic RED and Mic Cyan, both set to E♭ Major. A third
  instance sits at A, Chromatic. Waves CLA Vocals (`CVOS`) is on an aux.
- **Waves keeps Root and Scale in a plug-in-specific XML object**, not in its
  plain parameter list: `<PluginSpecific TagName="Scale">…<Root>3</Root>`. The
  raw root never appears among its 88 parameters. Two of them do move with it,
  though, if counted from 1: #7 is 4 on the E♭ instances (C = 1) and #5 goes
  1 → 2 as the scale goes Chromatic → Major. The A instance shows #7 = 1, but
  it is on Chromatic, where Root does not apply. Consistent with Root and Scale
  being automatable, not proof of it. Either way the encoding holds: a
  12-position menu selects the same key whether it counts from 0 or from 1.
- **Topline is two plug-ins.** `UI14` is Topline Vocal Suite, whose tuner
  exposes `tune_key` (0 = C; saved at 5, F) and `tune_scale` as real
  parameters. `UI13` is Topline Key Finder, UA's own key detector, on the Beat,
  HDMI and an aux.
- The AU `data` blocks of the UADx plug-ins do not match their saved controls
  (Topline's key is 5, its stored position 0.0) — stale defaults, so the step
  count of Topline's scale menu could not be read from them.

Changed as a result: every setup note now says how to put one controller on
several plug-ins — leave Learn Mode on and touch the same control in the next
one, which Logic supports — since the Waves setup needs both mics.

## Spotify: your library, the queue, and search that plays

Spotify's side of the browser was a dead end: "No library to browse". That was
true of the desktop app's scripting, which exposes the current track and the
transport and nothing else. The library is in Spotify's Web API instead, on
behalf of a signed-in user — so there is now a **Sign in to Spotify**, on the
empty Spotify screen and in Settings › Accounts.

**What it shows:** Liked Songs (newest 500) and every playlist in your Spotify
sidebar, with covers; Spotify's queue in the now-playing column; and search
across all of Spotify. Search used to show Apple Music results on the Spotify
side, whose Play opened the Music app — it now searches Spotify, and a result
plays straight away. Search needs no sign-in, only the client ID and secret it
always used.

**Playback stays with the desktop app,** by URI, so none of it needs Premium.
Tracks from a playlist are started *in that playlist's context*, so the next
song follows the playlist. Checked against the real app: restarted at a
playlist's first track in context, the next track was the playlist's second;
the same restart without a context jumped to an unrelated song.

**Sign-in** is Authorization Code with PKCE, the flow Spotify asks desktop apps
to use. The login happens on Spotify's page in the browser, so Studio One never
sees a password; PKCE needs no secret; the refresh token goes in the login
keychain beside the client ID, and Sign out deletes it. The redirect lands on a
one-shot listener bound to 127.0.0.1:8725 — Spotify stopped accepting
`localhost` in November 2025 but still accepts the loopback IP. That address
has to be added once as a Redirect URI in the Spotify developer dashboard.

**Spotify's 2026 rules, which shape what can be shown:**
- Development-mode apps need the app *owner* on Premium, or Spotify switches the
  app off entirely — search included.
- A playlist's tracks are only returned for playlists you own or collaborate
  on. Followed playlists still appear in the list, and say why they won't open.
- `GET /playlists/{id}/tracks` became `/items`, and each entry's `track` became
  `item`. Both shapes are read.
- Search is capped at 10 results.

**Tested:** the PKCE challenge against RFC 7636's own example (my first attempt
used a misremembered copy of the example and failed; the RFC's text matches);
the loopback listener with real HTTP requests — a stray `/favicon.ico` gets a
404 and the wait continues, the callback page is served, the query is handed
back, a busy port is reported as such; parsing of both response shapes,
dropping local files, podcast episodes and nulls. The new Spotify screen was
looked at in the app.

**Not tested:** signing in and loading a real library — that needs your
Spotify account and the redirect URI in your dashboard — and in-app search,
which stopped at the keychain prompt a new build raises.

**Also:** the request line now asks the controller whether it can take
requests, instead of whether it can browse. They were the same question until
Spotify could browse; the request line still needs Apple Music, because it adds
to and reorders a Music playlist.

## Choose the pitch plug-in the key is sent to

Settings › Logic › **Pitch plug-in**: Topline (what was there before, still the
default), Logic Pitch Correction, Antares Auto-Tune Access, Waves Tune Real-Time,
Slate Digital MetaTune.

**Why one layout could not serve them all.** They do not express a key the same
way, and there are three different answers among five choices:

- *Root plus scale menus* — Logic, Auto-Tune, Waves. The scale menus are the
  problem. Auto-Tune's has at least Major, Minor and Chromatic; Waves' manual
  says "many, many" scales, in an order it never gives. The old major/minor
  switch sent 127 for minor, which on a menu of three or more lands on the last
  entry, not on Minor.
- *Twelve note switches* — MetaTune has no key or scale parameter at all. Its key
  menu only switches its twelve notes on and off, and those are what a host can
  automate; Slate's own instructions for automating MetaTune's key are to record
  the note lanes. So it gets twelve controllers, CC 102 (C) to CC 113 (B), 127
  for a note in the key and 0 for one outside it, with a toggle in case the
  switches turn out to mean "off" at 127.
- *Root plus a two-way switch* — Topline, unchanged.

**The scale menus are never touched.** For Logic, Auto-Tune and Waves the plug-in
is set to Major once and a minor key is sent as its relative major. D minor and F
major are the same seven notes, and a correction grid is only the set of notes it
allows, so the tuning is identical — checked for all twelve minor keys. The one
visible difference is that the plug-in reads "F Major" while D minor plays. This
matters most for Logic's own Pitch Correction, which no other app can load, so
its menu order could not be read from anywhere.

**A bug in the key value itself, for every plug-in.** The root was sent as
`index × 127 / 11`. That is right if the receiving end rounds to the nearest
menu entry and wrong if it truncates: D, E, F♯, G♯ and A♯ each landed one note
flat. Hosts and plug-ins use at least four rules between them — round,
truncate, and two ways of dividing the range into equal bins. The value is now
the middle of the ones all four agree on, which exists for every position of any
menu up to thirteen long; tested for every position of every menu from 2 to 13.

**Setup inside Settings:** a short instruction for the chosen plug-in, Send for
Learn buttons that match it (Root, or twelve note buttons for MetaTune), and a
**Check it** row that sends any key on demand and says what the plug-in should
then read.

**Verified on the wire, not only in tests.** A listener attached to the
"Spot-a-oke" port while the real `MIDIBridge` published D minor at 120 BPM under
each choice: Topline CC 20 = 26 and CC 21 = 127; Logic, Auto-Tune and Waves
CC 20 = 61 (F) with no CC 21; MetaTune C D E F G A A♯ on and the rest off;
inverted, exactly the other five. The settings panel itself was not looked at —
opening Settings on a fresh build raises the keychain prompt, which needs a
person to answer.

**Not verified against the plug-ins.** None of them, nor Logic, is installed on
the Mac this was built on.

## The lyrics display, live, in the controls window

KaraFun keeps a running preview of the stage at the top of its control window;
this does the same, in place of the album art in the now-playing column. Clicking
it opens the real window — the thumbnail is where you notice the lyrics have
drifted, so it should be one click from where you fix that.

**It is the same view, not a second one.** `LyricsWindow` held the stage inline:
the connection states, the lyric states, the sweep, the countdown. That is now
`LyricsPane`, which both windows render. A reimplementation for the thumbnail
would have been a second thing to keep in step, and a preview that can disagree
with what the room sees is worse than no preview.

**Scaled, not laid out small.** The stage's type sizes are absolute points, so
laying it out in 300 points of width wraps every line and re-centres the sweep —
a tidy picture of something the room will never see. It renders at 1024x576 and
scales.

That took one real mistake to get right. `scaleEffect` is a geometry effect: it
changes what is drawn and never the size the view lays out at. Anchored
top-leading with a smaller frame below it, the drawn image and its layout box
stop sharing a centre and the whole preview is clipped away — it shipped to the
first build as an empty rectangle. Centre-anchored, the image and its box share
a centre and the frame lands on it exactly.

**What it costs.** Measured over nine one-second samples per configuration, one
track playing:

| | preview off | preview on |
| --- | --- | --- |
| controls window only | 22.2% | 29.6% |
| controls and lyrics both visible | 32.7% | 39.7-41.0% |
| controls behind the lyrics window | — | no measurable cost |

So about seven points of CPU, and none of it when the controls window is covered
— macOS throttles an occluded window's redraws, which is the full-screen-on-a-TV
case. The preview is capped at 30fps rather than following the display; this is
the one place `FrameRate` is allowed below its 60fps floor, because a thumbnail
is not the performance.

Drawing the backdrop separately at thumbnail size was tried, on the theory that
scaling meant computing a full-size blur and discarding most of it. **It saved
nothing measurable** — the difference sat inside the run-to-run noise — and it
made the preview less honest, since the particles then came out at their
absolute size and so proportionally much larger than the room sees. Reverted.

Settings › Display › "Show the lyrics display in the controls window" turns it
off and puts the album art back. On by default.

## Catalogue results now start on their own

"It opens up Apple Music but doesn't start playing it."

Music will not play a catalogue track from an Apple Event. That was already
recorded here, but only for one route; this time every route in its scripting
dictionary was tried, and all of them fail:

| Attempt | Result |
| --- | --- |
| `open location` then `play` | paused on a placeholder named after the album id |
| `playpause`, `play current track` | same placeholder, still paused |
| `download` that placeholder | error -4, unhandled |
| `duplicate` it into the library | cannot copy it |
| `search`/`tracks of source "iTunes Store"` | zero, always |
| LaunchServices deep link, then `play` | resumes some unrelated song |

Music will not even produce the placeholder consistently — the same script made
a URL track one minute and none the next. Nothing here is buildable. The routes
around it are no better: MusicKit's catalogue requests need a Team ID with a
MusicKit service attached, which an ad-hoc signed build cannot hold, and the
streams are FairPlay, so nothing outside Music can decode one.

What is left is the plus button in Music, and it is one click. So the row's
button is now **Play**: it opens the song in Music and watches the library, and
the moment the song lands it starts here. The row shows "Tap + in Music" with a
cancel while it waits, for up to two minutes, polling every 1.5s — Music posts
no notification when a track is added.

This is also the better outcome. A stream could not be queued, reordered,
requested or lyric-synced; a library track is all four.

**Matching what was added to what was asked for.** The store's metadata and
Music's copy are rarely identical, so the library is searched on the title with
brackets stripped and the candidate accepted on three counts: bare title equal,
one artist word shared, running time within 5s. Measured against this library,
store-to-library duration drift on a true pair is 0.00-0.02s, so 5s is loose
enough to be safe and tight enough to reject a different cut — it correctly
turned down a 203s radio edit offered against a 362s remix. Searching on the
full store title instead of the stripped one loses real matches: the store's
"Monsters (feat. Demi Lovato & blackbear)" finds nothing against a library
holding "Monsters (feat. blackbear)". Eight of eight owned songs matched, four
of four unowned correctly waited.

Verified end to end in the app: pressing Play on the store's "Monsters (feat.
Demi Lovato & blackbear)" started the library's "Monsters (feat. blackbear)"
within one poll.

## A dead track reference could zero the library half of a search

Found while testing the above, and the more serious bug of the two.

`searchLibrary` read each result's properties in a bare loop. Music's search
index can return a specifier for a track that no longer exists — deleting a URL
track leaves one behind until Music restarts — and reading *any* property of one
fails -1700. That error took down the whole script, `searchLibrary` threw, and
the caller's `try?` turned it into an empty array. A full library, reported as no
results, silently.

Each row is now read inside its own `try`, and the 25-row cap counts rows that
survived rather than rows attempted. Same query, before: script throws, zero
rows. After: 25 rows.

Three of these placeholders were in the library — two left by testing on Aug 31,
one from tonight — and they have been deleted.

## Search: the Apple Music results were off the bottom of the list

Reported as "the search is not working". It was working. Every part of it was
working, which is why this took measuring rather than reading.

The library search returns up to 25 hits and they are drawn first, at about 34
points a row. That is roughly three screens. The "APPLE MUSIC" heading and every
catalogue result sat below all of it, so a search looked exactly like the old
behaviour it was meant to replace: library only, catalogue never consulted.

What was checked before changing anything, in order: the iTunes endpoint from
this machine (200, 24 results); the AppleScript library search (0.72s, correct
hits); the exact fetch-and-parse code compiled standalone (24 of 24); and then
the same code inside the signed app through a launch probe (24 of 24). A log
line in `LibraryModel.search` settled it —

    search "Juice Wrld": library 25, catalogue 24 -> 24 after dedupe

— 24 catalogue hits in the model while the window showed none. Scrolling to the
bottom found them, rendered correctly, artwork and all.

**Fix:** the library section now shows its first six hits with a "Show all N in
your library" expander, so the Apple Music heading lands above the fold. The
expander resets whenever the query changes.

Also kept: one log line per search, and a reason line when a catalogue lookup
fails (network error, HTTP status, unreadable body). This failure was invisible
in the log, which is why it needed a probe build to find.

## Lyrics: the sweep was running ahead

Two changes were made here. One was right, one was wrong, and the wrong one
shipped first and made things worse.

**Reverted: asides no longer treated as free.**

The theory was that a bracketed backing vocal is layered *under* the lead rather
than sung before it, so it should cost the lead no time. The song it was tested
against disproves it. Its ad-lib appears alone on its own lines, where the file
shows it occupying 0.245-0.402s per syllable — real time. Counting it gives the
mixed lines a consistent 0.21-0.28s per syllable; treating it as free implies
the singer drawling "bright lights" across a full second, and starts the lead up
to 1.6s before it is actually sung.

Measured over the whole track, that change took lines whose sweep ends more than
0.4s early from 19 to 30. It was a regression, and it is out.

**Kept: the pace cap raised from 0.33s to 0.50s per syllable.**

Independently justified. Across 8,192 back-to-back lines in the local lyric
cache, 27% were sung slower than 0.33s per syllable, so their sweep was cut
short by 0.85s on average and sat ahead of the singer. At 0.50s that falls to
8%. Only 190 of those 8,192 lines are followed by a real gap, which is the only
case the cap exists for.

Over the test track, the four combinations end the sweep more than 0.4s early
on: 19 lines as it originally shipped, 30 with free asides, 10 with free asides
and the higher cap, and 5 as it now stands. Of those 5, four are short phrases
finishing before a breath and the fifth precedes a 16-second instrumental break.

## Credentials masked, and lyric matches recorded

**Changed**

- Client ID, client secret and the GetSongBPM key are all masked, with a "Show
  the keys" toggle. Only the secret was hidden before, so opening Settings on a
  shared screen exposed the other two.

**Added**

- The chosen lyric record's runtime gap is logged on every fetch, and a gap of
  more than four seconds is called out as a warning. `bestSearchMatch` picks the
  closest candidate by duration, but the comment claimed a tolerance the code
  never had: with no good match it still took the nearest, however far off. A
  live take or an extended mix drifts further out as the song goes on, which is
  indistinguishable from the app losing sync.

**On the sync itself — what was measured and cleared**

- The clock: instrumented to log any deviation over 0.15s from what Music
  reports. Forty-five seconds of playback, zero deviations, zero snaps.
- Queue contention: the browser, cover art and request server share one
  AppleScript queue with the position snapshot, which looked like the obvious
  culprit. Twelve rounds of heavy browser work against a playing track produced
  no snapshot over 250 ms.
- Output latency: stable within a session, one value per launch.
- Music's reported position: smooth 66 ms steps, no quantisation.

The timing machinery measures clean, so the remaining suspect is the lyric data
for particular tracks — which is what the new logging is there to identify.

## Settings: a sidebar

The sheet had grown a section at a time until it was taller than a laptop
screen. Its five sections — Accounts, Key & tempo, Logic, Display, Diagnostics —
are now panes behind a sidebar, at a fixed 660×470 with the pane scrolling and
Cancel/Save pinned below it. Nothing was reworded; the existing blocks were
moved as they stood.

## Search: the whole Apple Music catalogue

Search had two problems. It only looked inside the library — Music's scripting
`search` searches a playlist, never the catalogue — and in the app it was
switched off entirely on Apple Music, because the button was gated on
`supportsPlayingByID`, which only Spotify has. The sidebar read "Search
unavailable" for the whole time Apple Music was the source.

**Added**

- `CatalogSearch` — the public iTunes Search API. No key, no account, the whole
  catalogue.
- A live search field in the sidebar, replacing the disabled button. Results
  come back in two lists: what's in the library, playable on click, and the
  catalogue beyond it.

**Removed**

- "Find a song" from the control bar. The sidebar field covers it, and the old
  one only ever worked on Spotify.

**The limit, which is Music's and not ours**

A catalogue track cannot be played from a script. `open location` on a
music.apple.com URL navigates to it and leaves a paused placeholder named after
the album id; a following `play` does nothing. Same for the `music://` and
`itmss://` forms — all three checked. The only scriptable sources Music reports
are "Library" and "iTunes Store". So catalogue results offer "Open in Music"
rather than a Play button that would quietly fail: one click there adds it, and
from then on it plays and can be requested like anything else.

## Controls window: colour from the artwork

The window was a flat dark grey whatever was playing. It now takes its colour
from the cover.

**Changed**

- `ArtworkBackdrop` replaces the flat tinted panel: the cover blurred as
  texture, three pools of colour drawn from the palette already extracted from
  it, and a scrim so contrast doesn't depend on which cover is playing.
- Panes are tinted with the app's own near-black rather than pure black, and the
  section headers, play button and selection take the accent.

Two attempts were wrong before this one, both visible only in a screenshot. A
blurred cover with a lighten blend over it went grey — blurred artwork averages
out to something pale, and adding colour on top of pale barely shifts the hue.
Scrimming with pure black then drained what was left. The colour has to come
from the palette, with the blur only as texture underneath.

**Cost: none.** Measured during playback at about 20% CPU either way, against
the same 20% with the old flat panel — `drawingGroup()` flattens the backdrop to
one texture, so it is rebuilt on a track change rather than under every scrubber
tick. That 20% is pre-existing and worth looking at separately.

## Guest page: join was broken

**Fixed**

- The Join button set `join.hidden = true`, but `#join` carries
  `display:flex` — an id rule outranks the user-agent style that `[hidden]`
  relies on, so nothing moved and the splash stayed over the whole page. The
  name was stored and the request view was ready underneath; it just could not
  be reached. `[hidden] { display:none !important }` now sits in the shared CSS,
  which also fixes the remote's "Back to detected" button, which had been
  permanently visible for the same reason.

  Worth recording how this got through: the first test asserted that
  `join.hidden` had become `true` and that the nickname had been stored. Both
  were true. Neither says anything about what is on screen, and a screenshot
  would have shown the splash still covering it.

**Changed**

- The join screen shows the app icon instead of a microphone emoji, served from
  the bundled `.icns` at `/api/icon` rather than embedded as base64.

## Key and tempo on Apple Music

Key and tempo had gone missing on almost every Apple Music track. Two causes,
both in the same three lines.

**Fixed**

- ReccoBeats was being asked about Apple Music tracks using an Apple Music
  persistent ID. The guard meant to skip it tested `cacheKey.hasPrefix("am:")`,
  but `trackID` splits the uri on ":" and keeps the last component — so the
  prefix has already been stripped by the time it is checked, the guard was
  never true, and every Apple Music track queried ReccoBeats with an identifier
  it cannot possibly know. A guaranteed miss, every time. It tests `uri` now.

**Added**

- A Spotify bridge. ReccoBeats is keyed by Spotify track ID, so the same
  recording is looked up through the Spotify search the app already uses, and
  ReccoBeats asked with that ID. Without it Apple Music ran on GetSongBPM alone,
  which is why it looked like the switch to Apple Music broke the feature.

  Guarded three ways, because a wrong match publishes someone else's key to
  Logic with nothing to show anything is amiss: the artist must correspond
  whole-word, running times must be within four seconds, and titles must share
  at least 60% of their words. A near-miss returns nothing rather than a guess.
  Confirmed matching "Knife Talk (feat. 21 Savage & Project Pat)" to Spotify's
  "Knife Talk (with 21 Savage ft. Project Pat)", and a QUIX remix to its own
  remix entry, while rejecting tracks it could not place.

- `SpotifyAPI.warm()`, called detached at launch, so the first lookup of a
  session does not wait on the credential read.

Measured on tracks that previously returned nothing from any source: Broken —
Lund now C/134, Swan Dive — convolk G♯/141.97, Creep On Me (QUIX Remix) —
GASHI G/130.09, Knife Talk — Drake Fm/145.89. Genuinely obscure tracks still
miss, because neither source has them — that is coverage, not a bug.

**Not a bug, worth knowing**

The first lookup after launching a *newly built* binary takes about 50 seconds;
relaunching the same binary takes 0.7. The network is not involved — Spotify's
endpoints answer in 0.1s. It is the keychain re-evaluating its ACL because an
ad-hoc signature changes the app's identity on every rebuild. The self-signed
certificate described under "Signing" removes it.

## Remote and guest pages, restyled

Both pages rebuilt to the layout in the reference: a coloured control deck over
a dark list, and a nickname gate before a guest can request anything.

**Guest**

- A join screen — session code, nickname field with a live counter and a Join
  button that stays disabled until something is typed. The name is remembered
  per phone, scoped to the session code, so nobody retypes it every song, and
  there is a Change control to correct it.
- Requests now carry who asked. The host's sheet lists them as "Name: Song".

**Remote**

- Control deck: artwork, title, artist, volume, Key and Tempo steppers,
  transport and scrubber. Search and the queue sit in the dark half below.
- **Volume is real** — `sound volume` is the one audio control Apple Music
  actually exposes.
- **The two stem sliders are not possible.** Backing Vocals and Lead Vocal in
  the reference are stem faders; Apple Music hands over a finished stereo mix
  with nothing to separate. Volume takes their place rather than a fader that
  does nothing.
- **Key and Tempo correct, they do not transpose.** They write the same
  `manualKey` / `manualTempo` overrides the control bar sets, so they persist
  per track and republish to Logic. The audio itself cannot be shifted — it is
  a finished mix from Apple Music.

**Fixed while testing**

- The steppers did nothing on a track with no analysis, which is exactly when a
  manual value is wanted. The first press now seeds C and 120 BPM.
- The two steppers overflowed a 375pt phone and cut off the Tempo "+". Sized to
  fit rather than left to wrap.

## Remote: search, key/tempo, reorderable queue

**Changed**

- Search is a bar at the top of the page rather than a tab, so it's reachable
  without leaving the transport.
- Key and tempo are always on screen, dimmed to "KEY —" / "— BPM" when nothing
  is known. They were being hidden entirely when a track had no analysis, which
  reads as a missing feature rather than as missing data. The values already
  included the manual overrides and the ×2/÷2 multiplier — `publishedAnalysis`
  merges those — so what shows is what's actually being sent to Logic.

**Added**

- Up and down handles on each queue row. Only when the queue is the requests
  playlist: anything else is one of the user's own playlists, and rearranging it
  from a phone would quietly rewrite their library.

Two things had to be worked around, both found by testing rather than assumed:

- Music cannot move a track within a playlist. `move` takes a playlist, not a
  track, so a reorder is a rebuild — and only of the tail from the first
  affected position.
- Up Next is snapshotted when playback starts and ignores playlist edits
  completely. Reordering mid-play and calling `next track` still followed the
  old order. So the queue is re-seated after every reorder, landing back on the
  current track at the position it had reached: about half a second of stutter,
  in exchange for the change actually taking effect.

Two bugs in the first cut, caught before shipping: queue offsets were resolved
one position short, because the queue on screen starts at the playing track
rather than after it; and the rebuild held track references in an AppleScript
list, which Music rejects with "Unknown object type". It works on plain integer
indices now, which stay valid because duplicating only ever appends.

## Phone remote

Apple Events cannot reach iOS, and `MediaRemote` — the private API that reads
system-wide now playing — returns nothing without an entitlement: verified with
Music actively playing, symbols present, callback firing, payload empty. So the
Mac cannot follow the phone. The remote runs the other way instead.

**Added**

- A second page on the request server: artwork, title, key and tempo, a working
  scrubber, transport, live queue, and search that can play or queue.
- A second token. The guest code is shown to a room; the remote code can skip
  and seek, so it gets its own door. One token for both would hand the room the
  transport.
- Cover art over HTTP, shrunk to 600px — Music hands over about 570 KB, which is
  a lot to push over party Wi-Fi for something rendered small.

**Fixed a real bug this uncovered**

Music will do one or the other, not both: `play user playlist` builds an Up Next
queue but always starts at track 1, while `play track N of user playlist` starts
where you asked and leaves the queue empty — so `next track` afterwards does
nothing at all. Confirmed directly in `osascript`, so it is Music's behaviour
rather than the app's. Clicking a track in the browser had been leaving playback
unable to skip.

Now a track near the top of a playlist is reached by playing the playlist and
skipping to it, with the repeat running inside Music rather than as one Apple
Event per skip — 29 skips take 0.89s. Past 40 the track is started on its own,
because the cost is linear and waiting fifteen seconds to start track 500 is
worse than starting it without a queue.

## Request line

Apple Music has no shared-session feature, so this builds one: guests on the
same Wi-Fi scan a QR code, search the host's library from their phone, and their
picks land in a playlist Music owns.

**Added**

- `RequestServer.swift` — an `NWListener` HTTP server, no dependencies, serving
  a self-contained page plus a search and an add endpoint. Off unless started.
  The path carries a random token, so sharing the Wi-Fi is not enough to find
  it; a wrong token gets a bare 404.
- `SessionSheet.swift` — the QR code, the link to copy, what's been requested,
  and a button to start playing it.
- `queueRequest`, `searchLibrary`, `requests`, `playRequests` on the browser.

**Why it works this way**

Requests are `duplicate`d into a real playlist ("Studio One Requests") rather
than held in the app. Playing a playlist is what gives Music a `current
playlist`, which is what the Up Next panel already reads — so the request queue
shows up there with no extra machinery. Verified that `duplicate` succeeds on
Apple Music streaming tracks; `raw data of artwork` fails on those same tracks,
so it was worth checking rather than assuming.

Tracks travel as Music's `database ID`, not as a position in the search results,
which mean nothing by the time a guest taps Add. Looking one up again costs
0.20s across a 1,123-track library.

**The limit**

Guests can only request what the host already has. Music's `search` command
searches a playlist — there is no route to the Apple Music catalogue from the
scripting interface, so no amount of work on this side reaches it.

## Menu bar readout

**Added**

- `MenuBarReadout.swift` — key and tempo in the system menu bar ("E · 116"),
  with the half-time warning carried up as well, since without it a wrong tempo
  would look authoritative there. Its menu repeats the readout and offers ×2,
  ÷2, play/pause and the two windows. Toggleable in Settings, on by default.
- A `MenuBarExtra` scene rather than an `NSStatusItem`: it reads the model
  directly, so it follows `publishedAnalysis` — manual entries and the tempo
  multiplier included — with no extra plumbing.

**Changed**

- `bpmText` moved from `ControlBar` onto `TrackAnalysis`, so the bar and the
  menu bar format the number once rather than twice.

## Library browser

The controls window was a compact strip; it is now sidebar / catalogue /
now-playing, with the old control bar kept as a full-width footer so the key,
tempo and source controls stay where they were. `ControlsWindow` is still in
`ContentView.swift` — pointing the Controls scene back at it restores the strip.

**Added**

- `MusicLibrary.swift` — `MusicBrowser`, implemented over Apple Events.
- `LibraryModel.swift` — fetches on demand and caches; nothing is re-fetched on
  a redraw.
- `BrowserWindow.swift` — the three-pane UI.
- Cover art on Apple Music, which the app never had. `data of artwork 1` works
  where `raw data of artwork 1` fails: streaming tracks come back as
  "shared track" and refuse the latter. This fills the now-playing panel *and*
  the palette that tints the whole app and drives the background.

**Measured, and it shaped the code**

- Reading properties in a `repeat` loop took 2.71s for a 51-track playlist.
  Reading them in bulk — `name of every track of p` — took 0.18s, and stayed
  flat at 0.16s for 96 tracks. Every script here is written the bulk way.
- Enumerating playlists costs 0.48s for names, 2.40s if track counts are asked
  for as well. The counts are not shown.
- Up Next is sliced inside the script rather than in Swift: a library playlist
  here holds 1,123 tracks, and there is no reason to carry them all across the
  Apple Event boundary to show the next forty.

**Spotify**

Its scripting dictionary has no library, no playlists and no queue — the whole
surface is the current track, the transport and the volume. That is the
dictionary's shape, not a permission, so there is nothing to fall back to. The
catalogue says so and search stays the way in.

## Icon

**Added**

- A dark variant: black plate, gradient in the mark. `DockIcon.swift` applies it
  at runtime and follows the system theme, because macOS has no appearance-aware
  app icon — `.icns` holds one image, and the asset-catalog route forces Liquid
  Glass. Verified by compiling `is-glass: false` and the appearance
  specializations and having macOS render them: both are ignored.
- `Icon/icon-1024-dark.png` and `Icon/StudioOneDark.icns`, built by
  `Icon/build-icon.sh` alongside the light pair.

**Changed**

- Reverted the mark to the curved-beam form, where the innermost arc doubles as
  the note's beam. The straight-beam redraw and the reproportioning that
  followed were both backwards steps.
- The dark mark samples the gradient across its own bounds at -30°, not across
  the plate at -45°. The mark never reaches the plate's corners, so plate-sized
  sampling gave it only the middle of the ramp — pink to teal, with the red and
  green ends falling on empty space.

**Fixed**

- `DockIcon.start()` was called from `App.init()`, where `NSApp` is still nil,
  so it silently did nothing. Moved to `applicationDidFinishLaunching` by way of
  an `NSApplicationDelegateAdaptor`.

**Superseded**

- `Icon/make-icon.swift` — redrawn twice. First: Spotify's arcs shorten as they
  descend the way the real mark's do, and the note is engraved properly —
  straight slanted beam, parallel stems, tilted heads, uneven head heights.
  Previously the innermost arc doubled as the beam, which read as a third wave
  rather than as a note.

  Then the proportions. The arcs spanned 42°–138°, a sagitta-to-width ratio of
  0.20 — five times wider than tall, which is what made the mark look squashed.
  They now span 34°–146°, or 0.31. The mark is also drawn around the origin,
  measured with `CGPath.copy(strokingWithWidth:)` so stroke width counts, then
  scaled as a unit into a centred 650pt box: its margins are equal by
  construction, and the arcs and note hold their relative sizes if the box ever
  changes. The note hangs off the innermost arc's lowest point, so the clear
  space between them survives retuning the arcs.

**Added**

- `./build.sh --glass` — compiles `Icon/StudioOne.icon` with `actool` into
  `Assets.car` and sets `CFBundleIconName`, giving a real macOS 26 Liquid Glass
  icon rather than an imitation of one. Off by default.
- `Icon/build-icon.sh` — regenerates both icon forms from the one source.

Worth knowing: under Liquid Glass the system owns the background and renders
the artwork as glass. A white mark on the gradient plate comes out as a faint
ghost — verified by compiling and asking macOS to render it — so the glass
build puts the gradient in the mark and lets the system supply the ground.
The two icons therefore look different by necessity, not by choice.

## Renamed to Studio One

The app was **Karaoke**, then **Spot-a-oke**, and is now **Studio One**.

**Changed**

- `Info.plist` — `CFBundleName`, `CFBundleDisplayName`, `CFBundleExecutable`,
  `CFBundleIconFile`, and the Apple Events usage string.
- `build.sh` / `package.sh` — product name, icon path, and the expected signing
  identity (`STUDIOONE_SIGN_ID`, default `Studio One`).
- `Icon/make-icon.swift` — new mark. Spotify's stack of arcs, with the innermost
  arc doubling as the beam of Apple Music's note. The colour runs the long way
  round the wheel — pink, magenta, violet, blue, teal, green — because Spotify
  green and Apple Music red are complementary, and blending them directly goes
  through brown.
- User-facing strings in `ContentView.swift`, `SpotifyController.swift`,
  `Sheets.swift`, and the diagnostics log name.

**Deliberately unchanged**, because each one is an identifier that something
outside the app keys off:

- `CFBundleIdentifier` (`com.logan.SpotifyKaraoke`) — carries the Automation
  permission grants for Spotify and Apple Music, and every stored preference.
  Changing it means re-approving TCC and losing all settings.
- The keychain service (`SpotifyKaraoke.SpotifyAPI`) — holds the Spotify client
  ID and secret.
- `~/Library/Application Support/SpotifyKaraoke/Lyrics` — the lyric cache.
- The virtual MIDI source name (`Spot-a-oke`) — Logic files controller
  assignments under the port they were learned on.

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

- `MIDIBridge.swift` — publishes a virtual MIDI source named **Spot-a-oke** (kept under the old name so Logic assignments survive) and
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
