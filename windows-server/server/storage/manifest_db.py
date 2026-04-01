import aiosqlite
from datetime import datetime
from typing import Optional
from ..config import DB_FILE

_DB = str(DB_FILE)

SCHEMA = """
CREATE TABLE IF NOT EXISTS files (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    identifier TEXT NOT NULL,
    device_folder TEXT NOT NULL DEFAULT '',
    filename TEXT NOT NULL,
    sha256 TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    media_type TEXT NOT NULL,
    stored_path TEXT NOT NULL,
    uploaded_at TEXT NOT NULL,
    creation_date TEXT,
    UNIQUE(identifier, device_folder)
);
CREATE INDEX IF NOT EXISTS idx_id ON files(identifier);
CREATE INDEX IF NOT EXISTS idx_dev ON files(device_folder);
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

_db: Optional[aiosqlite.Connection] = None


async def get_db() -> aiosqlite.Connection:
    global _db
    if _db is None:
        _db = await aiosqlite.connect(_DB)
        _db.row_factory = aiosqlite.Row
        await _db.execute("PRAGMA journal_mode=WAL")
        await _db.execute("PRAGMA busy_timeout=10000")
        await _db.commit()
    return _db


async def init_db():
    db = await get_db()
    # Migration: add device_folder column before running schema (which creates index on it).
    await db.execute(
        "CREATE TABLE IF NOT EXISTS files ("
        "id INTEGER PRIMARY KEY AUTOINCREMENT, identifier TEXT NOT NULL, filename TEXT NOT NULL, "
        "sha256 TEXT NOT NULL, size_bytes INTEGER NOT NULL, media_type TEXT NOT NULL, "
        "stored_path TEXT NOT NULL, uploaded_at TEXT NOT NULL, creation_date TEXT)"
    )
    await db.commit()
    try:
        await db.execute("ALTER TABLE files ADD COLUMN device_folder TEXT NOT NULL DEFAULT ''")
        await db.commit()
    except Exception:
        pass  # column already exists
    await db.executescript(SCHEMA)
    await db.commit()
    # Migration: flatten device subfolders — all records now use device_folder=''.
    # OR REPLACE handles the rare case where both ("id","") and ("id","iPhone") exist.
    await db.execute("UPDATE OR REPLACE files SET device_folder='' WHERE device_folder != ''")
    await db.commit()
    # Migration: normalize stored_path to forward slashes so index scans match on Windows.
    await db.execute("UPDATE files SET stored_path = REPLACE(stored_path, '\\', '/') WHERE stored_path LIKE '%\\%'")
    await db.commit()

async def find_by_identifier(identifier: str, device_folder: str = "") -> Optional[dict]:
    db = await get_db()
    async with db.execute(
        "SELECT * FROM files WHERE identifier=? AND device_folder=?",
        (identifier, device_folder)
    ) as c:
        r = await c.fetchone()
        return dict(r) if r else None

async def find_by_sha256(sha256: str) -> Optional[dict]:
    db = await get_db()
    async with db.execute("SELECT * FROM files WHERE sha256=?", (sha256,)) as c:
        r = await c.fetchone()
        return dict(r) if r else None

async def insert_file(identifier, filename, sha256, size_bytes, media_type, stored_path,
                      creation_date=None, device_folder: str = "") -> dict:
    ts = datetime.utcnow().isoformat() + "Z"
    db = await get_db()
    await db.execute(
        "INSERT OR REPLACE INTO files "
        "(identifier,device_folder,filename,sha256,size_bytes,media_type,stored_path,uploaded_at,creation_date) "
        "VALUES (?,?,?,?,?,?,?,?,?)",
        (identifier, device_folder, filename, sha256, size_bytes, media_type, stored_path, ts, creation_date))
    await db.commit()
    return {"identifier": identifier, "filename": filename, "sha256": sha256,
            "size_bytes": size_bytes, "uploaded_at": ts, "stored_path": stored_path}

async def get_manifest(since: Optional[str] = None, device_folder: str = "") -> list[dict]:
    db = await get_db()
    conditions = ["device_folder=?"]
    args: list = [device_folder]
    if since:
        conditions.append("uploaded_at>?")
        args.append(since)
    where = " WHERE " + " AND ".join(conditions)
    q = f"SELECT identifier,filename,sha256,size_bytes,uploaded_at FROM files{where} ORDER BY uploaded_at"
    async with db.execute(q, args) as c:
        return [dict(r) for r in await c.fetchall()]

async def get_stored_paths(device_folder: str = "") -> set[str]:
    """Return the set of stored_path values already in the manifest for a device folder.
    Always returns forward-slash paths for consistent comparison with as_posix() scans."""
    db = await get_db()
    async with db.execute(
        "SELECT stored_path FROM files WHERE device_folder=?", (device_folder,)
    ) as c:
        return {r[0].replace("\\", "/") for r in await c.fetchall()}

async def get_all_device_folders() -> list[str]:
    """Return distinct device_folder values currently in the manifest."""
    db = await get_db()
    async with db.execute("SELECT DISTINCT device_folder FROM files") as c:
        return [r[0] for r in await c.fetchall()]

async def get_total_count() -> int:
    db = await get_db()
    async with db.execute("SELECT COUNT(*) FROM files") as c:
        r = await c.fetchone(); return r[0] if r else 0

async def get_total_bytes() -> int:
    db = await get_db()
    async with db.execute("SELECT COALESCE(SUM(size_bytes),0) FROM files") as c:
        r = await c.fetchone(); return r[0] if r else 0

async def delete_file(identifier: str, device_folder: str = "") -> bool:
    db = await get_db()
    c = await db.execute(
        "DELETE FROM files WHERE identifier=? AND device_folder=?",
        (identifier, device_folder))
    await db.commit(); return c.rowcount > 0

async def insert_session(s: dict):
    db = await get_db()
    await db.execute(
        "INSERT OR REPLACE INTO sync_sessions (id,started_at,completed_at,files_uploaded,bytes_transferred,skipped_duplicates,errors) VALUES (:session_id,:started_at,:completed_at,:files_uploaded,:bytes_transferred,:skipped_duplicates,:errors)",
        s); await db.commit()

async def reconcile_with_filesystem(storage_path, device_folder: str = "") -> int:
    """Remove manifest entries whose files are missing or have a size mismatch on disk.
    Size mismatch indicates a corrupted or truncated write; removing the entry forces
    the iOS client to re-upload the file on the next sync. Returns pruned count."""
    from pathlib import Path
    base = Path(storage_path)
    db = await get_db()
    async with db.execute(
        "SELECT identifier, stored_path, size_bytes FROM files WHERE device_folder=?",
        (device_folder,)
    ) as c:
        rows = [dict(r) for r in await c.fetchall()]
    stale = []
    for r in rows:
        path = base / r["stored_path"]
        if not path.exists():
            stale.append((r["identifier"], device_folder))
        elif path.stat().st_size != r["size_bytes"]:
            stale.append((r["identifier"], device_folder))
    if stale:
        await db.executemany(
            "DELETE FROM files WHERE identifier=? AND device_folder=?", stale)
        await db.commit()
    return len(stale)

async def reset_manifest(device_folder: Optional[str] = None):
    db = await get_db()
    if device_folder is not None:
        await db.execute("DELETE FROM files WHERE device_folder=?", (device_folder,))
    else:
        await db.execute("DELETE FROM files")
    await db.commit()

async def get_recent_sessions(limit=20) -> list[dict]:
    db = await get_db()
    async with db.execute("SELECT * FROM sync_sessions ORDER BY completed_at DESC LIMIT ?", (limit,)) as c:
        return [dict(r) for r in await c.fetchall()]
