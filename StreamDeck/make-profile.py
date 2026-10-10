#!/usr/bin/env python3
"""Builds "Studio One.streamDeckProfile": a ready-made page for Stream Deck +.

Elgato's route is to lay a page out in the Stream Deck app and export it.
This writes the same thing directly, in the layout the app itself uses
(ProfilesV3: a UUID.sdProfile folder, a manifest naming its pages, one
manifest per page listing actions by "column,row"), read from real profiles.
It is shipped beside the plug-in rather than inside it, so a page the app
dislikes can never get in the way of installing the plug-in.

Usage: make-profile.py <output .streamDeckProfile path>
"""
import json, os, sys, uuid, zipfile

PLUGIN = {"Name": "Studio One", "UUID": "com.logan.studioone", "Version": "1.0.0.0"}
STATES = {"playpause": 2}          # actions with more than one state

def action(kind, name, settings=None):
    return {
        "ActionID": str(uuid.uuid4()),
        "LinkedTitle": True,
        "Name": name,
        "Plugin": PLUGIN,
        "Resources": None,
        "Settings": settings or {},
        "State": 0,
        "States": [{} for _ in range(STATES.get(kind, 1))],
        "UUID": f"com.logan.studioone.{kind}",
    }

def mixer(mic, part, offset, label):
    # The same settings the plug-in's own settings panel saves; see pi/control.html.
    first = 30 + (mic - 1) * 8
    return action("logic.mixer", "Logic Mic Dial", {
        "control": f"mic{mic}.{part}", "name": f"Mic {mic} · {label}",
        "cc": first + offset, "channel": 16,
        "muteCC": first + 7, "muteName": f"Mic {mic} · Mute"})

def mute(mic):
    cc = 30 + (mic - 1) * 8 + 7
    return action("logic.mute", "Logic Mic Mute", {
        "control": f"mic{mic}.mute", "name": f"Mic {mic} · Mute", "cc": cc, "channel": 16})

def keys():
    return {
        "0,0": action("playpause", "Play / Pause"),
        "1,0": action("previous", "Previous Track"),
        "2,0": action("next", "Next Track"),
        "3,0": action("keybpm", "Key & BPM"),
        "0,1": mute(1),
        "1,1": mute(2),
        "2,1": action("lyricsfull", "Lyrics Full Screen"),
        "3,1": action("nowplaying", "Now Playing"),
    }

pages = [
    ("Mics", {
        "0,0": mixer(1, "level", 0, "Level"),
        "1,0": mixer(1, "plugin1", 3, "Plug-in 1"),
        "2,0": mixer(2, "level", 0, "Level"),
        "3,0": mixer(2, "plugin1", 3, "Plug-in 1"),
    }),
    ("Song", {
        "0,0": action("dial.key", "Key"),
        "1,0": action("dial.tempo", "Tempo"),
        "2,0": action("dial.sync", "Lyric Sync"),
        "3,0": action("dial.volume", "Volume"),
    }),
]

out = sys.argv[1]
profile_id = str(uuid.uuid4()).upper()
root = f"{profile_id}.sdProfile"
page_ids = [str(uuid.uuid4()) for _ in pages]
default_id = str(uuid.uuid4())       # the blank template new pages start from

files = {}
files[f"{root}/manifest.json"] = {
    "Device": {"Model": "20GBD9901", "UUID": ""},     # Stream Deck +
    "Name": "Studio One",
    "Pages": {"Current": page_ids[0], "Default": default_id, "Pages": page_ids},
    "Version": "3.0",
}
for page_id, (name, dials) in zip(page_ids, pages):
    files[f"{root}/Profiles/{page_id.upper()}/manifest.json"] = {
        "Controllers": [
            {"Actions": keys(), "Type": "Keypad"},
            {"Actions": dials, "Type": "Encoder"},
        ],
        "Icon": "",
        "Name": name,
    }
files[f"{root}/Profiles/{default_id.upper()}/manifest.json"] = {
    "Controllers": [{"Actions": None, "Type": "Keypad"}, {"Actions": None, "Type": "Encoder"}],
    "Icon": "", "Name": "",
}

os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for path, content in files.items():
        z.writestr(path, json.dumps(content, indent=2))
print(f"wrote {out}: {len(pages)} pages")
