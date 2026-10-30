#!/usr/bin/env python3
"""Attach checksum-verified upstream WebRTC symbols to a macOS archive."""
import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile
import urllib.request
import zipfile

URL = "https://github.com/stasel/WebRTC/releases/download/156.0.0/WebRTC-M156-dSYM.zip"
SHA256 = "0d01da89de4740750b74503e2cc384af7ed37dd816151a250d7cf6996ea158ee"
BUNDLE = "WebRTC-macos-x86_64_arm64.dSYM"

def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()

def uuids(path):
    output = subprocess.check_output(["xcrun", "dwarfdump", "--uuid", str(path)], text=True)
    values = set(re.findall(r"UUID: ([0-9A-Fa-f-]{36})", output))
    if not values:
        raise RuntimeError("No Mach-O UUIDs in " + str(path))
    return {value.upper() for value in values}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--symbols-zip", type=Path)
    args = parser.parse_args()
    archive = args.archive.resolve(strict=True)
    apps = list((archive / "Products/Applications").glob("*.app"))
    if len(apps) != 1:
        raise RuntimeError("Expected one archived app")
    framework = apps[0] / "Contents/Frameworks/WebRTC.framework"
    info = plistlib.loads((framework / "Resources/Info.plist").read_bytes())
    executable = info["CFBundleExecutable"]
    if executable != Path(executable).name or executable in (".", ".."):
        raise RuntimeError("Invalid framework executable")
    expected = uuids(framework / executable)
    cache = Path(__file__).resolve().parents[1] / ".build/app-store-symbols"
    cache.mkdir(parents=True, exist_ok=True)
    source = args.symbols_zip or cache / "WebRTC-M156-dSYM.zip"
    if not source.exists():
        partial = source.with_suffix(".download")
        try:
            urllib.request.urlretrieve(URL, partial)
            if digest(partial) != SHA256:
                raise RuntimeError("Upstream symbol checksum mismatch")
            partial.replace(source)
        finally:
            partial.unlink(missing_ok=True)
    if digest(source) != SHA256:
        raise RuntimeError("Cached symbol checksum mismatch")
    with tempfile.TemporaryDirectory(prefix="noctcord-symbols-") as temp:
        stage = Path(temp)
        with zipfile.ZipFile(source) as zipped:
            for item in zipped.infolist():
                path = PurePosixPath(item.filename)
                if not path.parts or path.parts[0] != BUNDLE:
                    continue
                if path.is_absolute() or ".." in path.parts or stat.S_ISLNK(item.external_attr >> 16):
                    raise RuntimeError("Unsafe symbol archive entry")
                zipped.extract(item, stage)
        symbols = stage / BUNDLE
        available = uuids(symbols / "Contents/Resources/DWARF/WebRTC")
        if not expected.issubset(available):
            raise RuntimeError("WebRTC symbols do not match embedded binary: " + str(expected - available))
        destination = archive / "dSYMs" / BUNDLE
        shutil.copytree(symbols, destination, dirs_exist_ok=True)
    print("Verified and attached WebRTC symbols for " + ", ".join(sorted(expected)))

if __name__ == "__main__":
    main()
