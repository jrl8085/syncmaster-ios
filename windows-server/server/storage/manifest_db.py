import aiosqlite
from datetime import datetime
from typing import Optional
from ..config import DB_FILE

_DB = str(DB_FILE)

SCHEMA = """
CREATE TABLE IF NOT EXISTS files (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    identifier TEXT UNIQUE NOT NULL,
    filename TEXT NOT NULL,
    sha256 TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    media_type TEXT NOT NULL,
    stored_path TEXT NOT NULL,
    uploaded_at TEXT NOT NULL,
    creation_date TEXT
);
CREATE INDEX IF NOT EXISTS idx_id ON files(identifier);
CREATE INDEX IF NOT EXISTS idx_sha ON files(sha256);
CREATE TABLE IF NOT EXISTS sync_sessions (
    id TEXT PRIMARY KEY,
    started_at TEXT, completed_at TEXT,
    files_uploaded INTEGER DEFAULT 0,
    bytes_transferred INTEGER DEFAULT 0,
    skipped_duplicates INTEGER DEFAULT 0,
    errors INTEGER DEFAULT 0
);
"""

async def init_db():
    async with aiosqlite.connect(_DB) as db:
        await db.executescript(SCHEMA)
        await db.commit()

async def find_by_identifier(identifier: str) -> Optional[dict]:
    async with aiosqlite.connect(_DB) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute("SELECT * FROM files WHERE identifier=?", (identifier,)) as c:
            r = await c.fetchone()
            return dict(r) if r else None

async def find_by_sha256(sha256: str) -> Optional[dict]:
    async with aiosqlite.connect(_DB) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute("SELECT * FROM files WHERE sha256=?", (sha256,)) as c:
            r = await c.fetchone()
            return dict(r) if r else None

async def insert_file(identifier, filename, sha256, size_bytes, media_type, stored_path, creation_date=None) -> dict:
    ts = datetime.utcnow().isoformat() + "Z"
    async with aiosqlite.connect(_DB) as db:
        await db.execute(
            "INSERT OR REPLACE INTO files (identifier,filename,sha256,size_bytes,media_type,stored_path,uploaded_at,creation_date) VALUES (?,?,?,?,?,?,?,?)",
            (identifier, filename, sha256, size_bytes, media_type, stored_path, ts, creation_date))
        await db.commit()
    return {"identifier": identifier, "filename": filename, "sha256": sha256,
            "size_bytes": size_bytes, "uploaded_at": ts, "stored_path": stored_path}

async def get_manifest(since: Optional[str] = None) -> list[dict]:
    async with aiosqlite.connect(_DB) as db:
        db.row_factory = aiosqlite.Row
        q = "SELECT identifier,filename,sha256,size_bytes,uploaded_at FROM files" + (" WHERE uploaded_at>?" if since else "") + " ORDER BY uploaded_at"
        args = (since,) if since else ()
        async with db.execute(q, args) as c:
            return [dict(r) for r in await c.fetchall()]

async def get_total_count() -> int:
    async with aiosqlite.connect(_DB) as db:
        async with db.execute("SELECT COUNT(*) FROM files") as c:
            r = await c.fetchone(); return r[0] if r else 0

async def get_total_bytes() -> int:
    async with aiosqlite.connect(_DB) as db:
        async with db.execute("SELECT COALESCE(SUM(size_bytes),0) FROM files") as c:
            r = await c.fetchone(); return r[0] if r else 0

async def delete_file(identifier: str) -> bool:
    async with aiosqlite.connect(_DB) as db:
        c = await db.execute("DELETE FROM files WHERE identifier=?", (identifier,))
        await db.commit(); return c.rowcount > 0

async def insert_session(s: dict):
    async with aiosqlite.connect(_DB) as db:
        await db.execute(
            "INSERT OR REPLACE INTO sync_sessions (id,started_at,completed_at,files_uploaded,bytes_transferred,skipped_duplicates,errors) VALUES (:session_id,:started_at,:completed_at,:files_uploaded,:bytes_transferred,:skipped_duplicates,:errors)",
            s); await db.commit()

async def get_recent_sessions(limit=20) -> list[dict]:
    async with aiosqlite.connect(_DB) as db:
        db.row_factory = aiosqlite.Row
        async with db.execute("SELECT * FROM sync_sessions ORDER BY completed_at DESC LIMIT ?", (limit,)) as c:
            return [dict(r) for r in await c.fetchall()]
