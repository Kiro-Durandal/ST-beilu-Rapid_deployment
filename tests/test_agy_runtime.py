"""Optional integration tests against a downloaded, pinned upstream checkout."""

import asyncio
from contextlib import closing
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("compat", ROOT / "ST-Manager/modules/gcli2api/compat.py")
compat = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compat)


@unittest.skipUnless(os.environ.get("AGY_UPSTREAM_ROOT"), "Set AGY_UPSTREAM_ROOT to the reviewed upstream checkout")
class RuntimeTests(unittest.TestCase):
    def test_application_startup_and_panel(self):
        compat.smoke(os.environ["AGY_UPSTREAM_ROOT"], startup=True)

    def test_migrated_database_opens_without_upstream_rebuilding_credentials(self):
        upstream = Path(os.environ["AGY_UPSTREAM_ROOT"]).resolve()
        sys.path.insert(0, str(upstream))
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "credentials.db"
            with closing(sqlite3.connect(path)) as db, db:
                db.execute("CREATE TABLE antigravity_credentials(id INTEGER PRIMARY KEY, filename TEXT, credential_data TEXT, user_email TEXT)")
                db.execute("INSERT INTO antigravity_credentials VALUES (1, 'test.json', ?, 'test@example.invalid')", (json.dumps({"refresh_token": "synthetic-refresh"}),))
            self.assertEqual(compat.migrate(path), 1)

            async def verify():
                from src.storage.database import Database
                database = Database()
                try:
                    await database.initialize()
                    self.assertEqual(await database.list_credentials(), ["test@example.invalid"])
                    record = await database.get_credential("test@example.invalid")
                    self.assertEqual(record["refresh_token"], "synthetic-refresh")
                    self.assertFalse(await database.get_config("request_log_enabled", True))
                finally:
                    await database.close()

            with patch.dict(os.environ, CREDENTIALS_DIR=folder, POSTGRESQL_URI="", MONGODB_URI=""):
                asyncio.run(verify())
            with closing(sqlite3.connect(path)) as db:
                self.assertEqual(db.execute("SELECT count(*) FROM st_manager_legacy_antigravity_credentials").fetchone()[0], 1)


if __name__ == "__main__":
    unittest.main()
