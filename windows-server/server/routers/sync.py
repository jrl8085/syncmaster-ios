from datetime import datetime
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException
from ..auth import verify_api_key
from ..config import get_config
from ..storage import manifest_db, file_store

router = APIRouter(dependencies=[Depends(verify_api_key)])

@router.get("/manifest")
async def get_manifest(since: Optional[str] = None, device_folder: str = ""):
    files = await manifest_db.get_manifest(since=since, device_folder=device_folder)
    return {"count": len(files), "generated_at": datetime.utcnow().isoformat() + "Z", "files": files}

@router.delete("/manifest")
async def reset_manifest(device_folder: Optional[str] = None):
    await manifest_db.reset_manifest(device_folder=device_folder)
    return {"status": "ok", "message": "Manifest cleared"}

@router.post("/manifest/reconcile")
async def reconcile_manifest(body: dict = {}):
    """Prune manifest entries whose files were deleted from disk."""
    storage_path = get_config()["storage_path"]
    device_folder = body.get("device_folder", "")
    pruned = await manifest_db.reconcile_with_filesystem(storage_path, device_folder)
    total = await manifest_db.get_total_count()
    return {"status": "ok", "pruned": pruned, "remaining": total}

@router.post("/manifest/index")
async def index_server_files(body: dict = {}):
    """Scan the storage folder and add sha256-keyed placeholder entries for any
    files not yet tracked in the manifest. iOS uses these placeholders to skip
    re-uploading content that is already physically present on the server."""
    import asyncio
    import hashlib
    from pathlib import Path

    storage_path = get_config()["storage_path"]
    device_folder = body.get("device_folder", "")
    root = Path(storage_path)
    scan_root = root / device_folder if device_folder else root

    if not scan_root.exists():
        return {"status": "ok", "indexed": 0, "already_known": 0}

    existing_paths = await manifest_db.get_stored_paths(device_folder)

    def _scan():
        results = []
        for fp in scan_root.rglob("*"):
            if not fp.is_file():
                continue
            stored_path = fp.relative_to(root).as_posix()
            if stored_path in existing_paths:
                continue
            h = hashlib.sha256()
            size = 0
            with open(fp, "rb") as f:
                for chunk in iter(lambda: f.read(1024 * 1024), b""):
                    h.update(chunk)
                    size += len(chunk)
            results.append((stored_path, fp.name, h.hexdigest(), size))
        return results

    new_files = await asyncio.to_thread(_scan)

    for stored_path, filename, sha256, size_bytes in new_files:
        identifier = f"__indexed__{sha256}"
        await manifest_db.insert_file(
            identifier, filename, sha256, size_bytes, "unknown",
            stored_path, None, device_folder,
        )

    return {
        "status": "ok",
        "indexed": len(new_files),
        "already_known": len(existing_paths),
    }


@router.post("/manifest/register")
async def register_identifier(body: dict):
    """Register an identifier that matches an already-stored file by sha256.
    Called by iOS when the exported file's hash is already in the server manifest,
    avoiding a full file upload. Creates a manifest entry reusing the existing path."""
    identifier = body.get("identifier", "")
    sha256 = body.get("sha256", "")
    device_folder = body.get("device_folder", "")
    if not identifier or not sha256:
        raise HTTPException(400, "identifier and sha256 are required")

    existing = await manifest_db.find_by_sha256(sha256)
    if not existing:
        return {"status": "not_found", "registered": False}

    root = file_store.get_storage_root()
    if not (root / existing["stored_path"]).exists():
        return {"status": "not_found", "registered": False}

    record = await manifest_db.insert_file(
        identifier,
        body.get("filename", existing["filename"]),
        sha256,
        body.get("size_bytes", existing["size_bytes"]),
        body.get("media_type", existing["media_type"]),
        existing["stored_path"],
        body.get("creation_date"),
        device_folder,
    )
    # Remove the __indexed__ placeholder now that a proper iOS identifier covers this file.
    await manifest_db.delete_file(f"__indexed__{sha256}", device_folder)
    return {"status": "ok", "registered": True, "stored_path": record["stored_path"],
            "identifier": identifier}


@router.post("/sync/complete")
async def sync_complete(body: dict):
    await manifest_db.insert_session({
        "session_id": body.get("session_id", ""),
        "started_at": body.get("started_at", ""),
        "completed_at": body.get("completed_at", ""),
        "files_uploaded": body.get("files_uploaded", 0),
        "bytes_transferred": body.get("bytes_transferred", 0),
        "skipped_duplicates": body.get("skipped_duplicates", 0),
        "errors": body.get("errors", 0),
    })
    return {"status": "recorded"}
