"""Prepare Android ARM64 wheels without running a compiler or installing packages."""

import argparse
import base64
import csv
from email.parser import Parser
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile


GREENLET_VERSION = "3.5.6"
CORE_VERSION = "2.50.1"
CORE_NAME = f"pydantic_core-{CORE_VERSION}-cp314-cp314-android_24_arm64_v8a.whl"
CORE_URL = f"https://github.com/tur-pypi-dists/python3.14-pydantic_core/releases/download/v{CORE_VERSION}/{CORE_NAME}"
CORE_SHA256 = "fe42631897c1afe1f9cbad38a30ae16bc5ef0cf36532a37750099cdb5da0e839"
PREFIX = Path("data/data/com.termux/files/usr")
TAG = "cp314-cp314-android_24_arm64_v8a"


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download_core(destination):
    target = Path(destination) / CORE_NAME
    if target.exists():
        if sha256(target) != CORE_SHA256:
            raise ValueError("Existing Pydantic Core wheel has a different hash; it was not overwritten")
        return target
    fd, temporary = tempfile.mkstemp(prefix=".pydantic-core-", dir=destination)
    try:
        with os.fdopen(fd, "wb") as output, urllib.request.urlopen(CORE_URL, timeout=60) as response:
            size = 0
            for chunk in iter(lambda: response.read(65536), b""):
                size += len(chunk)
                if size > 32 * 1024 * 1024:
                    raise ValueError("Native wheel exceeds expected size")
                output.write(chunk)
        if sha256(temporary) != CORE_SHA256:
            raise ValueError("Pydantic Core SHA-256 verification failed")
        os.replace(temporary, target)
        os.chmod(target, 0o600)
        return target
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def apt_metadata(text):
    record = {}
    for line in text.strip().split("\n\n", 1)[0].splitlines():
        if ": " in line and not line.startswith(" "):
            key, value = line.split(": ", 1)
            record[key] = value
    version = record.get("Version", "")
    if record.get("Package") != "python-greenlet":
        raise ValueError("APT metadata is not for python-greenlet")
    if version.split("-", 1)[0] != GREENLET_VERSION:
        raise ValueError(f"APT's python-greenlet version is {version or 'unknown'}, expected {GREENLET_VERSION}; no package was installed")
    if record.get("Architecture") != "aarch64" or not re.fullmatch(r"[0-9a-f]{64}", record.get("SHA256", "")):
        raise ValueError("APT metadata does not identify a hashed aarch64 package")
    return record


def verify_extension(path):
    if "cpython-314" not in path.name:
        raise ValueError("Greenlet extension was not built for CPython 3.14")
    with path.open("rb") as source:
        header = source.read(20)
    if header[:6] != b"\x7fELF\x02\x01" or header[18:20] != b"\xb7\x00":
        raise ValueError("Greenlet extension is not an ARM64 ELF binary")


def pack_greenlet(payload, destination):
    """Repackage authenticated Termux package payload, not a desktop Linux wheel."""
    site = Path(payload) / PREFIX / "lib/python3.14/site-packages"
    package = site / "greenlet"
    metadata = site / f"greenlet-{GREENLET_VERSION}.dist-info"
    if not package.is_dir() or not metadata.is_dir():
        raise ValueError("Termux package does not contain the expected Python 3.14 greenlet files")
    info = Parser().parsestr((metadata / "METADATA").read_text(encoding="utf-8"))
    if info.get("Name", "").lower() != "greenlet" or info["Version"] != GREENLET_VERSION:
        raise ValueError("Greenlet distribution metadata does not match the pinned version")
    extensions = list(package.glob("_greenlet*.so"))
    if len(extensions) != 1:
        raise ValueError("Expected exactly one compiled greenlet extension")
    verify_extension(extensions[0])
    members = {}
    for folder in (package, metadata):
        for path in sorted(folder.rglob("*")):
            if path.is_symlink():
                raise ValueError("Refusing a symlink in the native package payload")
            if not path.is_file() or "__pycache__" in path.parts or path.suffix == ".pyc":
                continue
            name = path.relative_to(site).as_posix()
            if path.name in ("RECORD", "WHEEL", "RECORD.jws", "RECORD.p7s") and path.parent == metadata:
                continue
            members[name] = path
    # Preserve the package's redistributed licence notices, when shipped outside site-packages.
    docs = Path(payload) / PREFIX / "share/doc/python-greenlet"
    if docs.is_dir():
        for path in sorted(docs.rglob("*")):
            if path.is_file() and not path.is_symlink():
                members[f"{metadata.name}/licenses/termux/{path.relative_to(docs).as_posix()}"] = path
    wheel_name = f"greenlet-{GREENLET_VERSION}-{TAG}.whl"
    wheel = Path(destination) / wheel_name
    fd, temporary = tempfile.mkstemp(prefix=".greenlet-", dir=destination)
    os.close(fd)
    rows = []
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, path in sorted(members.items()):
                digest = hashlib.sha256()
                with archive.open(name, "w") as output, path.open("rb") as source:
                    for chunk in iter(lambda: source.read(65536), b""):
                        output.write(chunk)
                        digest.update(chunk)
                rows.append((name, "sha256=" + base64.urlsafe_b64encode(digest.digest()).rstrip(b"=").decode(), path.stat().st_size))
            name = f"{metadata.name}/WHEEL"
            data = f"Wheel-Version: 1.0\nGenerator: ST-Manager Termux package repack\nRoot-Is-Purelib: false\nTag: {TAG}\n".encode()
            archive.writestr(name, data)
            digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
            rows.append((name, "sha256=" + digest, len(data)))
            record_name = f"{metadata.name}/RECORD"
            rows.append((record_name, "", ""))
            record = io.StringIO(newline="")
            csv.writer(record).writerows(rows)
            archive.writestr(record_name, record.getvalue())
        os.replace(temporary, wheel)
        os.chmod(wheel, 0o600)
        return wheel
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def prepare(destination):
    if sys.version_info[:2] != (3, 14) or platform.machine() not in ("aarch64", "arm64"):
        raise ValueError("This package preparation supports only CPython 3.14 / Android ARM64")
    if os.environ.get("PREFIX") != "/data/data/com.termux/files/usr":
        raise ValueError("Expected the standard Termux prefix")
    for command in ("apt-cache", "apt-get", "dpkg-deb"):
        if not shutil.which(command):
            raise ValueError(f"Missing command: {command}")
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    os.chmod(destination, 0o700)
    output = subprocess.run(["apt-cache", "show", "--no-all-versions", "python-greenlet"],
                            check=True, capture_output=True, text=True).stdout
    record = apt_metadata(output)
    print("Downloading the precompiled python-greenlet APT package; no installation or compilation.")
    with tempfile.TemporaryDirectory(prefix=".native-prepare-", dir=destination) as temporary:
        subprocess.run(["apt-get", "download", f"python-greenlet={record['Version']}"], cwd=temporary, check=True)
        packages = list(Path(temporary).glob("*.deb"))
        if len(packages) != 1 or sha256(packages[0]) != record["SHA256"]:
            raise ValueError("Downloaded Termux package does not match authenticated APT metadata")
        payload = Path(temporary) / "payload"
        subprocess.run(["dpkg-deb", "--extract", str(packages[0]), str(payload)], check=True)
        greenlet = pack_greenlet(payload, destination)
    print("Downloading the pinned TUR Pydantic Core wheel and checking SHA-256.")
    core = download_core(destination)
    manifest = {
        "managed_by": "ST-Manager", "target": TAG,
        "greenlet": {"file": greenlet.name, "sha256": sha256(greenlet),
                     "deb_version": record["Version"], "deb_sha256": record["SHA256"]},
        "pydantic_core": {"file": core.name, "sha256": CORE_SHA256, "url": CORE_URL},
    }
    (destination / "st-manager-native-sources.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Prepared native wheels in {destination}. Run the non-stopping dependency check next.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("destination")
    args = parser.parse_args()
    try:
        prepare(args.destination)
    except Exception as error:
        print(f"[ERROR] {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
