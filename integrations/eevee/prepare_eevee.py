#!/usr/bin/env python3
"""Apply dxify's reviewed, SponsorBlock-only profile to pinned Eevee sources."""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

PINNED_COMMIT = "ca363e63efd4730811a241ec48a5c0e4ef838112"
TWEAK = Path("Sources/EeveeSpotify/Tweak.x.swift")
SIDELOAD_FIX = Path("modules/zxPluginsInject/SideloadFix.xm")
DEFAULT_HOOK_FILES = {
    Path("Sources/EeveeSpotify/CleanShareLinks.x.swift"): 3,
    Path("Sources/EeveeSpotify/Experiments/LiveContainer/LiveContainerSharing.x.swift"): 1,
    Path("Sources/EeveeSpotify/OpenSpotify.x.swift"): 1,
}


class PreparationError(Exception):
    pass


def read_text(root: Path, relative: Path) -> tuple[Path, str, str]:
    path = root / relative
    raw = path.read_bytes()
    text = raw.decode("utf-8")
    newline = "\r\n" if b"\r\n" in raw else "\n"
    normalized = text.replace("\r\n", "\n")
    if "\r" in normalized:
        raise PreparationError(f"Mixed or unsupported line endings in {relative}")
    return path, normalized, newline


def verify_checkout(root: Path) -> None:
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "--show-toplevel", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        raise PreparationError("source must be a Git checkout of the pinned Reincarnated commit") from exc
    lines = result.stdout.splitlines()
    if len(lines) != 2 or Path(lines[0]).resolve() != root.resolve():
        raise PreparationError("source must point to the checkout root")
    if lines[1] != PINNED_COMMIT:
        raise PreparationError(f"expected Git HEAD {PINNED_COMMIT}; found {lines[1]}")


def prepare_tweak(root: Path) -> tuple[Path, bytes]:
    path, text, newline = read_text(root, TWEAK)
    owner = text.find("struct EeveeSpotify: Tweak {")
    start = text.find("    init() {\n", owner)
    close = text.rfind("\n    }\n}")
    if owner < 0 or start < 0 or close < start:
        raise PreparationError("Unreviewed Eevee initialization layout")
    if text[close + len("\n    }\n}"):].strip():
        raise PreparationError("Unexpected content after Eevee initialization")

    init = '''    init() {
        // dxify uses its own UI, lyrics, privacy, and app-group hooks. Keep this
        // upstream layer limited to the non-premium SponsorBlock feature.
        guard EeveeSpotify.spotifyVersion == "9.1.78" else {
            writeDebugLog("[INIT] dxify integration supports SponsorBlock on Spotify 9.1.78 only")
            return
        }
        var sponsorBlockOptions = UserDefaults.sponsorBlockOptions
        sponsorBlockOptions.enabled = UserDefaults.standard.bool(forKey: "spotifyglass.eevee.sponsorblock.enabled")
        UserDefaults.sponsorBlockOptions = sponsorBlockOptions
        activateSponsorBlock()
    }'''
    updated = text[:start] + init + "\n}\n"
    group_declaration = "struct DxifyDisabledGroup: HookGroup {}\n\n"
    owner = "struct EeveeSpotify: Tweak {"
    if updated.count(owner) != 1:
        raise PreparationError("Unreviewed Eevee Tweak declaration")
    updated = updated.replace(owner, group_declaration + owner, 1)
    return path, updated.replace("\n", newline).encode("utf-8")


def disable_default_hooks(root: Path) -> list[tuple[Path, bytes]]:
    planned: list[tuple[Path, bytes]] = []
    pattern = re.compile(r"(?m)^(class \w+: ClassHook<[^>]+> \{\n)")
    for relative, expected in DEFAULT_HOOK_FILES.items():
        path, text, newline = read_text(root, relative)
        if "typealias Group = DxifyDisabledGroup" in text:
            raise PreparationError(f"Already-modified default hook source: {relative}")
        updated, count = pattern.subn(r"\1    typealias Group = DxifyDisabledGroup\n", text)
        if count != expected:
            raise PreparationError(f"Expected {expected} default hooks in {relative}; found {count}")
        planned.append((path, updated.replace("\n", newline).encode("utf-8")))
    return planned


def prepare_sideload_shim(root: Path) -> tuple[Path, bytes]:
    path, text, newline = read_text(root, SIDELOAD_FIX)

    comment_start = "// Five pieces:\n"
    comment_end = "#import <Foundation/Foundation.h>"
    if text.count(comment_start) != 1 or text.count(comment_end) != 1:
        raise PreparationError("Unreviewed zxPluginsInject header layout")
    start = text.index(comment_start)
    end = text.index(comment_end, start)
    text = text[:start] + (
        "// Two pieces:\n"
        "//   1. SecItem* rebind — apps hard-code their entitled keychain access group;\n"
        "//      resigning with another team makes that group invalid.\n"
        "//   2. CKContainer / CKEntitlements neutered — resigned bundles have no iCloud\n"
        "//      entitlements, so CloudKit lookups would assert.\n\n"
    ) + text[end:]

    interface_start = "@interface LSBundleProxy: NSObject\n"
    access_group = "static NSString *accessGroupId;"
    if text.count(interface_start) != 1 or text.count(access_group) != 1:
        raise PreparationError("Unreviewed zxPluginsInject App Group declarations")
    start = text.index(interface_start)
    end = text.index(access_group, start) + len(access_group)
    text = text[:start] + access_group + text[end:]

    helpers_start = "// =========================================================================\n// helpers\n// =========================================================================\n"
    keychain_section = "// =========================================================================\n// keychain access-group rebind (fishhook)\n// =========================================================================\n"
    if text.count(helpers_start) != 1 or text.count(keychain_section) != 1:
        raise PreparationError("Unreviewed zxPluginsInject App Group helper layout")
    start = text.index(helpers_start)
    end = text.index(keychain_section, start)
    text = text[:start] + keychain_section + text[end + len(keychain_section):]

    start_marker = "// NSFileManager group container URL"
    end_marker = "// keychain access-group bootstrap"
    if text.count(start_marker) != 1 or text.count(end_marker) != 1:
        raise PreparationError("Unreviewed zxPluginsInject App Group hook layout")
    start = text.index(start_marker)
    end = text.index(end_marker, start)
    if end <= start:
        raise PreparationError("Invalid zxPluginsInject App Group hook range")
    replacement = (
        "// App Group redirection belongs to dxify's SpotifyGlassAppGroups.dylib.\n"
        "// Keep this shim's keychain and CloudKit compatibility hooks only.\n\n"
    )
    updated = text[:start] + replacement + text[end:]
    return path, updated.replace("\n", newline).encode("utf-8")


def prepare(root: Path) -> tuple[Path, ...]:
    verify_checkout(root)
    planned = [prepare_tweak(root), *disable_default_hooks(root), prepare_sideload_shim(root)]
    for path, content in planned:
        path.write_bytes(content)
    return tuple(path for path, _ in planned)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="pinned EeveeSpotifyReincarnated checkout")
    args = parser.parse_args()
    try:
        changed = prepare(args.source)
    except (PreparationError, OSError, UnicodeError) as exc:
        print(f"Eevee preparation refused: {exc}", file=sys.stderr)
        return 1
    for path in changed:
        print(f"Prepared {path.relative_to(args.source)}")
    print("Enabled SponsorBlock only; disabled Premium, ad-blocking, duplicate UI/lyrics, default hooks, and Eevee settings hooks.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
