from datetime import datetime
from typing import Optional
from fastapi import APIRouter, Depends
from ..auth import verify_api_key
from ..storage import manifest_db

router = APIRouter(dependencies=[Depends(verify_api_key)])

@router.get("/manifest")
async def get_manifest(since: Optional[str] = None):
    files = await manifest_db.get_manifest(since=since)
    return {"count": len(files), "generated_at": datetime.utcnow().isoformat() + "Z", "files": files}

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
