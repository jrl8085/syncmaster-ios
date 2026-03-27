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
                     creation_date: Optional[str], sha256_client: str, size_bytes: int) -> tuple[dict, bool]:
    if existing := await manifest_db.find_by_identifier(identifier):
        return existing, True

    sha256 = hashlib.sha256(file_data).hexdigest()
    if sha256 != sha256_client:
        raise ValueError(f"SHA256 mismatch: client={sha256_client}, server={sha256}")

    if existing_hash := await manifest_db.find_by_sha256(sha256):
        record = await manifest_db.insert_file(identifier, filename, sha256, size_bytes,
                                                media_type, existing_hash["stored_path"], creation_date)
        return record, True

    dest_dir = _make_dest_dir(creation_date)
    dest = _unique_path(dest_dir, filename)
    dest.write_bytes(file_data)
    stored_path = str(dest.relative_to(get_storage_root()))
    record = await manifest_db.insert_file(identifier, filename, sha256, size_bytes,
                                            media_type, stored_path, creation_date)
    return record, False

def _make_dest_dir(creation_date: Optional[str]) -> Path:
    try:
        dt = datetime.fromisoformat(creation_date.rstrip("Z")) if creation_date else datetime.utcnow()
    except ValueError:
        dt = datetime.utcnow()
    d = get_storage_root() / f"{dt.year:04d}" / f"{dt.month:02d}" / f"{dt.day:02d}"
    d.mkdir(parents=True, exist_ok=True)
    return d

def _unique_path(directory: Path, filename: str) -> Path:
    stem, suffix = Path(filename).stem, Path(filename).suffix
    candidate = directory / filename
    i = 1
    while candidate.exists():
        candidate = directory / f"{stem}_{i}{suffix}"; i += 1
    return candidate
