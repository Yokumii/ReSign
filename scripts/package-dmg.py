#!/usr/bin/env python3
"""Package ReSign.app in a compressed disk image with an Applications shortcut."""
import argparse
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=pathlib.Path, help="Destination .dmg file")
    parser.add_argument("--app", type=pathlib.Path, default=root / "dist/ReSign.app")
    arguments = parser.parse_args()
    app = arguments.app.resolve()
    output = arguments.output.resolve()
    if not (app / "Contents/Info.plist").is_file():
        parser.error(f"App bundle not found: {app}")
    if output.suffix != ".dmg":
        parser.error("Output filename must end in .dmg")
    output.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="resign-dmg-", dir=output.parent) as temporary:
        staging = pathlib.Path(temporary)
        subprocess.run(["ditto", str(app), str(staging / app.name)], check=True)
        (staging / "Applications").symlink_to("/Applications", target_is_directory=True)
        subprocess.run(["hdiutil", "create", "-volname", "ReSign", "-srcfolder", str(staging),
                        "-fs", "HFS+", "-format", "UDZO", "-ov", str(output)], check=True)
    if not output.is_file() or output.stat().st_size == 0:
        raise RuntimeError(f"Disk image was not created: {output}")
    subprocess.run(["hdiutil", "verify", str(output)], check=True)
    print(f"Disk image: {output}")


if __name__ == "__main__":
    main()
