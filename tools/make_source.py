#!/usr/bin/env python3
"""Writes the SideStore / AltStore source for one release of the iPhone app.

Usage: make_source.py <ipa> <version> <build> <download-url> <out.json>

The source lists one app, dev.nxpocketapple.app, at the release's version. SideStore reads it from the stable URL
https://github.com/Absenti/NXPocketApple/releases/latest/download/source.json, offers the update when the version is newer
than the installed one, and checks that the IPA asks for no entitlement the source does not declare.
"""
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import zipfile
from datetime import datetime, timezone

REPO = "https://github.com/Absenti/NXPocketApple"
ICON = "https://raw.githubusercontent.com/Absenti/NXPocketApple/main/app/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"


def app_facts(ipa):
    """The bundle ID, minimum iOS and entitlements the IPA carries."""
    with zipfile.ZipFile(ipa) as archive:
        names = [n for n in archive.namelist() if n.startswith("Payload/") and n.count("/") == 2 and n.endswith(".app/Info.plist")]
        if len(names) != 1:
            sys.exit(f"{ipa}: expected one Payload/<app>.app/Info.plist, found {names}")
        info = plistlib.loads(archive.read(names[0]))
        app_dir = names[0][: -len("Info.plist")]
        executable = app_dir + info["CFBundleExecutable"]
        with tempfile.TemporaryDirectory() as tmp:
            path = archive.extract(executable, tmp)
            out = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", path],
                                 capture_output=True, check=False).stdout
    entitlements = sorted(plistlib.loads(out).keys()) if out.strip() else []
    return info, entitlements


def main():
    if len(sys.argv) != 6:
        sys.exit(__doc__)
    ipa, version, build, url, out = sys.argv[1:]
    info, entitlements = app_facts(ipa)
    if info.get("CFBundleIdentifier") != "dev.nxpocketapple.app":
        sys.exit(f"the IPA's bundle ID is {info.get('CFBundleIdentifier')}, not dev.nxpocketapple.app")
    if info.get("CFBundleShortVersionString") != version:
        sys.exit(f"the IPA is version {info.get('CFBundleShortVersionString')}, the release is {version}")
    source = {
        "name": "NXPocketApple",
        "identifier": "dev.nxpocketapple.source",
        "subtitle": "Your own Switch games, built on your Mac, played on your iPhone.",
        "website": REPO,
        "sourceURL": f"{REPO}/releases/latest/download/source.json",
        "iconURL": ICON,
        "apps": [{
            "name": "NXPocketApple",
            "bundleIdentifier": "dev.nxpocketapple.app",
            "developerName": "NXPocketApple",
            "subtitle": "Plays the games the NXPocketApple launcher builds on your Mac.",
            "localizedDescription": "Imports the games the NXPocketApple launcher builds on your Mac from your own dumps, "
                                    "signs them on the iPhone and plays them. It ships no key, no firmware and no game.",
            "iconURL": ICON,
            "category": "games",
            "versions": [{
                "version": version,
                "buildVersion": build,
                "date": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "localizedDescription": f"NXPocketApple {version}. Release notes: {REPO}/releases/tag/v{version}",
                "downloadURL": url,
                "size": os.path.getsize(ipa),
                "minOSVersion": info.get("MinimumOSVersion", "26.0"),
            }],
            "appPermissions": {"entitlements": entitlements, "privacy": {}},
        }],
        "news": [],
    }
    with open(out, "w") as handle:
        json.dump(source, handle, indent=2)
        handle.write("\n")


if __name__ == "__main__":
    main()
