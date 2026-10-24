import base64
import csv
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("native", ROOT / "ST-Manager/modules/gcli2api/native_wheels.py")
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


class NativeWheelTests(unittest.TestCase):
    def fixture(self, root):
        site = root / native.PREFIX / "lib/python3.14/site-packages"
        package = site / "greenlet"
        metadata = site / "greenlet-3.5.6.dist-info"
        package.mkdir(parents=True)
        metadata.mkdir()
        (package / "__init__.py").write_text("# fixture\n")
        header = bytearray(20)
        header[:6] = b"\x7fELF\x02\x01"
        header[18:20] = b"\xb7\x00"
        (package / "_greenlet.cpython-314-aarch64-linux-android.so").write_bytes(header)
        (metadata / "METADATA").write_text("Metadata-Version: 2.1\nName: greenlet\nVersion: 3.5.6\n")
        return package

    def assert_valid_record(self, wheel):
        with zipfile.ZipFile(wheel) as archive:
            wheel_metadata = archive.read("greenlet-3.5.6.dist-info/WHEEL").decode()
            self.assertIn("Tag: cp314-cp314-android_24_arm64_v8a", wheel_metadata)
            record = archive.read("greenlet-3.5.6.dist-info/RECORD").decode()
            for name, digest, length in csv.reader(io.StringIO(record)):
                if name.endswith("/RECORD"):
                    continue
                data = archive.read(name)
                self.assertEqual(len(data), int(length))
                expected = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
                self.assertEqual(digest, "sha256=" + expected)

    def test_pack_is_a_wheel_with_complete_hash_records(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            package = self.fixture(root)
            wheel = native.pack_greenlet(root, root)
            self.assert_valid_record(wheel)
            with zipfile.ZipFile(wheel) as archive:
                self.assertEqual(archive.read("greenlet/_greenlet.cpython-314-aarch64-linux-android.so"),
                                 (package / "_greenlet.cpython-314-aarch64-linux-android.so").read_bytes())

    def test_refuses_a_desktop_elf_binary(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            package = self.fixture(root)
            extension = next(package.glob("*.so"))
            data = bytearray(extension.read_bytes())
            data[18:20] = b"\x3e\x00"  # x86_64 is not the requested ARM64 target.
            extension.write_bytes(data)
            with self.assertRaises(ValueError):
                native.pack_greenlet(root, root)

    def test_apt_version_and_architecture_are_checked(self):
        record = "Package: python-greenlet\nVersion: 3.5.6\nArchitecture: aarch64\nSHA256: " + "a" * 64
        self.assertEqual(native.apt_metadata(record)["Version"], "3.5.6")
        for invalid in (record.replace("3.5.6", "3.5.7"), record.replace("aarch64", "x86_64"),
                        record.replace("python-greenlet", "another-package"), record.replace("SHA256:", "SHA1:")):
            with self.assertRaises(ValueError):
                native.apt_metadata(invalid)

    def test_corrupt_download_is_not_published(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(native.urllib.request, "urlopen", return_value=io.BytesIO(b"corrupt")):
            with self.assertRaises(ValueError):
                native.download_core(folder)
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_corrupt_cached_download_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder) / native.CORE_NAME
            target.write_bytes(b"untrusted")
            with self.assertRaises(ValueError), patch.object(native.urllib.request, "urlopen") as fetch:
                native.download_core(folder)
            fetch.assert_not_called()
            self.assertEqual(target.read_bytes(), b"untrusted")

    @unittest.skipUnless(os.environ.get("TERMUX_NATIVE_PAYLOAD"), "Set TERMUX_NATIVE_PAYLOAD for the real APT payload test")
    def test_real_termux_payload_repackages_without_changing_binary(self):
        payload = Path(os.environ["TERMUX_NATIVE_PAYLOAD"])
        with tempfile.TemporaryDirectory() as folder:
            wheel = native.pack_greenlet(payload, folder)
            self.assert_valid_record(wheel)
            path = native.PREFIX / "lib/python3.14/site-packages/greenlet/_greenlet.cpython-314-aarch64-linux-android.so"
            with zipfile.ZipFile(wheel) as archive:
                self.assertEqual(archive.read("greenlet/_greenlet.cpython-314-aarch64-linux-android.so"), (payload / path).read_bytes())


if __name__ == "__main__":
    unittest.main()
