#!/usr/bin/env python3
"""Opdaterer sidestore/source.json (AltStore/SideStore-kildeformat) med en ny version.

Brug: make_source.py <version> <build> <ipa-sti> <download-url>
"""
import json, os, sys
from datetime import datetime, timezone

version, build, ipa, url = sys.argv[1:5]
path = os.path.join(os.path.dirname(__file__), "..", "sidestore", "source.json")
raw = "https://raw.githubusercontent.com/Thyxo/digital-change/main"
icon = f"{raw}/ios/KameraPlus/Assets.xcassets/AppIcon.appiconset/icon-1024.png"

try:
    with open(path) as f:
        old_versions = json.load(f)["apps"][0]["versions"]
except Exception:
    old_versions = []

new = {
    "version": version,
    "buildVersion": build,
    "date": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "localizedDescription": f"Build {build}",
    "downloadURL": url,
    "size": os.path.getsize(ipa),
    "minOSVersion": "17.0",
}
versions = [new] + [v for v in old_versions if v.get("version") != version][:4]

privacy = {
    "NSCameraUsageDescription": "Kameraet bruges til at tage billeder.",
    "NSPhotoLibraryAddUsageDescription": "Billeder kan gemmes i Fotos.",
}
source = {
    "name": "KameraPlus",
    "identifier": "dk.thyxo.kameraplus.source",
    "subtitle": "Kamera",
    "description": "KameraPlus-kilde – opdateres automatisk ved hver ny build.",
    "iconURL": icon,
    "website": "https://github.com/Thyxo/digital-change",
    "tintColor": "#FEF657",
    "apps": [{
        "name": "KameraPlus",
        "bundleIdentifier": "dk.thyxo.kameraplus",
        "developerName": "Thyxo",
        "subtitle": "Kamera",
        "localizedDescription": "Magi-rekvisit: et kamera, der ligner iPhones eget, med en skjult effekt (Digital Flap).",
        "iconURL": icon,
        "tintColor": "#FEF657",
        "category": "entertainment",
        "screenshots": [],
        "versions": versions,
        "appPermissions": {"entitlements": [], "privacy": privacy},
    }],
    "news": [],
}

os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    json.dump(source, f, ensure_ascii=False, indent=2)
    f.write("\n")
print(f"source.json -> {version} ({build}), {new['size']} bytes")
