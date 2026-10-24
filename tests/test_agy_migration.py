import importlib.util
from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("compat", ROOT / "ST-Manager/modules/gcli2api/compat.py")
compat = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compat)


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.db = self.root / "credentials.db"
        with closing(sqlite3.connect(self.db)) as db, db:
            db.execute("""CREATE TABLE antigravity_credentials (
                id INTEGER PRIMARY KEY, filename TEXT UNIQUE, credential_data TEXT,
                user_email TEXT, disabled INTEGER, tier TEXT, model_cooldowns TEXT
            )""")
            db.execute("CREATE INDEX idx_ag_disabled ON antigravity_credentials(disabled)")
            db.execute("CREATE TABLE config(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            db.execute("INSERT INTO config VALUES ('panel_password', ?)", (json.dumps("existing-password"),))
            db.execute("CREATE TABLE credentials(filename TEXT, credential_data TEXT)")
            db.execute("INSERT INTO credentials VALUES ('geminicli.json', '{}')")

    def add_credential(self, email="one@example.invalid", token="refresh-value", disabled=1):
        with closing(sqlite3.connect(self.db)) as db, db:
            number = db.execute("SELECT count(*) FROM antigravity_credentials").fetchone()[0]
            db.execute("INSERT INTO antigravity_credentials VALUES (?, ?, ?, ?, ?, ?, ?)", (
                number + 1, f"legacy-{number}.json",
                json.dumps({"refresh_token": token, "token": "access-value", "project_id": "test-project"}),
                email, disabled, "ultra", '{"claude":1234567890}',
            ))

    def test_preserves_credentials_password_and_legacy_archive(self):
        self.add_credential()
        self.assertEqual(compat.migrate(self.db), 1)
        with closing(sqlite3.connect(self.db)) as db, db:
            row = db.execute("SELECT email, refresh_token, access_token, disabled, tier, model_cooldowns FROM antigravity_credentials").fetchone()
            self.assertEqual(row, ("one@example.invalid", "refresh-value", "access-value", 1, "ultra", '{"claude":1234567890}'))
            self.assertEqual(db.execute("SELECT count(*) FROM st_manager_legacy_antigravity_credentials").fetchone()[0], 1)
            self.assertEqual(db.execute("SELECT value FROM config WHERE key='panel_password'").fetchone()[0], json.dumps("existing-password"))
            self.assertEqual(db.execute("SELECT value FROM config WHERE key='request_log_enabled'").fetchone()[0], "false")
            self.assertEqual(db.execute("SELECT count(*) FROM credentials").fetchone()[0], 1)
        self.assertEqual(compat.migrate(self.db), 0)

    def test_missing_email_rolls_back(self):
        self.add_credential(email="")
        self.assert_migration_refused()

    def test_missing_refresh_token_rolls_back(self):
        self.add_credential(token="")
        self.assert_migration_refused()

    def test_duplicate_email_does_not_silently_discard_an_account(self):
        self.add_credential()
        self.add_credential(email="ONE@example.invalid")
        self.assert_migration_refused()

    def test_malformed_json_rolls_back(self):
        self.add_credential()
        with closing(sqlite3.connect(self.db)) as db, db:
            db.execute("UPDATE antigravity_credentials SET credential_data='not JSON'")
        self.assert_migration_refused()

    def assert_migration_refused(self):
        before = self.db.read_bytes()
        with self.assertRaises(ValueError):
            compat.migrate(self.db)
        self.assertEqual(self.db.read_bytes(), before)
        with closing(sqlite3.connect(self.db)) as db, db:
            columns = {row[1] for row in db.execute("PRAGMA table_info(antigravity_credentials)")}
            self.assertIn("filename", columns)
            self.assertNotIn("email", columns)

    def test_new_install_and_modern_database_are_idempotent(self):
        new_db = self.root / "new.db"
        self.assertEqual(compat.migrate(new_db), 0)
        self.assertEqual(compat.migrate(new_db), 0)


class RequirementsTests(unittest.TestCase):
    def test_modern_profile_excludes_asyncpg_and_pins_native_dependencies(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "src/storage").mkdir(parents=True)
            (root / "src/storage/database.py").touch()
            (root / "requirements.txt").write_text("fastapi>=0.116.1\npydantic>=2.11.7\nSQLAlchemy[asyncio]>=2.0.30\ngreenlet>=3.0.0\nasyncpg\naiosqlite>=0.20.0\n")
            output = root / "resolved.txt"
            with patch.dict(os.environ, GCLI_EXPECT_FASTAPI="0.162.0", GCLI_EXPECT_PYDANTIC="2.14.1"):
                compat.requirements(root, output)
            self.assertEqual(output.read_text().splitlines(), [
                "aiosqlite>=0.20.0", "fastapi==0.162.0", "pydantic==2.14.1", "sqlalchemy[asyncio]==2.1.6",
                "greenlet==3.5.6", "pydantic-core==2.50.1",
            ])

    def modern_fixture(self, folder, line):
        root = Path(folder)
        (root / "src/storage").mkdir(parents=True)
        (root / "src/storage/database.py").touch()
        (root / "requirements.txt").write_text(line + "\n")
        return root

    def test_upstream_native_or_framework_version_conflicts_are_not_overridden(self):
        for line in ("pydantic>=2.15", "pydantic-core>=2.51", "greenlet>=3.6", "SQLAlchemy<2.1", "fastapi!=0.162.0"):
            with self.subTest(line=line), tempfile.TemporaryDirectory() as folder:
                root = self.modern_fixture(folder, line)
                output = root / "resolved.txt"
                output.write_text("previous requirements\n")
                with patch.dict(os.environ, GCLI_EXPECT_FASTAPI="0.162.0", GCLI_EXPECT_PYDANTIC="2.14.1"):
                    with self.assertRaisesRegex(ValueError, "incompatible"):
                        compat.requirements(root, output)
                self.assertEqual(output.read_text(), "previous requirements\n")

    def test_compatible_bounds_and_duplicate_extras_are_preserved(self):
        with tempfile.TemporaryDirectory() as folder:
            root = self.modern_fixture(folder, "pydantic[email]>=2.11,<3\npydantic>=2.12\nFastAPI~=0.162.0")
            output = root / "resolved.txt"
            with patch.dict(os.environ, GCLI_EXPECT_FASTAPI="0.162.0", GCLI_EXPECT_PYDANTIC="2.14.1"):
                compat.requirements(root, output)
            self.assertIn("pydantic[email]==2.14.1", output.read_text().splitlines())
            self.assertEqual(output.read_text().count("pydantic["), 1)

    def test_legacy_pydantic_patch_override_remains_supported(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "requirements-termux.txt").write_text("pydantic==1.10.22\n")
            output = root / "resolved.txt"
            with patch.dict(os.environ, GCLI_EXPECT_FASTAPI="0.118.3", GCLI_EXPECT_PYDANTIC="1.10.26"):
                compat.requirements(root, output)
            self.assertIn("pydantic==1.10.26", output.read_text().splitlines())

    def test_rejects_installer_directives(self):
        for line in ("-r other.txt", "--extra-index-url https://untrusted.invalid", "pkg @ https://untrusted.invalid/pkg.whl", "-e ."):
            with self.subTest(line=line), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                (root / "requirements-termux.txt").write_text(line)
                with patch.dict(os.environ, GCLI_EXPECT_FASTAPI="0.118.3", GCLI_EXPECT_PYDANTIC="1.10.26"):
                    with self.assertRaises(ValueError):
                        compat.requirements(root, root / "out.txt")


if __name__ == "__main__":
    unittest.main()
