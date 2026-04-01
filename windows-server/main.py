"""
SyncMaster Server — entry point.
Runs FastAPI (uvicorn) in a daemon thread; PyQt6 GUI on the main thread.
"""
import asyncio
import multiprocessing
import queue
import sys
import threading
import uvicorn
import ctypes
from PyQt6.QtWidgets import QApplication, QMessageBox

# PyInstaller + Windows: must call freeze_support() before anything else.
# Also force SelectorEventLoop — ProactorEventLoop (Windows default in 3.8+)
# causes uvicorn to fail silently in a frozen exe.
if sys.platform == "win32":
    multiprocessing.freeze_support()
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

from server.config import get_config
from server.ssl_utils import generate_self_signed_cert, cert_covers_current_ip, get_local_ip
from server.app import create_app

EXTRA_THEME = {
    "density_scale": "-1",
    "primaryColor": "#3B82F6",
    "primaryLightColor": "#93C5FD",
    "secondaryColor": "#1E293B",
    "secondaryLightColor": "#334155",
    "secondaryDarkColor": "#0F172A",
    "primaryTextColor": "#E5E7EB",
    "secondaryTextColor": "#94A3B8",
    "font_family": "Segoe UI",
}


_MUTEX = None  # keep alive for process lifetime

def _ensure_single_instance():
    global _MUTEX
    _MUTEX = ctypes.windll.kernel32.CreateMutexW(None, True, "Global\\SyncMasterApp")
    if ctypes.windll.kernel32.GetLastError() == 183:  # ERROR_ALREADY_EXISTS
        app = QApplication.instance() or QApplication(sys.argv)
        QMessageBox.information(None, "SyncMaster", "SyncMaster is already running.")
        sys.exit(0)


def main():
    _ensure_single_instance()
    cert_file, key_file = generate_self_signed_cert(force=not cert_covers_current_ip())
    event_queue: queue.Queue = queue.Queue(maxsize=500)
    cfg = get_config()

    fastapi_app = create_app(event_queue=event_queue)
    server_running = threading.Event()
    server_running.set()

    def run_server():
        config = uvicorn.Config(
            fastapi_app,
            host=cfg["host"],
            port=cfg["port"],
            ssl_keyfile=str(key_file),
            ssl_certfile=str(cert_file),
            log_level="warning",
            access_log=False,
        )
        server = uvicorn.Server(config)
        event_queue.put({"type": "server_status", "running": True})
        server.run()
        event_queue.put({"type": "server_status", "running": False})

    threading.Thread(target=run_server, daemon=True, name="uvicorn").start()

    qt_app = QApplication(sys.argv)
    qt_app.setQuitOnLastWindowClosed(False)
    qt_app.setApplicationName("SyncMaster")

    from qt_material import apply_stylesheet
    apply_stylesheet(qt_app, theme="dark_blue.xml", extra=EXTRA_THEME)

    from gui.app_window import SyncMasterWindow
    window = SyncMasterWindow(event_queue=event_queue, server_running_event=server_running)
    window.show()

    local_ip = get_local_ip()
    print(f"\n  SyncMaster running on https://{local_ip}:{cfg['port']}")
    print(f"  API Key: {cfg['api_key']}\n")

    sys.exit(qt_app.exec())


if __name__ == "__main__":
    main()
