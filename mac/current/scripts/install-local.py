#!/usr/bin/env python3
"""Install a signed local build at the configured application path."""

import argparse
import ctypes
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / ".local-install-path"


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def bundle_info(app):
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundleIdentifier") != "local.leaf.pdfreader" or info.get("CFBundleExecutable") != "LeafReader":
        raise ValueError(f"Not a Margin application: {app}")
    return info


def version_key(info):
    parts = []
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        value = info.get(key, "")
        if not re.fullmatch(r"\d+(?:\.\d+){0,3}", value):
            raise ValueError(f"Unsupported {key}: {value}")
        numbers = tuple(map(int, value.split(".")))
        parts.append(numbers + (0,) * (4 - len(numbers)))
    return tuple(parts)


def verify(app):
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))


def require_stopped():
    # Refuse to interrupt reading or replace code used by a running instance.
    commands = run("/bin/ps", "-axo", "comm=").splitlines()
    if any(command.strip().endswith("/Contents/MacOS/LeafReader") for command in commands):
        raise ValueError("Quit Margin normally, then rerun scripts/install-local.py. The installed app was not changed.")


def swap(first, second):
    # macOS exchanges both directory entries atomically on the same volume.
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    rename = library.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(first), os.fsencode(second), 0x00000002) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def install(source, destination):
    source = source.resolve()
    destination = destination.expanduser()
    if not destination.is_absolute() or destination.suffix != ".app" or destination.is_symlink():
        raise ValueError("The installation path must be an absolute, non-symlink .app path.")
    destination = destination.resolve()
    if source == destination or source in destination.parents or destination in source.parents:
        raise ValueError("Build and installation paths must be separate.")
    info = bundle_info(source)
    verify(source)
    require_stopped()
    if destination.exists() and version_key(info) < version_key(bundle_info(destination)):
        raise ValueError("Refusing to replace a newer installed version with an older build.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".margin-install-", dir=destination.parent) as directory:
        staged = Path(directory) / "Margin.app"
        run("/usr/bin/ditto", str(source), str(staged))
        verify(staged)
        require_stopped()
        if destination.exists():
            # Retain the previous bundle until the installed copy passes verification.
            swap(staged, destination)
            try:
                verify(destination)
            except BaseException:
                swap(staged, destination)
                raise
        else:
            staged.rename(destination)
        print(f"Installed Margin {info['CFBundleShortVersionString']}: {destination}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / "Margin.app")
    parser.add_argument("--destination", type=Path)
    args = parser.parse_args()
    destination = args.destination
    if destination is None:
        if not CONFIG.is_file():
            raise ValueError("Set .local-install-path to the absolute path of your installed Margin.app.")
        destination = Path(CONFIG.read_text().strip())
    install(args.source, destination)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        detail = error.stderr.strip() if isinstance(error, subprocess.CalledProcessError) else str(error)
        print(f"Installation failed: {detail}", file=sys.stderr)
        sys.exit(1)
