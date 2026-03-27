"""
SyncMaster Server — entry point.
Runs FastAPI server, CustomTkinter GUI, and pystray tray icon concurrently.
"""
import queue
import sys
import threading
import uvicorn

from server.config import get_config
from server.ssl_utils import generate_self_signed_cert, get_local_ip
from server.app import create_app


def main():
    cert_file, key_file = generate_self_signed_cert()
    event_queue: queue.Queue = queue.Queue(maxsize=500)
    cfg = get_config()

    app = create_app(event_queue=event_queue)
    server_running = threading.Event()
    server_running.set()

    def run_server():
        config = uvicorn.Config(app, host=cfg["host"], port=cfg["port"],
                                ssl_keyfile=str(key_file), ssl_certfile=str(cert_file),
                                log_level="warning", access_log=False)
        server = uvicorn.Server(config)
        event_queue.put({"type": "server_status", "running": True})
        server.run()
        event_queue.put({"type": "server_status", "running": False})

    threading.Thread(target=run_server, daemon=True, name="uvicorn").start()

    from gui.app_window import SyncMasterWindow
    window = SyncMasterWindow(event_queue=event_queue, server_running_event=server_running)

    from tray.tray_app import SyncMasterTray
    tray = SyncMasterTray(
        on_show=lambda: window.after(0, window.show_from_tray),
        on_quit=lambda: window.after(0, _quit, window),
        on_pause_toggle=lambda p: event_queue.put({"type": "pause", "paused": p}),
    )
    window._tray_ref = tray
    threading.Thread(target=tray.start, daemon=True, name="tray").start()

    local_ip = get_local_ip()
    print(f"\n  SyncMaster running on https://{local_ip}:{cfg['port']}")
    print(f"  API Key: {cfg['api_key']}\n")

    window.mainloop()


def _quit(window):
    window.destroy()
    sys.exit(0)


if __name__ == "__main__":
    main()
