#!/usr/bin/env python3
"""Create release assets from a clean tagged checkout and its built app."""
import datetime
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.parse
import urllib.request

root = pathlib.Path(__file__).resolve().parent.parent
os.chdir(root)
app = root / "dist/ReSign.app"
with (app / "Contents/Info.plist").open("rb") as source:
    info = plistlib.load(source)
version = info["CFBundleShortVersionString"]
tag = os.environ.get("RELEASE_TAG")
if not tag:
    raise SystemExit("RELEASE_TAG is required")
if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version) or tag != "v" + version:
    raise SystemExit("Release tag and app version must match")
if subprocess.check_output(["git", "status", "--porcelain"], text=True).strip():
    raise SystemExit("Release packaging requires a clean checkout")
commit = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
if subprocess.check_output(["git", "rev-list", "-n", "1", tag], text=True).strip() != commit:
    raise SystemExit("Release tag does not point to the built checkout")
architecture = subprocess.check_output(["lipo", "-archs", str(app / "Contents/MacOS/ReSign")], text=True).strip()
if architecture != "arm64":
    raise SystemExit(f"Unexpected release architecture: {architecture}")
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
signature = subprocess.run(["codesign", "--display", "--verbose=4", str(app)],
                           check=True, capture_output=True, text=True).stderr
if not any(line.strip() == "Signature=adhoc" for line in signature.splitlines()):
    raise SystemExit("This release workflow expects an ad-hoc signed app")

output = root / "dist/release"
if output.exists():
    shutil.rmtree(output)
output.mkdir()
subprocess.run([sys.executable, str(root / "scripts/package-dmg.py"),
                str(output / f"ReSign-{version}-macos-arm64.dmg"), "--app", str(app)], check=True)
subprocess.run(["git", "archive", "--format=tar.gz", f"--prefix=ReSign-{version}/",
                "-o", str(output / f"ReSign-{version}-source.tar.gz"), "HEAD"], check=True)

notices = app / "Contents/Resources/Licenses"
libraries = json.loads((notices / "bundled-libraries.json").read_text())
formulae = json.loads((notices / "homebrew-formulae.json").read_text())
formula_by_name = {item["name"]: item for item in formulae}
for library in libraries:
    if "formula" not in library:
        continue
    formula = formula_by_name[library["formula"]]
    expected = formula["versions"]["stable"] + (f"_{formula['revision']}" if formula["revision"] else "")
    if library["version"] != expected:
        raise SystemExit(f"Homebrew source metadata does not match installed {library['formula']}")
binary_sources = json.loads((notices / "binary-sources.json").read_text())
pins = json.loads((root / "Package.resolved").read_text())["pins"]
checkouts = {p.name.lower(): p for p in (root / ".build/checkouts").iterdir() if p.is_dir()}
source_downloads = []


def download(url, destination, expected_sha256=None):
    if urllib.parse.urlparse(url).scheme != "https":
        raise RuntimeError(f"Source archive must use HTTPS: {url}")
    digest = hashlib.sha256()
    with urllib.request.urlopen(url, timeout=120) as response, destination.open("wb") as target:
        while chunk := response.read(1024 * 1024):
            digest.update(chunk)
            target.write(chunk)
    actual = digest.hexdigest()
    if expected_sha256 is not None and actual != expected_sha256:
        raise RuntimeError(f"Source checksum mismatch: {destination.name}")
    source_downloads.append({"file": destination.name, "url": url, "sha256": actual})


def source_filter(member):
    if any(part in {".git", ".build", ".swiftpm"} for part in pathlib.PurePosixPath(member.name).parts):
        return None
    return member


with tempfile.TemporaryDirectory(prefix="release-sources-", dir=root / "dist") as temporary:
    staging = pathlib.Path(temporary)
    for formula in formulae:
        source = formula["urls"]["stable"]
        checksum = source.get("checksum")
        if not checksum or not re.fullmatch(r"[0-9a-f]{64}", checksum):
            raise RuntimeError(f"Missing source SHA-256 for {formula['name']}")
        filename = pathlib.PurePosixPath(urllib.parse.urlparse(source["url"]).path).name
        download(source["url"], staging / (formula["name"].replace("@", "-") + "-" + filename), checksum)
    for source in binary_sources:
        repository_path = source["repository"].removeprefix("https://github.com/")
        download(f"https://codeload.github.com/{repository_path}/tar.gz/{source['revision']}",
                 staging / f"{source['name']}-{source['revision']}.tar.gz")
    with tarfile.open(output / f"ReSign-{version}-dependencies.tar.gz", "w:gz") as archive:
        for pin in pins:
            checkout = checkouts[pin["identity"]]
            revision = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
            if revision != pin["state"]["revision"]:
                raise RuntimeError(f"Source revision mismatch: {pin['identity']}")
            archive.add(checkout, arcname="SwiftPackages/" + pin["identity"], filter=source_filter)
        for path in staging.iterdir():
            archive.add(path, arcname="SourceArchives/" + path.name)
        archive.add(notices, arcname="Licenses")
        archive.add(root / "Package.resolved", arcname="Package.resolved")
        instructions = staging / "README.md"
        instructions.write_text(
            "# Dependency sources\n\n"
            "SwiftPackages contains the exact Swift Package Manager checkouts. "
            "SourceArchives contains the source archives for bundled Homebrew libraries "
            "and the pinned Unicorn binary package. Licenses contains notices and "
            "Homebrew formula metadata. See the accompanying ReSign source archive "
            "for Package.resolved, build scripts and relinking instructions in docs/RELEASING.md.\n")
        archive.add(instructions, arcname="README.md")

build_info = {
    "version": version, "build": info["CFBundleVersion"], "tag": tag, "commit": commit,
    "architecture": architecture, "minimum_macos": info["LSMinimumSystemVersion"],
    "signing": "ad-hoc", "notarized": False,
    "built_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "runner_image": os.environ.get("ImageVersion"),
    "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
    "swift": subprocess.check_output(["swift", "--version"], text=True).strip(),
    "swift_packages": pins, "source_downloads": source_downloads,
}
(output / "BUILD-INFO.json").write_text(json.dumps(build_info, indent=2) + "\n")
with (output / "SHA256SUMS").open("w") as sums:
    for path in sorted(output.iterdir()):
        if path.name == "SHA256SUMS":
            continue
        with path.open("rb") as source:
            digest = hashlib.sha256()
            while chunk := source.read(1024 * 1024):
                digest.update(chunk)
        sums.write(f"{digest.hexdigest()}  {path.name}\n")
print(f"Release assets: {output}")
