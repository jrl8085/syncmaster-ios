import asyncio
import logging
from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from .storage import manifest_db
from .routers import health, uploads, sync

log = logging.getLogger("syncmaster.reconcile")

_RECONCILE_INTERVAL = 3600  # seconds


async def _reconcile_loop(event_queue, config: dict):
    """Background task: reconcile every device folder against the filesystem once per hour."""
    storage_path = config["storage_path"]
    while True:
        await asyncio.sleep(_RECONCILE_INTERVAL)
        try:
            folders = await manifest_db.get_all_device_folders()
            total_pruned = 0
            for folder in folders:
                pruned = await manifest_db.reconcile_with_filesystem(storage_path, folder)
                total_pruned += pruned
                if pruned:
                    log.info("Reconcile '%s': pruned %d stale entry(s)", folder, pruned)
            if event_queue is not None:
                event_queue.put_nowait({
                    "type": "reconcile",
                    "folders": len(folders),
                    "pruned": total_pruned,
                })
        except Exception:
            log.exception("Hourly reconcile failed")


@asynccontextmanager
async def lifespan(app: FastAPI):
    from .config import get_config
    await manifest_db.init_db()
    eq = getattr(app.state, "event_queue", None)
    task = asyncio.create_task(_reconcile_loop(eq, get_config()))
    try:
        yield
    finally:
        task.cancel()

def create_app(event_queue: asyncio.Queue = None) -> FastAPI:
    app = FastAPI(title="SyncMaster Server", version="1.0.0", lifespan=lifespan, docs_url=None, redoc_url=None)
    app.state.event_queue = event_queue
    app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
    if event_queue:
        uploads.set_event_queue(event_queue)
    app.include_router(health.router)
    app.include_router(uploads.router)
    app.include_router(sync.router)
    return app
