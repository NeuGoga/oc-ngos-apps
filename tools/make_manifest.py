#!/usr/bin/env python3
"""Regenerate Music/manifest.tbl, songs/catalog.tbl and the apps.tbl entry.

Run this from the repository root after changing any Lua source or adding a
.dfpwm file, then commit. The in-game updater compares manifest versions, so
bump the version when you want clients to pull:

    python tools/make_manifest.py --version 1.1.0 --skip-catalog
    git add -A && git commit -m "Music 1.1.0" && git push

In your own music repository, only the catalogue matters:

    python tools/make_manifest.py --catalog-only

Hashes must match what NgOS's store computes, which is sha256 over the file
content after `gsub("\\r", "")` and stripping trailing whitespace
(see /ngos/bin/store.lua). normalise() below mirrors that exactly.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

APP = "Music"
# Not "music": on a case-insensitive filesystem that is the same
# directory as the app folder above.
SONG_DIR = "songs"
# Bytes of tape consumed per second of audio at speed 1.0. One 1024 byte
# packet every 250 ms -- see TapeDriveState.java.
BYTES_PER_SECOND = 4096

# Shipped to the computer. Everything else in the app folder (README, extras)
# stays in the repository only.
APP_FILES = [
    "app.lua",
    "mplayer/rt.lua",
    "mplayer/repo.lua",
    "mplayer/tape.lua",
    "mplayer/download.lua",
    "mplayer/catalog.lua",
    "mplayer/diag.lua",
    "mplayer/player.lua",
    "mplayer/update.lua",
    "mplayer/ui.lua",
]

# Installed outside the app directory, onto the default PATH.
SYSTEM_FILES = {
    "/usr/bin/music.lua": "cli.lua",
}


def normalise(data: bytes) -> bytes:
    """Match store.lua: content:gsub("\\r", ""):gsub("%s+$", "").

    rstrip() rather than re.sub(rb"\\s+$", ...) on purpose: Python's `$` also
    matches just before a trailing newline, which is not how Lua's `$` anchor
    behaves. bytes.rstrip() strips exactly b" \\t\\n\\r\\x0b\\f", the same set
    Lua's %s matches in the C locale.
    """
    return data.replace(b"\r", b"").rstrip()


def sha256_of(path: Path) -> str:
    return hashlib.sha256(normalise(path.read_bytes())).hexdigest()


def raw_url(owner: str, repo: str, branch: str, path: str) -> str:
    return f"https://raw.githubusercontent.com/{owner}/{repo}/{branch}/{path}"


def lua_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def stamp_version(version: str) -> None:
    """Bake the version into ui.lua so the app can show what is running.

    Must run before hashing, or the manifest would record the hash of the
    unstamped file and the updater would reject its own release.
    """
    path = ROOT / APP / "mplayer" / "ui.lua"
    text = path.read_text(encoding="utf-8")
    marker = re.compile(r'local VERSION = "[^"]*" --\[\[VERSION\]\]')
    if not marker.search(text):
        sys.exit("Could not find the VERSION marker in Music/mplayer/ui.lua")
    stamped = marker.sub(f'local VERSION = "{version}" --[[VERSION]]', text)
    if stamped != text:
        path.write_text(stamped, encoding="utf-8")


def build_manifest(owner: str, repo: str, branch: str, version: str) -> str:
    stamp_version(version)
    lines = ["{", f'  version = {lua_string(version)},', "  files = {"]

    missing = []
    for rel in APP_FILES:
        path = ROOT / APP / rel
        if not path.is_file():
            missing.append(f"{APP}/{rel}")
            continue
        repo_path = f"{APP}/{rel}"
        lines.append(f"    [{lua_string(rel)}] = {{")
        lines.append(f"      url = {lua_string(raw_url(owner, repo, branch, repo_path))},")
        lines.append(f"      path = {lua_string(repo_path)},")
        lines.append(f"      sha256 = {lua_string(sha256_of(path))}")
        lines.append("    },")
    lines.append("  },")

    lines.append("  system = {")
    for target, rel in SYSTEM_FILES.items():
        path = ROOT / APP / rel
        if not path.is_file():
            missing.append(f"{APP}/{rel}")
            continue
        repo_path = f"{APP}/{rel}"
        lines.append(f"    [{lua_string(target)}] = {{")
        lines.append(f"      url = {lua_string(raw_url(owner, repo, branch, repo_path))},")
        lines.append(f"      path = {lua_string(repo_path)},")
        lines.append(f"      sha256 = {lua_string(sha256_of(path))}")
        lines.append("    },")
    lines.append("  }")
    lines.append("}")

    if missing:
        sys.exit("Missing source files:\n  " + "\n  ".join(missing))

    return "\n".join(lines) + "\n"


def build_catalog() -> tuple[str, int]:
    """List every .dfpwm in songs/, with its length derived from its size."""
    song_dir = ROOT / SONG_DIR
    song_dir.mkdir(exist_ok=True)

    entries = sorted(song_dir.glob("*.dfpwm"), key=lambda p: p.name.lower())
    lines = ["{"]
    for path in entries:
        size = path.stat().st_size
        seconds = round(size / BYTES_PER_SECOND)
        # "Artist - Title.dfpwm" -> "Artist - Title"
        title = path.stem.replace("_", " ").strip()
        lines.append("  {")
        lines.append(f"    title = {lua_string(title)},")
        lines.append(f'    file = {lua_string(SONG_DIR + "/" + path.name)},')
        lines.append(f"    seconds = {seconds},")
        lines.append(f"    bytes = {size}")
        lines.append("  },")
    lines.append("}")
    return "\n".join(lines) + "\n", len(entries)


def update_apps_tbl(owner: str, repo: str, branch: str) -> bool:
    """Add a Music entry to apps.tbl if it is not already there."""
    apps_path = ROOT / "apps.tbl"
    manifest_url = raw_url(owner, repo, branch, f"{APP}/manifest.tbl")

    if not apps_path.is_file():
        apps_path.write_text("{\n}\n", encoding="utf-8")

    text = apps_path.read_text(encoding="utf-8")
    if f'id = "{APP}"' in text:
        # Keep the manifest URL current even if the entry already exists.
        new_text = re.sub(
            r'(id = "Music".*?manifest = ")[^"]*(")',
            lambda m: m.group(1) + manifest_url + m.group(2),
            text,
            flags=re.S,
        )
        if new_text != text:
            apps_path.write_text(new_text, encoding="utf-8")
            return True
        return False

    entry = (
        "  {\n"
        f'    id = "{APP}",\n'
        f'    name = "{APP}",\n'
        '    desc = "Tape drive music player with a download queue",\n'
        f'    manifest = "{manifest_url}"\n'
        "  }"
    )
    stripped = text.rstrip()
    if not stripped.endswith("}"):
        sys.exit("apps.tbl does not look like a Lua table")
    inner = stripped[:-1].rstrip()
    if inner.endswith("{"):
        merged = inner + "\n" + entry + "\n}\n"
    else:
        merged = inner + ",\n" + entry + "\n}\n"
    apps_path.write_text(merged, encoding="utf-8")
    return True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--owner", default="NeuGoga", help="GitHub user owning the app repo")
    parser.add_argument("--repo", default="oc-ngos-apps", help="app repository name")
    parser.add_argument("--branch", default="main")
    parser.add_argument("--version", default=None, help="new app version, e.g. 1.1.0")
    parser.add_argument("--from-remote", action="store_true",
                        help="take owner/repo from the git origin instead of the defaults")
    parser.add_argument("--catalog-only", action="store_true",
                        help="only rebuild songs/catalog.tbl (for your music repo)")
    parser.add_argument("--skip-catalog", action="store_true",
                        help="do not touch songs/catalog.tbl (app repo has no songs)")
    args = parser.parse_args()

    if args.catalog_only:
        catalog, count = build_catalog()
        (ROOT / SONG_DIR / "catalog.tbl").write_text(catalog, encoding="utf-8")
        print(f"{SONG_DIR}/catalog.tbl  {count} song(s)")
        return

    owner, repo = args.owner, args.repo
    if args.from_remote:
        import subprocess

        try:
            url = subprocess.check_output(
                ["git", "-C", str(ROOT), "remote", "get-url", "origin"], text=True
            ).strip()
        except Exception:
            sys.exit("Cannot read the git remote; pass --owner and --repo.")
        match = re.search(r"[:/]([^/:]+)/([^/]+?)(?:\.git)?$", url)
        if not match:
            sys.exit(f"Cannot parse the remote URL: {url}")
        owner, repo = match.group(1), match.group(2)

    manifest_path = ROOT / APP / "manifest.tbl"
    version = args.version
    if not version:
        if manifest_path.is_file():
            found = re.search(r'version\s*=\s*"([^"]+)"', manifest_path.read_text(encoding="utf-8"))
            version = found.group(1) if found else "1.0.0"
        else:
            version = "1.0.0"

    manifest_path.write_text(build_manifest(owner, repo, args.branch, version), encoding="utf-8")
    print(f"{APP}/manifest.tbl   version {version}, {len(APP_FILES)} app files "
          f"+ {len(SYSTEM_FILES)} system file(s)")

    if not args.skip_catalog:
        catalog, count = build_catalog()
        (ROOT / SONG_DIR / "catalog.tbl").write_text(catalog, encoding="utf-8")
        print(f"{SONG_DIR}/catalog.tbl  {count} song(s)")

    if update_apps_tbl(owner, repo, args.branch):
        print("apps.tbl          Music entry written")
    else:
        print("apps.tbl          already current")

    print(f"\nRepository: {owner}/{repo} ({args.branch})")
    print("Commit and push, then run `music update` in game.")


if __name__ == "__main__":
    main()
