import hashlib
import shutil
from datetime import datetime
from pathlib import Path
from typing import Optional
from ..config import get_config
from . import manifest_db

def get_storage_root() -> Path:
    p = Path(get_config()["storage_path"])
    p.mkdir(parents=True, exist_ok=True)
    return p

def get_free_bytes() -> int:
    return shutil.disk_usage(get_storage_root()).free

async def store_file(file_data: bytes, identifier: str, filename: str, media_type: str,
                     creation_date: Optional[str], sha256_client: str, size_bytes: int,
                     device_folder: str = "") -> tuple[dict, bool]:
    root = get_storage_root()

    # Dedup by identifier: only skip if the file actually exists on disk with the right size.
    if existing := await manifest_db.find_by_identifier(identifier, device_folder):
        stored = root / existing["stored_path"]
        if stored.exists() and stored.stat().st_size == existing["size_bytes"]:
            return existing, True
        # File is missing or corrupted — remove stale record and fall through to re-store.
        await manifest_db.delete_file(identifier, device_folder)

    sha256 = hashlib.sha256(file_data).hexdigest()
    if sha256 != sha256_client:
        raise ValueError(f"SHA256 mismatch: client={sha256_client}, server={sha256}")

    # Dedup by content hash: only reuse stored_path if the file is intact.
    if existing_hash := await manifest_db.find_by_sha256(sha256):
        stored = root / existing_hash["stored_path"]
        if stored.exists() and stored.stat().st_size == existing_hash["size_bytes"]:
            record = await manifest_db.insert_file(
                identifier, filename, sha256, size_bytes, media_type,
                existing_hash["stored_path"], creation_date, device_folder)
            return record, True

    dest_dir = _make_dest_dir(creation_date, device_folder)
    dest = _unique_path(dest_dir, filename)
    dest.write_bytes(file_data)
    stored_path = dest.relative_to(root).as_posix()  # always forward slashes
    record = await manifest_db.insert_file(
        identifier, filename, sha256, size_bytes, media_type,
        stored_path, creation_date, device_folder)
    return record, False

def _make_dest_dir(creation_date: Optional[str], device_folder: str = "") -> Path:
    try:
        dt = datetime.fromisoformat(creation_date.rstrip("Z")) if creation_date else datetime.utcnow()
    except ValueError:
        dt = datetime.utcnow()
    month_name = f"{dt.month} - {dt.strftime('%B')}"  # e.g. "1 - January"
    d = get_storage_root()
    if device_folder:
        d = d / device_folder
    d = d / f"{dt.year:04d}" / month_name
    d.mkdir(parents=True, exist_ok=True)
    return d

def _unique_path(directory: Path, filename: str) -> Path:
    stem, suffix = Path(filename).stem, Path(filename).suffix
    candidate = directory / filename
    i = 1
    while candidate.exists():
        candidate = directory / f"{stem}_{i}{suffix}"; i += 1
    return candidate
