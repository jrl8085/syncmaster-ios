import asyncio
from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from .storage import manifest_db
from .routers import health, uploads, sync

@asynccontextmanager
async def lifespan(app: FastAPI):
    await manifest_db.init_db()
    yield

def create_app(event_queue: asyncio.Queue = None) -> FastAPI:
    app = FastAPI(title="SyncMaster Server", version="1.0.0", lifespan=lifespan, docs_url=None, redoc_url=None)
    app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
    if event_queue:
        uploads.set_event_queue(event_queue)
    app.include_router(health.router)
    app.include_router(uploads.router)
    app.include_router(sync.router)
    return app
