#!/usr/bin/env python3
"""Prepare the pinned libsignal Swift package and official prebuilt iOS FFI archive."""

from pathlib import Path
import hashlib
import os
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SIGNAL_ROOT = ROOT / "Vendor" / "libsignal"
SIGNAL_PACKAGE = SIGNAL_ROOT / "swift" / "Package.swift"

EXPECTED_COMMIT = "efe13e9b363d2c115dba61b76e5e53bbfc2874bc"
SIGNAL_TAG = "v0.70.0"
ARCHIVE_NAME = "libsignal-client-ios-build-v0.70.0.tar.gz"
ARCHIVE_URL = f"https://build-artifacts.signal.org/libraries/{ARCHIVE_NAME}"
CHECKSUM_URL = (
    "https://github.com/signalapp/libsignal/releases/download/"
    f"{SIGNAL_TAG}/{ARCHIVE_NAME}.sha256"
)

CACHE_DIR = Path.home() / "Library" / "Caches" / "VO1D-Messenger"
CACHE_ARCHIVE = CACHE_DIR / ARCHIVE_NAME
CACHE_CHECKSUM = CACHE_DIR / f"{ARCHIVE_NAME}.sha256"


def run(*args: str, cwd: Path | None = None) -> str:
    result = subprocess.run(
        list(args),
        cwd=str(cwd) if cwd else None,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    return result.stdout.strip()


def ensure_submodule() -> None:
    if not SIGNAL_PACKAGE.is_file():
        print("Initializing pinned libsignal submodule...")
        subprocess.run(
            [
                "git",
                "submodule",
                "update",
                "--init",
                "--recursive",
                "--depth",
                "1",
                "Vendor/libsignal",
            ],
            cwd=ROOT,
            check=True,
        )

    if not SIGNAL_PACKAGE.is_file():
        raise RuntimeError("libsignal submodule was not initialized correctly")

    actual = run("git", "rev-parse", "HEAD", cwd=SIGNAL_ROOT)
    if actual != EXPECTED_COMMIT:
        print(f"Resetting libsignal to pinned commit {EXPECTED_COMMIT[:12]}...")
        subprocess.run(
            ["git", "fetch", "--depth", "1", "origin", EXPECTED_COMMIT],
            cwd=SIGNAL_ROOT,
            check=True,
        )
        subprocess.run(
            ["git", "checkout", "--detach", EXPECTED_COMMIT],
            cwd=SIGNAL_ROOT,
            check=True,
        )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url: str, destination: Path) -> None:
    partial = destination.with_suffix(destination.suffix + ".download")
    partial.unlink(missing_ok=True)
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "VO1D-Messenger dependency bootstrap"},
    )
    try:
        with urllib.request.urlopen(request, timeout=180) as response, partial.open("wb") as output:
            shutil.copyfileobj(response, output, length=1024 * 1024)
    except Exception:
        partial.unlink(missing_ok=True)
        raise
    partial.replace(destination)


def official_checksum() -> str:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    try:
        download(CHECKSUM_URL, CACHE_CHECKSUM)
    except Exception:
        if not CACHE_CHECKSUM.is_file():
            raise

    text = CACHE_CHECKSUM.read_text(errors="replace")
    match = re.search(r"\b([0-9a-fA-F]{64})\b", text)
    if not match:
        raise RuntimeError("Official libsignal checksum file is invalid")
    return match.group(1).lower()


def ensure_archive() -> Path:
    expected = official_checksum()
    if CACHE_ARCHIVE.is_file() and sha256(CACHE_ARCHIVE) == expected:
        return CACHE_ARCHIVE

    print("Downloading official libsignal iOS prebuilt archive (first setup only)...")
    download(ARCHIVE_URL, CACHE_ARCHIVE)
    actual = sha256(CACHE_ARCHIVE)
    if actual != expected:
        CACHE_ARCHIVE.unlink(missing_ok=True)
        raise RuntimeError(
            f"libsignal archive checksum mismatch: expected {expected}, got {actual}"
        )
    return CACHE_ARCHIVE


def read_archive_member(tar: tarfile.TarFile, suffix: str) -> bytes:
    matches = [
        member for member in tar.getmembers()
        if member.isfile() and member.name.endswith(suffix)
    ]
    if len(matches) != 1:
        raise RuntimeError(f"Expected one libsignal archive member ending with {suffix}")
    handle = tar.extractfile(matches[0])
    if handle is None:
        raise RuntimeError(f"Unable to read {matches[0].name}")
    return handle.read()


def write_artifact(data: bytes, platform_name: str, configuration: str) -> Path:
    destination = SIGNAL_ROOT / "artifacts" / platform_name / configuration / "libsignal_ffi.a"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
    return destination


def artifacts_ready() -> bool:
    needed = [
        SIGNAL_ROOT / "artifacts" / "iphoneos" / "Debug" / "libsignal_ffi.a",
        SIGNAL_ROOT / "artifacts" / "iphoneos" / "Release" / "libsignal_ffi.a",
        SIGNAL_ROOT / "artifacts" / "iphonesimulator" / "Debug" / "libsignal_ffi.a",
        SIGNAL_ROOT / "artifacts" / "iphonesimulator" / "Release" / "libsignal_ffi.a",
    ]
    return all(path.is_file() and path.stat().st_size > 1024 for path in needed)


def prepare_artifacts() -> None:
    if artifacts_ready():
        print("libsignal package and iOS FFI artifacts already prepared.")
        return

    archive = ensure_archive()
    with tarfile.open(archive, "r:gz") as tar:
        device = read_archive_member(
            tar, "target/aarch64-apple-ios/release/libsignal_ffi.a"
        )

        machine = platform.machine().lower()
        if machine in {"x86_64", "amd64"}:
            simulator_suffix = "target/x86_64-apple-ios/release/libsignal_ffi.a"
        else:
            simulator_suffix = "target/aarch64-apple-ios-sim/release/libsignal_ffi.a"
        simulator = read_archive_member(tar, simulator_suffix)

    write_artifact(device, "iphoneos", "Debug")
    write_artifact(device, "iphoneos", "Release")
    write_artifact(simulator, "iphonesimulator", "Debug")
    write_artifact(simulator, "iphonesimulator", "Release")
    print("Prepared official libsignal FFI artifacts for device and simulator.")


def main() -> None:
    ensure_submodule()
    prepare_artifacts()


if __name__ == "__main__":
    main()
