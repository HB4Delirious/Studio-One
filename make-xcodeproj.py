#!/usr/bin/env python3
"""Writes 'Studio One.xcodeproj' from the files in this folder.

XcodeGen would do this from project.yml, but it isn't installed and installing
it means downloading a toolchain. This writes the project file directly, so the
only thing needed is Xcode itself. Re-run it after adding a Swift file:

    python3 make-xcodeproj.py && open 'Studio One.xcodeproj'

Every build setting mirrors build.sh, so a build from Xcode and a build from the
script produce the same app: ad-hoc signed, hardened runtime, Apple Events
entitlement, no sandbox, Swift 5 mode.
"""
import hashlib
import os
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).parent.resolve()
APP = "Studio One"
BUNDLE_ID = "com.logan.SpotifyKaraoke"
DEPLOYMENT = "14.0"
TOOL = "StudioOneDeck"

def signing_identity():
    """The certificate to sign with, and its team.

    A certificate — any certificate — keeps the keychain quiet: an ad-hoc
    signature identifies the app by a hash of itself, so every rebuild looks
    like a different app and "Always Allow" is forgotten. A certificate names
    the app and the certificate instead, which survives recompiling.
    """
    try:
        found = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"],
                               capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return "-", ""
    for pattern in [r'"(Studio One)"', r'"(Apple Development: [^"]*)"', r'"(Developer ID Application: [^"]*)"']:
        match = re.search(pattern, found)
        if not match:
            continue
        name = match.group(1)
        # The team is the certificate's OU, not the code in its name — those
        # look alike and are different things (that code identifies the
        # certificate itself, and Xcode rejects it as a team).
        team = ""
        try:
            pem = subprocess.run(["security", "find-certificate", "-c", name, "-p"],
                                 capture_output=True, text=True, timeout=10).stdout
            subject = subprocess.run(["openssl", "x509", "-noout", "-subject"],
                                     input=pem, capture_output=True, text=True, timeout=10).stdout
            found_ou = re.search(r"OU\s*=\s*([A-Z0-9]{10})", subject)
            team = found_ou.group(1) if found_ou else ""
        except Exception:
            pass
        return name, team
    return "-", ""

IDENTITY, TEAM = signing_identity()

# codesign takes the certificate's full name; Xcode wants the generic kind plus
# the team, and rejects the full name ("No certificate for team … matching …").
XCODE_IDENTITY = next((kind for kind in ("Apple Development", "Developer ID Application")
                       if IDENTITY.startswith(kind)), IDENTITY)

def uid(*parts):
    """A stable 24-hex id per object, so re-running doesn't churn the file."""
    return hashlib.md5("::".join(parts).encode()).hexdigest()[:24].upper()

def quoted(text):
    safe = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./")
    return text if text and all(c in safe for c in text) else '"%s"' % text.replace('\\', '\\\\').replace('"', '\\"')

def settings(pairs, indent):
    pad = "\t" * indent
    return "".join("%s%s = %s;\n" % (pad, key, quoted(value) if isinstance(value, str) else value)
                   for key, value in sorted(pairs.items()))

# ---------------------------------------------------------------- files

app_sources = sorted(p.name for p in ROOT.glob("*.swift"))
# Every file, not a list: naming only main.swift left midi.swift out of the
# Xcode target when it was added, and the plug-in no longer built there.
tool_sources = sorted(str(p.relative_to(ROOT)) for p in (ROOT / "StreamDeck/Sources").glob("*.swift"))
resources = [p for p in ["Icon/StudioOne.icns", "Icon/StudioOneDark.icns"] if (ROOT / p).exists()]
support = ["Info.plist", "Karaoke.entitlements", "project.yml", "README.md", "CHANGELOG.md",
           "build.sh", "package.sh", "StreamDeck/manifest.json", "StreamDeck/build.sh",
           "StreamDeck/make-images.swift"]
support = [p for p in support if (ROOT / p).exists()]

objects = []

def file_ref(path, kind=None):
    ident = uid("fileref", path)
    name = os.path.basename(path)
    guess = {".swift": "sourcecode.swift", ".plist": "text.plist.xml", ".entitlements": "text.plist.entitlements",
             ".icns": "image.icns", ".json": "text.json", ".sh": "text.script.sh",
             ".md": "net.daringfireball.markdown", ".yml": "text.yaml"}
    kind = kind or guess.get(pathlib.Path(path).suffix, "text")
    objects.append("\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = %s; name = %s; path = %s; sourceTree = \"<group>\"; };"
                   % (ident, name, kind, quoted(name), quoted(path)))
    return ident

def build_file(path, phase):
    ident = uid("buildfile", phase, path)
    objects.append("\t\t%s /* %s in %s */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
                   % (ident, os.path.basename(path), phase, uid("fileref", path), os.path.basename(path)))
    return ident

def group(name, children, ident=None, path=None):
    ident = ident or uid("group", name)
    body = "".join("\t\t\t\t%s,\n" % c for c in children)
    objects.append("\t\t%s /* %s */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n%s\t\t\t);\n%s\t\t\tsourceTree = \"<group>\";\n\t\t};"
                   % (ident, name, body,
                      "\t\t\tname = %s;\n" % quoted(name) + ("\t\t\tpath = %s;\n" % quoted(path) if path else "")))
    return ident

for path in app_sources + tool_sources + resources + support:
    file_ref(path)

app_product = uid("product", APP)
objects.append('\t\t%s /* %s.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "%s.app"; sourceTree = BUILT_PRODUCTS_DIR; };' % (app_product, APP, APP))
tool_product = uid("product", TOOL)
objects.append('\t\t%s /* %s */ = {isa = PBXFileReference; explicitFileType = "compiled.mach-o.executable"; includeInIndex = 0; path = %s; sourceTree = BUILT_PRODUCTS_DIR; };' % (tool_product, TOOL, TOOL))

source_group = group("App", [uid("fileref", p) for p in app_sources])
deck_group = group("Stream Deck", [uid("fileref", p) for p in tool_sources + [s for s in support if s.startswith("StreamDeck/")]])
resource_group = group("Resources", [uid("fileref", p) for p in resources])
support_group = group("Supporting Files",
                      [uid("fileref", p) for p in support if not p.startswith("StreamDeck/")])
products_group = group("Products", [app_product, tool_product])
main_group = group("", [source_group, deck_group, resource_group, support_group, products_group], ident=uid("group", "main"))

# ---------------------------------------------------------------- phases

def phase(isa, name, files, extra=""):
    ident = uid("phase", name)
    body = "".join("\t\t\t\t%s,\n" % f for f in files)
    objects.append("\t\t%s /* %s */ = {\n\t\t\tisa = %s;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n%s\t\t\t);\n%s\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};"
                   % (ident, name, isa, body, extra))
    return ident

app_sources_phase = phase("PBXSourcesBuildPhase", "App Sources", [build_file(p, "Sources") for p in app_sources])
app_frameworks = phase("PBXFrameworksBuildPhase", "App Frameworks", [])
app_resources = phase("PBXResourcesBuildPhase", "App Resources", [build_file(p, "Resources") for p in resources])
tool_sources_phase = phase("PBXSourcesBuildPhase", "Tool Sources", [build_file(p, "Sources") for p in tool_sources])
tool_frameworks = phase("PBXFrameworksBuildPhase", "Tool Frameworks", [])

# Builds and packages the Stream Deck plug-in into the app, exactly as build.sh
# does, so an Xcode build produces an app whose Install button has something to
# install. Skipped, not failed, when the folder isn't there.
script = r"""set -e
if [ -x "$SRCROOT/StreamDeck/build.sh" ]; then
  "$SRCROOT/StreamDeck/build.sh" > /dev/null
  cp "$SRCROOT/StreamDeck/build/com.logan.studioone.streamDeckPlugin" \
     "$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/Resources/"
else
  echo "warning: StreamDeck/build.sh not found — the app will have no plug-in to install"
fi
"""
script_phase = uid("phase", "Stream Deck plug-in")
objects.append("\t\t%s /* Stream Deck plug-in */ = {\n\t\t\tisa = PBXShellScriptBuildPhase;\n\t\t\talwaysOutOfDate = 1;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\tinputFileListPaths = (\n\t\t\t);\n\t\t\tinputPaths = (\n\t\t\t);\n\t\t\tname = \"Stream Deck plug-in\";\n\t\t\toutputFileListPaths = (\n\t\t\t);\n\t\t\toutputPaths = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t\tshellPath = /bin/sh;\n\t\t\tshellScript = %s;\n\t\t};" % (script_phase, quoted(script)))

# ---------------------------------------------------------------- settings

shared = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "COPY_PHASE_STRIP": "NO",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "MACOSX_DEPLOYMENT_TARGET": DEPLOYMENT,
    "SDKROOT": "macosx",
    # Swift 5, not 6: the app crosses actor boundaries in places Swift 6 rejects.
    "SWIFT_VERSION": "5.0",
    "SWIFT_STRICT_CONCURRENCY": "minimal",
    # The Stream Deck phase writes inside the project folder.
    "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
    "CODE_SIGN_STYLE": "Manual",
    # Whatever certificate this Mac has, like build.sh. Ad-hoc only if there is
    # none, in which case the keychain will ask again after every rebuild.
    "CODE_SIGN_IDENTITY": XCODE_IDENTITY,
    "DEVELOPMENT_TEAM": TEAM,
}
debug = dict(shared, **{
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
})
release = dict(shared, **{
    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "SWIFT_OPTIMIZATION_LEVEL": "-O",
})
app_target_settings = {
    "PRODUCT_NAME": APP,
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
    "INFOPLIST_FILE": "Info.plist",
    "GENERATE_INFOPLIST_FILE": "NO",
    "CODE_SIGN_ENTITLEMENTS": "Karaoke.entitlements",
    "ENABLE_HARDENED_RUNTIME": "YES",
    "ENABLE_APP_SANDBOX": "NO",
    "COMBINE_HIDPI_IMAGES": "YES",
    "MARKETING_VERSION": "1.0",
    "CURRENT_PROJECT_VERSION": "1",
    "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/../Frameworks"',
}
tool_target_settings = {
    "PRODUCT_NAME": TOOL,
    "PRODUCT_BUNDLE_IDENTIFIER": "com.logan.studioone.deck",
    "MACOSX_DEPLOYMENT_TARGET": "13.0",
    "ENABLE_HARDENED_RUNTIME": "NO",
    "SWIFT_VERSION": "5.0",
}

def config(name, values, label):
    ident = uid("config", label, name)
    objects.append("\t\t%s /* %s */ = {\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n%s\t\t\t};\n\t\t\tname = %s;\n\t\t};"
                   % (ident, name, settings(values, 4), name))
    return ident

def config_list(label, debug_values, release_values):
    ident = uid("configlist", label)
    d, r = config("Debug", debug_values, label), config("Release", release_values, label)
    objects.append("\t\t%s /* Build configuration list for %s */ = {\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t%s /* Debug */,\n\t\t\t\t%s /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t};"
                   % (ident, label, d, r))
    return ident

project_configs = config_list("project", debug, release)
app_configs = config_list("app", dict(debug, **app_target_settings), dict(release, **app_target_settings))
tool_configs = config_list("tool", dict(debug, **tool_target_settings), dict(release, **tool_target_settings))

# ---------------------------------------------------------------- targets

app_target = uid("target", APP)
objects.append("\t\t%s /* %s */ = {\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = %s;\n\t\t\tbuildPhases = (\n\t\t\t\t%s,\n\t\t\t\t%s,\n\t\t\t\t%s,\n\t\t\t\t%s,\n\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n\t\t\tname = %s;\n\t\t\tproductName = %s;\n\t\t\tproductReference = %s;\n\t\t\tproductType = \"com.apple.product-type.application\";\n\t\t};"
               % (app_target, APP, app_configs, app_sources_phase, app_frameworks, app_resources,
                  script_phase, quoted(APP), quoted(APP), app_product))
tool_target = uid("target", TOOL)
objects.append("\t\t%s /* %s */ = {\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = %s;\n\t\t\tbuildPhases = (\n\t\t\t\t%s,\n\t\t\t\t%s,\n\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n\t\t\tname = %s;\n\t\t\tproductName = %s;\n\t\t\tproductReference = %s;\n\t\t\tproductType = \"com.apple.product-type.tool\";\n\t\t};"
               % (tool_target, TOOL, tool_configs, tool_sources_phase, tool_frameworks,
                  quoted(TOOL), quoted(TOOL), tool_product))

project = uid("project", APP)
objects.append("\t\t%s /* Project object */ = {\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\t\t\t\tLastSwiftUpdateCheck = 1600;\n\t\t\t\tLastUpgradeCheck = 1600;\n\t\t\t};\n\t\t\tbuildConfigurationList = %s;\n\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n\t\t\tmainGroup = %s;\n\t\t\tproductRefGroup = %s;\n\t\t\tprojectDirPath = \"\";\n\t\t\tprojectRoot = \"\";\n\t\t\ttargets = (\n\t\t\t\t%s,\n\t\t\t\t%s,\n\t\t\t);\n\t\t};"
               % (project, project_configs, main_group, products_group, app_target, tool_target))

# ---------------------------------------------------------------- write

out = ROOT / ("%s.xcodeproj" % APP)
out.mkdir(exist_ok=True)
(out / "project.pbxproj").write_text(
    "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 56;\n\tobjects = {\n%s\n\t};\n\trootObject = %s /* Project object */;\n}\n"
    % ("\n".join(sorted(objects)), project))

schemes = out / "xcshareddata" / "xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
(schemes / ("%s.xcscheme" % APP)).write_text(f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}"
               BuildableName="{APP}.app" BlueprintName="{APP}" ReferencedContainer="container:{APP}.xcodeproj"/>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"/>
   <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO"
      ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}"
            BuildableName="{APP}.app" BlueprintName="{APP}" ReferencedContainer="container:{APP}.xcodeproj"/>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}"
            BuildableName="{APP}.app" BlueprintName="{APP}" ReferencedContainer="container:{APP}.xcodeproj"/>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration="Debug"/>
   <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
""")
print("wrote %s with %d app sources, %d resources; signing as %s"
      % (out.name, len(app_sources), len(resources), IDENTITY))
