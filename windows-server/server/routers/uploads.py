import asyncio
from typing import Optional
from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile, status
from ..auth import verify_api_key
from ..storage import file_store, manifest_db

router = APIRouter(dependencies=[Depends(verify_api_key)])
_event_queue: Optional[asyncio.Queue] = None

def set_event_queue(q: asyncio.Queue):
    global _event_queue; _event_queue = q

def _push(event: dict):
    if _event_queue:
        try: _event_queue.put_nowait(event)
        except asyncio.QueueFull: pass

@router.post("/upload", status_code=201)
async def upload_file(
    file: UploadFile = File(...),
    identifier: str = Form(...),
    filename: str = Form(...),
    media_type: str = Form(...),
    creation_date: str = Form(default=""),
    sha256: str = Form(...),
    size_bytes: int = Form(...),
):
    if file_store.get_free_bytes() < 100 * 1024 * 1024:
        raise HTTPException(507, "Insufficient storage space")

    data = await file.read()
    try:
        record, is_dup = await file_store.store_file(
            data, identifier, filename, media_type, creation_date or None, sha256, size_bytes)
    except ValueError as e:
        raise HTTPException(400, str(e))

    _push({"type": "upload", "filename": filename, "size_bytes": size_bytes,
           "media_type": media_type, "duplicate": is_dup, "stored_path": record["stored_path"]})

    return {"status": "duplicate" if is_dup else "accepted", "identifier": identifier,
            "stored_path": record["stored_path"], "deduplicated": is_dup}

@router.get("/files")
async def list_files(page: int = 1, per_page: int = 50, media_type: Optional[str] = None):
    files = await manifest_db.get_manifest()
    if media_type: files = [f for f in files if f.get("media_type") == media_type]
    total = len(files)
    start = (page - 1) * per_page
    return {"total": total, "page": page, "per_page": per_page, "files": files[start:start + per_page]}

@router.delete("/files/{identifier}")
async def delete_file_route(identifier: str, delete_file: bool = False):
    from ..config import get_config
    from pathlib import Path, os
    record = await manifest_db.find_by_identifier(identifier)
    if not record: raise HTTPException(404, "File not found")
    if delete_file:
        p = Path(get_config()["storage_path"]) / record["stored_path"]
        if p.exists(): p.unlink()
    deleted = await manifest_db.delete_file(identifier)
    return {"status": "removed" if deleted else "not_found", "identifier": identifier}
