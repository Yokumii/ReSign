#!/usr/bin/env python3
"""Static engineering & AI-coding consistency checks for ReSign.

Validates:
1. CLAUDE.md symlink points to AGENTS.md.
2. DESIGN.md ThemePalette light/dark token values match Sources/ReSign/AppTheme.swift.
3. Version consistency across Resources/Info.plist, README.md, and docs/releases/<ver>.md.
4. Pinned Swift dependency revisions across Package.swift, Package.resolved,
   Vendor/SideSign/UPSTREAM.md, and scripts/binary-sources.json.
5. Source hygiene: no bare print/debugPrint/NSLog in Sources/ReSign, UTF-8 & LF-only endings.
6. Python and shell script syntax validation.

Zero external dependencies (Python 3 standard library only).
"""

import json
import os
import pathlib
import plistlib
import py_compile
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def check_claude_symlink(errors: list[str]) -> None:
    claude = ROOT / "CLAUDE.md"
    agents = ROOT / "AGENTS.md"
    if not agents.is_file():
        errors.append("Missing AGENTS.md at repository root.")
        return
    if not claude.is_symlink():
        errors.append("CLAUDE.md must be a symlink pointing to AGENTS.md.")
        return
    target = os.readlink(claude)
    if target != "AGENTS.md":
        errors.append(f"CLAUDE.md symlink points to '{target}', expected 'AGENTS.md'.")


def parse_app_theme_tokens(path: pathlib.Path) -> dict[str, tuple[float, float]]:
    """Extract (light, dark) opacity pairs from ThemePalette in AppTheme.swift."""
    text = path.read_text(encoding="utf-8")
    match = re.search(r"struct ThemePalette\s*\{(.*?)\n\}", text, re.S)
    if not match:
        raise RuntimeError("Could not find 'struct ThemePalette' in AppTheme.swift")
    body = match.group(1)

    tokens: dict[str, tuple[float, float]] = {}
    # Match: var <name>: ... { ... isDark ? <dark> : <light> ... }
    # or:    func <name>(...) -> ... { ... isDark ? <dark> : <light> ... }
    decl_pattern = re.compile(
        r"(?:var\s+(?P<var>\w+)|func\s+(?P<func>\w+)\s*\((?P<params>[^)]*)\))[^{]*\{(?P<expr>[^}]+)\}"
    )
    ternary_num = re.compile(r"isDark\s*\?\s*([0-9]+(?:\.[0-9]+)?)\s*:\s*([0-9]+(?:\.[0-9]+)?)")
    dark_only = re.compile(r"isDark\s*\?[^:]*opacity\(([0-9]+(?:\.[0-9]+)?)\)\s*:\s*\.clear")

    for m in decl_pattern.finditer(body):
        if m.group("var"):
            name = m.group("var")
            if name == "isDark":
                continue
        else:
            params = m.group("params").strip()
            name = f"{m.group('func')}({'_:' if params else ''})"
        expr = m.group("expr")
        t = ternary_num.search(expr)
        if t:
            dark_val, light_val = float(t.group(1)), float(t.group(2))
            tokens[name] = (light_val, dark_val)
            continue
        d = dark_only.search(expr)
        if d:
            tokens[name] = (0.0, float(d.group(1)))
    return tokens


def check_design_tokens(errors: list[str]) -> None:
    theme_path = ROOT / "Sources/ReSign/AppTheme.swift"
    design_path = ROOT / "DESIGN.md"
    if not theme_path.is_file():
        errors.append("Missing Sources/ReSign/AppTheme.swift.")
        return
    if not design_path.is_file():
        errors.append("Missing DESIGN.md at repository root.")
        return

    code_tokens = parse_app_theme_tokens(theme_path)
    design_text = design_path.read_text(encoding="utf-8")

    # Parse markdown table rows: | `token` | `base` | `0.07` | `0.13` | ... |
    row_re = re.compile(
        r"^\|\s*`(?P<name>[^`]+)`\s*\|\s*[^|]+\|\s*`(?P<light>[0-9]+(?:\.[0-9]+)?)`\s*\|\s*`(?P<dark>[0-9]+(?:\.[0-9]+)?)`\s*\|",
        re.M,
    )
    doc_tokens: dict[str, tuple[float, float]] = {}
    for m in row_re.finditer(design_text):
        doc_tokens[m.group("name").strip()] = (float(m.group("light")), float(m.group("dark")))

    for name, (light, dark) in sorted(code_tokens.items()):
        if name not in doc_tokens:
            errors.append(f"DESIGN.md is missing ThemePalette token '{name}' (light={light:.2f}, dark={dark:.2f}).")
            continue
        doc_light, doc_dark = doc_tokens[name]
        if abs(doc_light - light) > 1e-6 or abs(doc_dark - dark) > 1e-6:
            errors.append(
                f"DESIGN.md token '{name}' mismatch: "
                f"AppTheme.swift has (light={light:.2f}, dark={dark:.2f}), "
                f"DESIGN.md has (light={doc_light:.2f}, dark={doc_dark:.2f})."
            )

    for name in sorted(doc_tokens):
        if name not in code_tokens:
            errors.append(f"DESIGN.md documents unknown ThemePalette token '{name}' not found in AppTheme.swift.")


def check_version_consistency(errors: list[str]) -> None:
    plist_path = ROOT / "Resources/Info.plist"
    with plist_path.open("rb") as f:
        info = plistlib.load(f)
    version = info.get("CFBundleShortVersionString", "")
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        errors.append(f"Invalid CFBundleShortVersionString in Resources/Info.plist: '{version}'.")
        return

    release_doc = ROOT / "docs/releases" / f"{version}.md"
    if not release_doc.is_file():
        errors.append(f"Missing release supplement file: docs/releases/{version}.md (Info.plist version is {version}).")

    readme_text = (ROOT / "README.md").read_text(encoding="utf-8")
    m = re.search(r"当前版本为\s+([0-9]+\.[0-9]+\.[0-9]+)", readme_text)
    if not m:
        errors.append("README.md is missing '当前版本为 X.Y.Z' version declaration.")
    elif m.group(1) != version:
        errors.append(f"README.md version ({m.group(1)}) does not match Resources/Info.plist ({version}).")

    expected_link = f"docs/releases/{version}.md"
    if expected_link not in readme_text:
        errors.append(f"README.md does not link to current release notes '{expected_link}'.")


def check_pinned_dependencies(errors: list[str]) -> None:
    package_swift = (ROOT / "Package.swift").read_text(encoding="utf-8")
    resolved = json.loads((ROOT / "Package.resolved").read_text(encoding="utf-8"))
    pins = {pin["identity"].lower(): pin["state"] for pin in resolved.get("pins", [])}

    # Verify AnisetteKit revision in Package.swift matches Package.resolved
    m = re.search(r'AnisetteKit\.git",\s*revision:\s*"([0-9a-f]{40})"', package_swift)
    if not m:
        errors.append("Package.swift must pin AnisetteKit to a 40-character commit revision.")
    else:
        pkg_rev = m.group(1)
        resolved_rev = pins.get("anisettekit", {}).get("revision")
        if pkg_rev != resolved_rev:
            errors.append(
                f"AnisetteKit revision mismatch: Package.swift={pkg_rev}, Package.resolved={resolved_rev}."
            )

    # Verify Vendor/SideSign/UPSTREAM.md pin table matches Package.resolved
    upstream_text = (ROOT / "Vendor/SideSign/UPSTREAM.md").read_text(encoding="utf-8")
    row_re = re.compile(r"^\|\s*([A-Za-z0-9_-]+)\s*\|\s*([0-9a-f]{40}|[0-9]+\.[0-9]+\.[0-9]+)", re.M)
    for m in row_re.finditer(upstream_text):
        dep_name, expected = m.group(1).lower(), m.group(2)
        if dep_name not in pins:
            errors.append(f"Vendor/SideSign/UPSTREAM.md lists '{dep_name}' which is missing from Package.resolved.")
            continue
        state = pins[dep_name]
        actual = state.get("revision") if len(expected) == 40 else state.get("version")
        if actual != expected:
            errors.append(
                f"Vendor/SideSign/UPSTREAM.md pin mismatch for '{dep_name}': "
                f"UPSTREAM.md={expected}, Package.resolved={actual}."
            )

    # Verify scripts/binary-sources.json format
    binary_sources = json.loads((ROOT / "scripts/binary-sources.json").read_text(encoding="utf-8"))
    for item in binary_sources:
        name = item.get("name", "<unknown>")
        if not str(item.get("binary_url", "")).startswith("https://"):
            errors.append(f"scripts/binary-sources.json: '{name}' binary_url must use https://.")
        if not re.fullmatch(r"[0-9a-f]{64}", str(item.get("binary_checksum", ""))):
            errors.append(f"scripts/binary-sources.json: '{name}' binary_checksum must be 64-char hex SHA-256.")
        if not re.fullmatch(r"[0-9a-f]{40}", str(item.get("revision", ""))):
            errors.append(f"scripts/binary-sources.json: '{name}' revision must be 40-char commit SHA.")


def check_source_hygiene(errors: list[str]) -> None:
    # 1. No bare print/debugPrint/NSLog in Sources/ReSign/
    forbidden_log = re.compile(r"\b(?:print|debugPrint|NSLog)\s*\(")
    for swift_file in sorted((ROOT / "Sources/ReSign").glob("*.swift")):
        for lineno, line in enumerate(swift_file.read_text(encoding="utf-8").splitlines(), 1):
            stripped = line.lstrip()
            if stripped.startswith("//"):
                continue
            if forbidden_log.search(line):
                rel = swift_file.relative_to(ROOT)
                errors.append(
                    f"{rel}:{lineno}: avoid bare print/debugPrint/NSLog in Sources/ReSign; use AppModel.record(_:)."
                )

    # 2. UTF-8 and LF line endings across first-party text files
    skip_dirs = {".git", ".build", ".swiftpm", "dist", "Vendor", "__pycache__"}
    text_exts = {".swift", ".c", ".h", ".m", ".py", ".sh", ".md", ".yml", ".yaml", ".json", ".command"}
    exact_names = {"Makefile", ".editorconfig", ".gitignore", ".gitattributes", ".swift-format", "pre-commit"}

    for path in sorted(ROOT.rglob("*")):
        if any(part in skip_dirs for part in path.parts):
            continue
        if not path.is_file() or path.is_symlink():
            continue
        if path.suffix not in text_exts and path.name not in exact_names:
            continue
        raw = path.read_bytes()
        rel = path.relative_to(ROOT)
        if b"\r\n" in raw:
            errors.append(f"{rel}: contains CRLF line endings (expected LF per .editorconfig).")
        try:
            raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            errors.append(f"{rel}: not valid UTF-8 ({exc}).")


def check_scripts_syntax(errors: list[str]) -> None:
    for py_file in sorted((ROOT / "scripts").glob("*.py")):
        try:
            py_compile.compile(str(py_file), doraise=True)
        except py_compile.PyCompileError as exc:
            errors.append(f"Python syntax error in {py_file.relative_to(ROOT)}: {exc.msg}")

    shell_files = [
        *sorted((ROOT / "scripts").glob("*.sh")),
        ROOT / "build.command",
        *sorted((ROOT / "deploy/anisette").glob("*.sh")),
    ]
    githooks = ROOT / ".githooks"
    if githooks.is_dir():
        shell_files.extend(p for p in sorted(githooks.iterdir()) if p.is_file())

    for sh_file in shell_files:
        if not sh_file.is_file():
            continue
        proc = subprocess.run(["bash", "-n", str(sh_file)], capture_output=True, text=True)
        if proc.returncode != 0:
            errors.append(f"Shell syntax error in {sh_file.relative_to(ROOT)}: {proc.stderr.strip()}")


def main() -> int:
    errors: list[str] = []
    check_claude_symlink(errors)
    check_design_tokens(errors)
    check_version_consistency(errors)
    check_pinned_dependencies(errors)
    check_source_hygiene(errors)
    check_scripts_syntax(errors)

    if errors:
        print(f"Consistency check failed with {len(errors)} issue(s):", file=sys.stderr)
        for item in errors:
            print(f"  - {item}", file=sys.stderr)
        return 1

    print("All consistency, token, version, dependency, hygiene, and script syntax checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
