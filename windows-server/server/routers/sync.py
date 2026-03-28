from datetime import datetime
from typing import Optional
from fastapi import APIRouter, Depends
from ..auth import verify_api_key
from ..config import get_config
from ..storage import manifest_db

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
