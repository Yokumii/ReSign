#!/usr/bin/env python3
"""Collect notices before signing the macOS bundle; retain source provenance."""
import json
import pathlib
import re
import shutil
import subprocess
import sys
import urllib.request

root = pathlib.Path(__file__).resolve().parent.parent
app = pathlib.Path(sys.argv[1]).resolve()
notices = app / "Contents/Resources/Licenses"
libraries = json.loads((notices / "bundled-libraries.json").read_text())


def copy_notices(source, destination):
    copied = 0
    for path in source.rglob("*"):
        relative = path.relative_to(source)
        if ".git" in relative.parts or not path.is_file():
            continue
        if not re.match(r"^(licen[cs]e|copying|notice)([._-]|$)", path.name, re.I):
            continue
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
        copied += 1
    if copied == 0:
        raise RuntimeError(f"No license notices found in {source}")


checkouts = root / ".build/checkouts"
pins = json.loads((root / "Package.resolved").read_text())["pins"]
checkout_paths = {path.name.lower(): path for path in checkouts.iterdir() if path.is_dir()}
for pin in pins:
    checkout = checkout_paths[pin["identity"]]
    revision = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
    if revision != pin["state"]["revision"]:
        raise RuntimeError(f"Resolved checkout differs from lockfile: {pin['identity']}")
    copy_notices(checkout, notices / "SwiftPackages" / pin["identity"])

formula_names = sorted({item["formula"] for item in libraries if "formula" in item})
formula_info = json.loads(subprocess.check_output(
    ["brew", "info", "--json=v2", *formula_names], text=True))["formulae"] if formula_names else []
for name in formula_names:
    source = pathlib.Path(next(item["cellar"] for item in libraries if item.get("formula") == name))
    copy_notices(source, notices / "Homebrew" / name)
(notices / "homebrew-formulae.json").write_text(json.dumps(formula_info, indent=2) + "\n")

binary_sources = json.loads((root / "scripts/binary-sources.json").read_text())
for source in binary_sources:
    manifest = (checkout_paths[source["package"].lower()] / "Package.swift").read_text()
    if source["binary_url"] not in manifest or source["binary_checksum"] not in manifest:
        raise RuntimeError(f"Update binary-sources.json for {source['name']}")
    destination = notices / "BinaryPackages" / source["name"]
    destination.mkdir(parents=True, exist_ok=True)
    repository_path = source["repository"].removeprefix("https://github.com/")
    for name in source["licenses"]:
        url = f"https://raw.githubusercontent.com/{repository_path}/{source['revision']}/{name}"
        with urllib.request.urlopen(url, timeout=60) as response:
            (destination / name).write_bytes(response.read())
(notices / "binary-sources.json").write_text(json.dumps(binary_sources, indent=2) + "\n")
