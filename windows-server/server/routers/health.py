from datetime import datetime
from fastapi import APIRouter
from ..config import get_config
from ..storage.file_store import get_free_bytes

router = APIRouter()

@router.get("/health")
async def health():
    cfg = get_config()
    return {"status": "ok", "version": "1.0.0",
            "server_time": datetime.utcnow().isoformat() + "Z",
            "storage_path": cfg["storage_path"],
            "storage_free_bytes": get_free_bytes()}
