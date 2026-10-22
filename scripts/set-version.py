#!/usr/bin/env python3
"""Sets Murmur's version everywhere it's kept, or checks they agree.

    set-version.py 1.4.0        the Mac app (Resources/Info.plist: CFBundleShortVersionString, and CFBundleVersion one
                                higher, as Sparkle compares it), the Windows app (shell/src-tauri/tauri.conf.json) and the
                                shell's crate (shell/src-tauri/Cargo.toml, with its line in Cargo.lock)
    set-version.py --check 1.4.0    exits 1 unless all of them say 1.4.0 (the release workflow's first step)
"""
import json
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLIST = ROOT / "Resources/Info.plist"
TAURI = ROOT / "shell/src-tauri/tauri.conf.json"
CARGO = ROOT / "shell/src-tauri/Cargo.toml"
LOCK = ROOT / "shell/src-tauri/Cargo.lock"


def versions():
    plist = plistlib.loads(PLIST.read_bytes())
    tauri = json.loads(TAURI.read_text(encoding="utf-8"))
    cargo = re.search(r'(?m)^version = "([^"]+)"', CARGO.read_text(encoding="utf-8")).group(1)
    return {"Info.plist": plist["CFBundleShortVersionString"], "tauri.conf.json": tauri["version"], "Cargo.toml": cargo}


def set_version(version):
    # Info.plist: edited as text, so its layout and comments stay as they are.
    text = PLIST.read_text(encoding="utf-8")
    build = int(plistlib.loads(PLIST.read_bytes())["CFBundleVersion"]) + 1
    text = re.sub(r"(<key>CFBundleShortVersionString</key>\s*<string>)[^<]*(</string>)", rf"\g<1>{version}\g<2>", text)
    text = re.sub(r"(<key>CFBundleVersion</key>\s*<string>)[^<]*(</string>)", rf"\g<1>{build}\g<2>", text)
    PLIST.write_text(text, encoding="utf-8")

    text = TAURI.read_text(encoding="utf-8")
    TAURI.write_text(re.sub(r'("version":\s*")[^"]*(")', rf"\g<1>{version}\g<2>", text, count=1), encoding="utf-8")

    text = CARGO.read_text(encoding="utf-8")
    CARGO.write_text(re.sub(r'(?m)^(version = ")[^"]*(")', rf"\g<1>{version}\g<2>", text, count=1), encoding="utf-8")
    text = LOCK.read_text(encoding="utf-8")
    LOCK.write_text(re.sub(r'(name = "murmur-shell"\nversion = ")[^"]*(")', rf"\g<1>{version}\g<2>", text), encoding="utf-8")
    print(f"Murmur {version} (Mac build {build})")


def main():
    args = sys.argv[1:]
    check = "--check" in args
    args = [a for a in args if a != "--check"]
    if len(args) != 1 or not re.fullmatch(r"\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?", args[0]):
        sys.exit(__doc__)
    version = args[0]
    if check:
        found = versions()
        wrong = {name: v for name, v in found.items() if v != version}
        if wrong:
            sys.exit(f"not {version}: " + ", ".join(f"{name} says {v}" for name, v in wrong.items()))
        print(f"all at {version}")
    else:
        set_version(version)


if __name__ == "__main__":
    main()
