#!/usr/bin/env python3
"""Writes 'Studio One Remote.xcodeproj' from the files in this folder.

Like the Mac app's make-xcodeproj.py: no XcodeGen, only Xcode. Two targets —
the app, and the widget extension that draws its Live Activity — both signed
automatically with the free personal team. Re-run it after adding a file:

    python3 make-xcodeproj.py && open 'Studio One Remote.xcodeproj'
"""
import hashlib
import os
import pathlib

ROOT = pathlib.Path(__file__).parent.resolve()
NAME = "Studio One Remote"
APP = "StudioOneRemote"
WIDGETS = "StudioOneRemoteWidgets"
BUNDLE_ID = "com.logan.studioone.remote"
TEAM = "CLFMJM5GY3"
DEPLOYMENT = "26.0"
VERSION = "2.0"

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

def swift(folder):
    return sorted(str(p.relative_to(ROOT)) for p in (ROOT / folder).glob("*.swift"))

app_sources = swift("App")
widget_sources = swift("Widgets")
shared_sources = swift("Shared")
assets = "App/Assets.xcassets"
support = ["Config/Info.plist", "Config/Widgets-Info.plist", "make-xcodeproj.py"]

objects = []

def file_ref(path, kind=None):
    ident = uid("fileref", path)
    name = os.path.basename(path)
    guess = {".swift": "sourcecode.swift", ".plist": "text.plist.xml", ".xcassets": "folder.assetcatalog",
             ".py": "text.script.python"}
    kind = kind or guess.get(pathlib.Path(path).suffix, "text")
    objects.append("\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = %s; name = %s; path = %s; sourceTree = \"<group>\"; };"
                   % (ident, name, kind, quoted(name), quoted(path)))
    return ident

def build_file(path, phase, extra=""):
    ident = uid("buildfile", phase, path)
    objects.append("\t\t%s /* %s in %s */ = {isa = PBXBuildFile; fileRef = %s /* %s */;%s };"
                   % (ident, os.path.basename(path), phase, uid("fileref", path), os.path.basename(path), extra))
    return ident

def group(name, children, ident=None):
    ident = ident or uid("group", name)
    body = "".join("\t\t\t\t%s,\n" % c for c in children)
    objects.append("\t\t%s /* %s */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n%s\t\t\t);\n\t\t\tname = %s;\n\t\t\tsourceTree = \"<group>\";\n\t\t};"
                   % (ident, name, body, quoted(name)))
    return ident

for path in app_sources + widget_sources + shared_sources + support:
    file_ref(path)
file_ref(assets)

app_product = uid("product", APP)
objects.append('\t\t%s /* %s.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = %s.app; sourceTree = BUILT_PRODUCTS_DIR; };' % (app_product, APP, APP))
widget_product = uid("product", WIDGETS)
objects.append('\t\t%s /* %s.appex */ = {isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = %s.appex; sourceTree = BUILT_PRODUCTS_DIR; };' % (widget_product, WIDGETS, WIDGETS))

app_group = group("App", [uid("fileref", p) for p in app_sources] + [uid("fileref", assets)])
widget_group = group("Widgets", [uid("fileref", p) for p in widget_sources])
shared_group = group("Shared", [uid("fileref", p) for p in shared_sources])
support_group = group("Supporting Files", [uid("fileref", p) for p in support])
products_group = group("Products", [app_product, widget_product])
main_group = group("", [app_group, widget_group, shared_group, support_group, products_group], ident=uid("group", "main"))

def phase(isa, name, files, extra=""):
    ident = uid("phase", name)
    body = "".join("\t\t\t\t%s,\n" % f for f in files)
    objects.append("\t\t%s /* %s */ = {\n\t\t\tisa = %s;\n\t\t\tbuildActionMask = 2147483647;\n%s\t\t\tfiles = (\n%s\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};"
                   % (ident, name, isa, extra, body))
    return ident

app_sources_phase = phase("PBXSourcesBuildPhase", "App Sources",
                          [build_file(p, "App Sources") for p in app_sources + shared_sources])
app_frameworks = phase("PBXFrameworksBuildPhase", "App Frameworks", [])
app_resources = phase("PBXResourcesBuildPhase", "App Resources", [build_file(assets, "App Resources")])
embedded = build_file("product:" + WIDGETS, "Embed", " settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); };")
# The embedded product refers to the product file, not a source file.
objects[-1] = objects[-1].replace(uid("fileref", "product:" + WIDGETS), widget_product)
embed_phase = phase("PBXCopyFilesBuildPhase", "Embed Foundation Extensions", [embedded],
                    extra="\t\t\tdstPath = \"\";\n\t\t\tdstSubfolderSpec = 13;\n\t\t\tname = \"Embed Foundation Extensions\";\n")
widget_sources_phase = phase("PBXSourcesBuildPhase", "Widget Sources",
                             [build_file(p, "Widget Sources") for p in widget_sources + shared_sources])
widget_frameworks = phase("PBXFrameworksBuildPhase", "Widget Frameworks", [])
widget_resources = phase("PBXResourcesBuildPhase", "Widget Resources", [])

shared = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "CODE_SIGN_STYLE": "Automatic",
    "DEVELOPMENT_TEAM": TEAM,
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT,
    "SDKROOT": "iphoneos",
    "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
    "SUPPORTS_MACCATALYST": "NO",
    "SWIFT_VERSION": "5.0",
    "TARGETED_DEVICE_FAMILY": "1",
    "MARKETING_VERSION": VERSION,
    "CURRENT_PROJECT_VERSION": "1",
    "GENERATE_INFOPLIST_FILE": "NO",
}
debug = dict(shared, **{
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
})
release = dict(shared, **{
    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "SWIFT_OPTIMIZATION_LEVEL": "-O",
    "VALIDATE_PRODUCT": "YES",
})
app_settings = {
    "PRODUCT_NAME": APP,
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
    "INFOPLIST_FILE": "Config/Info.plist",
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    "ENABLE_PREVIEWS": "YES",
    "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/Frameworks"',
}
widget_settings = {
    "PRODUCT_NAME": WIDGETS,
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID + ".widgets",
    "INFOPLIST_FILE": "Config/Widgets-Info.plist",
    "APPLICATION_EXTENSION_API_ONLY": "YES",
    "SKIP_INSTALL": "YES",
    "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks"',
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
app_configs = config_list("app", dict(debug, **app_settings), dict(release, **app_settings))
widget_configs = config_list("widgets", dict(debug, **widget_settings), dict(release, **widget_settings))

project = uid("project", NAME)
widget_target = uid("target", WIDGETS)
app_target = uid("target", APP)

proxy = uid("proxy", WIDGETS)
objects.append("\t\t%s /* PBXContainerItemProxy */ = {\n\t\t\tisa = PBXContainerItemProxy;\n\t\t\tcontainerPortal = %s /* Project object */;\n\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = %s;\n\t\t\tremoteInfo = %s;\n\t\t};"
               % (proxy, project, widget_target, WIDGETS))
dependency = uid("dependency", WIDGETS)
objects.append("\t\t%s /* PBXTargetDependency */ = {\n\t\t\tisa = PBXTargetDependency;\n\t\t\ttarget = %s /* %s */;\n\t\t\ttargetProxy = %s /* PBXContainerItemProxy */;\n\t\t};"
               % (dependency, widget_target, WIDGETS, proxy))

def target(ident, name, configs, phases, product, kind, dependencies=()):
    phase_list = "".join("\t\t\t\t%s,\n" % p for p in phases)
    deps = "".join("\t\t\t\t%s,\n" % d for d in dependencies)
    objects.append("\t\t%s /* %s */ = {\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = %s;\n\t\t\tbuildPhases = (\n%s\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n%s\t\t\t);\n\t\t\tname = %s;\n\t\t\tproductName = %s;\n\t\t\tproductReference = %s;\n\t\t\tproductType = \"%s\";\n\t\t};"
                   % (ident, name, configs, phase_list, deps, quoted(name), quoted(name), product, kind))

target(widget_target, WIDGETS, widget_configs, [widget_sources_phase, widget_frameworks, widget_resources],
       widget_product, "com.apple.product-type.app-extension")
target(app_target, APP, app_configs, [app_sources_phase, app_frameworks, app_resources, embed_phase],
       app_product, "com.apple.product-type.application", [dependency])

objects.append("\t\t%s /* Project object */ = {\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\t\t\t\tLastSwiftUpdateCheck = 1600;\n\t\t\t\tLastUpgradeCheck = 1600;\n\t\t\t};\n\t\t\tbuildConfigurationList = %s;\n\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n\t\t\tmainGroup = %s;\n\t\t\tproductRefGroup = %s;\n\t\t\tprojectDirPath = \"\";\n\t\t\tprojectRoot = \"\";\n\t\t\ttargets = (\n\t\t\t\t%s,\n\t\t\t\t%s,\n\t\t\t);\n\t\t};"
               % (project, project_configs, main_group, products_group, app_target, widget_target))

out = ROOT / ("%s.xcodeproj" % NAME)
out.mkdir(exist_ok=True)
(out / "project.pbxproj").write_text(
    "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 56;\n\tobjects = {\n%s\n\t};\n\trootObject = %s /* Project object */;\n}\n"
    % ("\n".join(sorted(objects)), project))

schemes = out / "xcshareddata" / "xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
reference = f'''<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}"
               BuildableName="{APP}.app" BlueprintName="{APP}" ReferencedContainer="container:{NAME}.xcodeproj"/>'''
(schemes / ("%s.xcscheme" % NAME)).write_text(f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            {reference}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"/>
   <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO"
      ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
            {reference}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
            {reference}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration="Debug"/>
   <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
""")
print("wrote %s: %d app, %d widget, %d shared sources" % (out.name, len(app_sources), len(widget_sources), len(shared_sources)))
