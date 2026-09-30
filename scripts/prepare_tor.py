#!/usr/bin/env python3
"""Prepare the upstream Tor XCFramework for iOS/Xcode shallow-bundle rules."""

from pathlib import Path
import hashlib
import os
import plistlib
import shutil
import stat
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "Vendor" / "TorRuntime"
XCFRAMEWORK = RUNTIME / "tor.xcframework"

TOR_VERSION = "v409.13.1"
TOR_URL = f"https://github.com/iCepa/Tor.framework/releases/download/{TOR_VERSION}/tor.xcframework.zip"
TOR_SHA256 = "851174402abc8655273264f6b877a625648e52e6f9dd490b35e7cb94c2c924c6"

CACHE_DIR = Path.home() / "Library" / "Caches" / "VO1D-Messenger"
CACHE_ZIP = CACHE_DIR / f"tor-{TOR_VERSION}.xcframework.zip"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download_archive() -> Path:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    if CACHE_ZIP.is_file() and sha256(CACHE_ZIP) == TOR_SHA256:
        return CACHE_ZIP

    partial = CACHE_ZIP.with_suffix(CACHE_ZIP.suffix + ".download")
    partial.unlink(missing_ok=True)
    print(f"Downloading Tor runtime {TOR_VERSION} (first setup only)...")
    try:
        with urllib.request.urlopen(TOR_URL, timeout=120) as response, partial.open("wb") as output:
            shutil.copyfileobj(response, output, length=1024 * 1024)
    except Exception:
        partial.unlink(missing_ok=True)
        raise

    actual = sha256(partial)
    if actual != TOR_SHA256:
        partial.unlink(missing_ok=True)
        raise RuntimeError(f"Tor archive checksum mismatch: {actual}")

    partial.replace(CACHE_ZIP)
    return CACHE_ZIP


def safe_extract_with_symlinks(archive: Path, destination: Path) -> None:
    with zipfile.ZipFile(archive) as zf:
        for info in zf.infolist():
            relative = Path(info.filename)
            if relative.is_absolute() or ".." in relative.parts:
                raise RuntimeError(f"Unsafe path in Tor archive: {info.filename}")

            target = destination / relative
            mode = (info.external_attr >> 16) & 0xFFFF

            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue

            target.parent.mkdir(parents=True, exist_ok=True)
            if stat.S_ISLNK(mode):
                link_target = zf.read(info).decode("utf-8")
                target.unlink(missing_ok=True)
                os.symlink(link_target, target)
                continue

            with zf.open(info) as source, target.open("wb") as output:
                shutil.copyfileobj(source, output)

            permissions = mode & 0o777
            if permissions:
                target.chmod(permissions)


def copy_item(source: Path, destination: Path) -> None:
    if source.is_dir():
        shutil.copytree(source, destination, symlinks=True)
    else:
        shutil.copy2(source, destination, follow_symlinks=True)


def flatten_ios_framework(framework: Path) -> None:
    versions = framework / "Versions"
    if not versions.exists():
        if not (framework / "Info.plist").is_file():
            raise RuntimeError(f"Tor framework has no root Info.plist: {framework}")
        return

    version_dirs = sorted(path for path in versions.iterdir() if path.is_dir() and not path.is_symlink())
    if not version_dirs:
        raise RuntimeError(f"Tor framework has no concrete version directory: {framework}")

    source = version_dirs[0]
    replacement = framework.with_name(framework.name + ".vo1d-shallow")
    if replacement.exists():
        shutil.rmtree(replacement)
    replacement.mkdir(parents=True)

    for item in source.iterdir():
        if item.name == "Resources" and item.is_dir():
            for resource in item.iterdir():
                copy_item(resource, replacement / resource.name)
        else:
            copy_item(item, replacement / item.name)

    if not (replacement / "Info.plist").is_file():
        shutil.rmtree(replacement, ignore_errors=True)
        raise RuntimeError(f"Flattened Tor framework is missing Info.plist: {framework}")

    shutil.rmtree(framework)
    replacement.rename(framework)


def ios_slices_are_valid() -> bool:
    info_path = XCFRAMEWORK / "Info.plist"
    if not info_path.is_file():
        return False

    try:
        with info_path.open("rb") as handle:
            metadata = plistlib.load(handle)
        for library in metadata.get("AvailableLibraries", []):
            if library.get("SupportedPlatform") != "ios":
                continue
            framework = XCFRAMEWORK / library["LibraryIdentifier"] / library["LibraryPath"]
            if (framework / "Versions").exists() or not (framework / "Info.plist").is_file():
                return False
    except Exception:
        return False

    return True


def prepare() -> None:
    if ios_slices_are_valid():
        print("Tor runtime already prepared.")
        return

    archive = download_archive()
    with tempfile.TemporaryDirectory(prefix="vo1d-tor-") as temp_dir:
        temp = Path(temp_dir)
        safe_extract_with_symlinks(archive, temp)

        candidates = list(temp.glob("tor.xcframework"))
        if not candidates:
            candidates = list(temp.rglob("tor.xcframework"))
        if len(candidates) != 1:
            raise RuntimeError("Could not locate tor.xcframework in the downloaded archive")

        if XCFRAMEWORK.exists():
            shutil.rmtree(XCFRAMEWORK)
        shutil.copytree(candidates[0], XCFRAMEWORK, symlinks=True)

    with (XCFRAMEWORK / "Info.plist").open("rb") as handle:
        metadata = plistlib.load(handle)

    for library in metadata.get("AvailableLibraries", []):
        if library.get("SupportedPlatform") != "ios":
            continue
        framework = XCFRAMEWORK / library["LibraryIdentifier"] / library["LibraryPath"]
        flatten_ios_framework(framework)

    if not ios_slices_are_valid():
        shutil.rmtree(XCFRAMEWORK, ignore_errors=True)
        raise RuntimeError("Tor XCFramework preparation failed validation")

    print("Prepared Tor runtime with shallow iOS framework bundles.")


if __name__ == "__main__":
    prepare()
