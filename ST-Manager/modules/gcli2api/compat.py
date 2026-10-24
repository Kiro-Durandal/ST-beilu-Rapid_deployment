"""Offline compatibility and SQLite migration helpers for ST-Manager."""

import argparse
import asyncio
import json
import os
from pathlib import Path
import re
import sqlite3
import sys
import tempfile


def profile(root):
    root = Path(root)
    if (root / "src/storage/database.py").is_file():
        return "agy2api"
    if (root / "requirements-termux.txt").is_file():
        return "legacy"
    raise ValueError("Unrecognized upstream layout; current installation was not replaced")


def requirements(root, output):
    kind = profile(root)
    source = Path(root) / ("requirements.txt" if kind == "agy2api" else "requirements-termux.txt")
    pins = {
        "fastapi": os.environ["GCLI_EXPECT_FASTAPI"],
        "pydantic": os.environ["GCLI_EXPECT_PYDANTIC"],
    }
    if kind == "agy2api":
        pins.update(sqlalchemy="2.1.6", greenlet="3.5.6")
    result = []
    # Accept package specifiers only, never pip options, URLs or editable projects.
    pattern = re.compile(r"([A-Za-z0-9][A-Za-z0-9_.-]*)(?:\[[A-Za-z0-9_,.-]+\])?\s*([<>=!~0-9A-Za-z.,*+ -]*)")
    for line in source.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        match = pattern.fullmatch(line)
        if not match:
            raise ValueError("Unsupported dependency syntax; refusing an unreviewed installer directive")
        name = match[1].lower().replace("_", "-")
        if name == "asyncpg" or name in pins:
            continue
        result.append(line)
    result.extend(f"{name}=={version}" for name, version in pins.items())
    Path(output).write_text("\n".join(result) + "\n", encoding="utf-8")


def migrate(database):
    """Migrate a stopped service's COPIED SQLite DB; leave the backup untouched."""
    db = sqlite3.connect(database, timeout=30)
    db.row_factory = sqlite3.Row
    migrated = 0
    try:
        db.execute("BEGIN IMMEDIATE")
        columns = {row[1] for row in db.execute("PRAGMA table_info(antigravity_credentials)")}
        if "filename" in columns:
            if "credential_data" not in columns:
                raise ValueError("Unknown legacy credential schema; migration cancelled")
            rows = db.execute("SELECT * FROM antigravity_credentials ORDER BY id").fetchall()
            planned = []
            seen = set()
            for number, row in enumerate(rows, 1):
                try:
                    data = json.loads(row["credential_data"])
                    if not isinstance(data, dict):
                        raise ValueError
                    email = str(data.get("email") or (row["user_email"] if "user_email" in columns else "") or "").strip()
                    if not re.fullmatch(r"[^\s@]+@[^\s@]+", email) or not data.get("refresh_token"):
                        raise ValueError
                except (TypeError, ValueError, json.JSONDecodeError):
                    raise ValueError(f"Legacy credential row {number} lacks a valid email/refresh token; fix or export it in the old panel first") from None
                if email.casefold() in seen:
                    raise ValueError("Duplicate credential emails cannot be merged without losing data; resolve them in the old panel first")
                seen.add(email.casefold())

                def old(key, default):
                    return row[key] if key in columns and row[key] is not None else default

                planned.append((
                    email, str(data.get("access_token") or data.get("token") or ""),
                    str(data["refresh_token"]), str(data.get("client_id") or ""),
                    str(data.get("client_secret") or ""), str(data.get("project_id") or ""),
                    str(data.get("expiry") or ""), old("disabled", 0),
                    old("error_codes", "[]"), old("error_messages", "[]"),
                    old("last_success", None), old("model_cooldowns", "{}"),
                    old("tier", data.get("tier") or "pro"), old("created_at", 0), old("updated_at", 0),
                ))
            archive = "st_manager_legacy_antigravity_credentials"
            if db.execute("SELECT 1 FROM sqlite_master WHERE name=?", (archive,)).fetchone():
                raise ValueError("Legacy archive already exists; refusing to overwrite it")
            db.execute(f"ALTER TABLE antigravity_credentials RENAME TO {archive}")
            # The old index name must be released before upstream creates its index.
            db.execute("DROP INDEX IF EXISTS idx_ag_disabled")
            db.execute("""
                CREATE TABLE antigravity_credentials (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, email VARCHAR(320) NOT NULL UNIQUE,
                    access_token TEXT NOT NULL, refresh_token TEXT NOT NULL,
                    client_id TEXT NOT NULL, client_secret TEXT NOT NULL,
                    project_id TEXT NOT NULL, expiry TEXT NOT NULL, disabled BOOLEAN NOT NULL,
                    error_codes TEXT NOT NULL, error_messages TEXT NOT NULL,
                    last_success FLOAT, model_cooldowns TEXT NOT NULL, tier VARCHAR(32),
                    created_at FLOAT NOT NULL, updated_at FLOAT NOT NULL
                )
            """)
            db.executemany("""
                INSERT INTO antigravity_credentials (
                    email, access_token, refresh_token, client_id, client_secret, project_id,
                    expiry, disabled, error_codes, error_messages, last_success,
                    model_cooldowns, tier, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, planned)
            db.execute("CREATE INDEX idx_ag_disabled ON antigravity_credentials(disabled)")
            migrated = len(planned)
        elif columns and "email" not in columns:
            raise ValueError("Unknown credential schema; refusing to let upstream rebuild it")
        db.execute("CREATE TABLE IF NOT EXISTS config (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at REAL DEFAULT 0)")
        # HTTP body capture is explicitly out of scope. Keep upstream's opt-in off.
        db.execute("INSERT OR IGNORE INTO config(key, value) VALUES ('request_log_enabled', 'false')")
        db.commit()
        return migrated
    except BaseException:
        db.rollback()
        raise
    finally:
        db.close()


def smoke(root, startup=False):
    root = Path(root).resolve()
    kind = profile(root)
    import fastapi
    import pydantic
    if fastapi.__version__ != os.environ["GCLI_EXPECT_FASTAPI"]:
        raise RuntimeError("FastAPI version mismatch")
    if pydantic.__version__ != os.environ["GCLI_EXPECT_PYDANTIC"]:
        raise RuntimeError("Pydantic version mismatch")
    os.chdir(root)
    sys.path.insert(0, str(root))
    # Never let validation open/migrate the real credentials DB or contact Redis.
    with tempfile.TemporaryDirectory(prefix="st-manager-smoke-") as folder:
        os.environ.update(CREDENTIALS_DIR=folder, POSTGRESQL_URI="", MONGODB_URI="", REDIS_URL="")
        for name in ("API_PASSWORD", "PANEL_PASSWORD", "PASSWORD"):
            os.environ.pop(name, None)
        import web
        if kind == "agy2api":
            from src.models import GeminiRequest, model_to_dict
            data = model_to_dict(GeminiRequest(contents=[], extension={"preserved": True}))
            if data.get("extension") != {"preserved": True}:
                raise RuntimeError("Pydantic extra fields were lost")
            if not (root / "dist/index.html").is_file():
                raise RuntimeError("Missing compiled control panel; no frontend build will run on F50")
            if startup:
                asyncio.run(_startup_test(web))


async def _startup_test(web):
    import httpx
    from src.storage.database import get_database
    async with web.app.router.lifespan_context(web.app):
        database = await get_database()
        if database.backend_type != "sqlite":
            raise RuntimeError("Expected SQLite backend")
        await database.store_credential("smoke@example.invalid", {"refresh_token": "dummy-test-value"})
        if not await database.get_credential("smoke@example.invalid"):
            raise RuntimeError("Credential round-trip failed")
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=web.app), base_url="http://test") as client:
            response = await client.get("/")
            if response.status_code != 200 or 'id="root"' not in response.text:
                raise RuntimeError("Control panel failed to load")
            if (await client.get("/usage-logs/list")).status_code not in (401, 403):
                raise RuntimeError("Panel logs are not authenticated")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("profile", "smoke"):
        command = sub.add_parser(name)
        command.add_argument("root")
        if name == "smoke":
            command.add_argument("--startup", action="store_true")
    command = sub.add_parser("requirements")
    command.add_argument("root")
    command.add_argument("output")
    command = sub.add_parser("migrate")
    command.add_argument("database")
    args = parser.parse_args()
    try:
        if args.command == "profile":
            print(profile(args.root))
        elif args.command == "requirements":
            requirements(args.root, args.output)
        elif args.command == "migrate":
            print(f"Antigravity credentials migrated: {migrate(args.database)}")
        elif args.command == "smoke":
            smoke(args.root, args.startup)
    except Exception as error:
        print(f"[ERROR] {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
