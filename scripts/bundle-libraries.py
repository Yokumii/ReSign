#!/usr/bin/env python3
"""Build-time helper only; Python is not shipped or required by ReSign.app."""
import json
import pathlib
import re
import shutil
import subprocess
import sys

app, bin_dir, brew_prefix = map(pathlib.Path, sys.argv[1:])
frameworks = app / "Contents/Frameworks"
main_binary = app / "Contents/MacOS/ReSign"
copied = {}


def run(*arguments):
    return subprocess.check_output(arguments, text=True)


def dependencies(binary):
    return [line.strip().split(" (compatibility version", 1)[0]
            for line in run("/usr/bin/otool", "-L", str(binary)).splitlines()[1:]]


def rpaths(binary):
    lines = run("/usr/bin/otool", "-l", str(binary)).splitlines()
    result = []
    for index, line in enumerate(lines):
        if "cmd LC_RPATH" in line:
            for candidate in lines[index + 1:index + 4]:
                match = re.search(r"path (.*?) \(offset", candidate)
                if match:
                    result.append(match.group(1))
    return result


def expanded(path, origin):
    return pathlib.Path(path.replace("@loader_path", str(origin.parent))
                        .replace("@executable_path", str(bin_dir)))


def resolve(dependency, origin):
    if dependency.startswith("@rpath/"):
        suffix = dependency.removeprefix("@rpath/")
        for base in [*rpaths(origin), *rpaths(main_binary), str(bin_dir), str(brew_prefix / "lib")]:
            candidate = expanded(base, origin) / suffix
            if candidate.exists():
                return candidate.resolve()
        raise RuntimeError(f"无法定位动态库：{dependency}，来源：{origin}")
    return expanded(dependency, origin).resolve()


def bundle(origin, destination):
    for dependency in dependencies(origin):
        if dependency.startswith(("/usr/lib/", "/System/Library/")):
            continue
        source = resolve(dependency, origin)
        # A dylib's first entry is its own install name.
        if source == origin.resolve():
            continue
        if not source.is_file():
            raise RuntimeError(f"动态依赖不存在：{source}")
        framework = next((parent for parent in source.parents if parent.suffix == ".framework"), None)
        name = str(pathlib.Path(framework.name) / source.relative_to(framework)) if framework else source.name
        if name in copied and copied[name] != source:
            raise RuntimeError(f"动态库名称冲突：{source} 与 {copied[name]}")
        bundled = frameworks / name
        if name not in copied:
            copied[name] = source
            if framework:
                target = frameworks / framework.name
                if target.exists():
                    raise RuntimeError(f"Framework 名称冲突：{framework.name}")
                shutil.copytree(framework, target, symlinks=True)
            else:
                shutil.copy2(source, bundled)
            bundled.chmod(bundled.stat().st_mode | 0o200)
            subprocess.run(["/usr/bin/install_name_tool", "-id", "@rpath/" + name, str(bundled)], check=True)
            bundle(source, bundled)
        subprocess.run(["/usr/bin/install_name_tool", "-change", dependency,
                        "@rpath/" + name, str(destination)], check=True)


bundle(main_binary, main_binary)
subprocess.run(["/usr/bin/install_name_tool", "-add_rpath", "@executable_path/../Frameworks", str(main_binary)], check=True)

# SwiftPM resource accessors in macOS application bundles use the resource directory.
for resource in bin_dir.glob("*.bundle"):
    shutil.copytree(resource, app / "Contents/Resources" / resource.name)

# Preserve the exact source locations for notices and release source collection.
manifest = []
for name, source in sorted(copied.items()):
    entry = {"name": name, "source": str(source)}
    if source.is_relative_to(brew_prefix / "Cellar"):
        parts = source.relative_to(brew_prefix / "Cellar").parts
        entry.update(formula=parts[0], version=parts[1],
                     cellar=str(brew_prefix / "Cellar" / parts[0] / parts[1]))
    manifest.append(entry)
(app / "Contents/Resources/Licenses/bundled-libraries.json").write_text(
    json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
