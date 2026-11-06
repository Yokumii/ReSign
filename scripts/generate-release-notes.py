#!/usr/bin/env python3
"""Generate release Markdown from version tags and commit subjects."""
import argparse
import os
import pathlib
import plistlib
import re
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
VERSION_TAG = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
COMMIT = re.compile(r"^(?P<type>[a-z]+)(?:\((?P<scope>[^()]+)\))?(?P<breaking>!)?:\s*(?P<summary>.+)$")


def git(*arguments):
    return subprocess.check_output(["git", "-C", str(root), *arguments], text=True).strip()


def escape_markdown(text):
    for character in "\\`*_{}[]<>()#!|":
        text = text.replace(character, "\\" + character)
    return text


def previous_tag(tag):
    parents = git("rev-list", "--parents", "-n", "1", tag).split()[1:]
    if not parents:
        return None
    candidates = [value for value in git("tag", "--merged", parents[0]).splitlines()
                  if VERSION_TAG.fullmatch(value)]
    if not candidates:
        return None
    matches = [argument for value in candidates for argument in ("--match", value)]
    return git("describe", "--tags", "--abbrev=0", *matches, parents[0])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", default=os.environ.get("RELEASE_TAG"))
    parser.add_argument("--output", type=pathlib.Path, default=root / "dist/RELEASE_NOTES.md")
    arguments = parser.parse_args()
    tag = arguments.tag
    if not tag or not VERSION_TAG.fullmatch(tag):
        parser.error("Specify a version tag such as v1.0.0")
    with (root / "Resources/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    version = info["CFBundleShortVersionString"]
    if tag != "v" + version or git("rev-list", "-n", "1", tag) != git("rev-parse", "HEAD"):
        raise SystemExit("Tag, checkout and Info.plist version must match")
    previous = previous_tag(tag)
    revision_range = f"{previous}..{tag}" if previous else tag
    repository = os.environ.get("GITHUB_REPOSITORY")
    if repository and not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise SystemExit("Invalid GITHUB_REPOSITORY")
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com").rstrip("/")
    repository_url = f"{server}/{repository}" if repository else None

    groups = {name: [] for name in ["不兼容变更", "新增功能", "问题修复", "性能优化", "代码重构", "测试", "文档", "构建与发布", "其他变更"]}
    categories = {"feat": "新增功能", "fix": "问题修复", "perf": "性能优化", "refactor": "代码重构",
                  "test": "测试", "docs": "文档", "build": "构建与发布", "ci": "构建与发布", "deps": "构建与发布"}
    for commit in git("log", "--no-merges", "--format=%H", revision_range).splitlines():
        message = git("show", "-s", "--format=%B", commit)
        lines = message.splitlines()
        subject = lines[0] if lines else "Untitled commit"
        matched = COMMIT.fullmatch(subject)
        breaking = bool(matched and matched["breaking"]) or bool(re.search(r"^BREAKING[ -]CHANGE:", message, re.M))
        category = "不兼容变更" if breaking else categories.get(matched["type"] if matched else "", "其他变更")
        summary = matched["summary"] if matched else subject
        if matched and matched["scope"]:
            summary = escape_markdown(matched["scope"]) + "：" + summary
        reference = f"[{commit[:7]}]({repository_url}/commit/{commit})" if repository_url else commit[:7]
        groups[category].append(f"- {escape_markdown(summary)} ({reference})")

    template = (root / "docs/RELEASE_TEMPLATE.md").read_text(encoding="utf-8")
    for name, value in {"version": version, "minimum_macos": info["LSMinimumSystemVersion"],
                        "app_archive": f"ReSign-{version}-macos-arm64.dmg"}.items():
        template = template.replace("{" + name + "}", value)
    sections = [template.rstrip()]
    supplement = root / "docs/releases" / f"{version}.md"
    if supplement.is_file():
        sections.append(supplement.read_text(encoding="utf-8").strip())
    sections.append("## 本次更新")
    for title, entries in groups.items():
        if entries:
            sections.append("### " + title + "\n\n" + "\n".join(entries))
    if not any(groups.values()):
        sections.append("此版本没有新增的非合并提交。")
    if repository_url:
        url = f"{repository_url}/compare/{previous}...{tag}" if previous else f"{repository_url}/commits/{tag}"
        sections.append(f"[完整变更记录]({url})")
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text("\n\n".join(sections) + "\n", encoding="utf-8")
    print(f"Release notes: {arguments.output}")


if __name__ == "__main__":
    main()
