import queue
import threading
import tkinter as tk
import customtkinter as ctk

from ..server.config import get_config, update_config
from ..server.ssl_utils import get_local_ip

ctk.set_appearance_mode("Dark")
ctk.set_default_color_theme("blue")

# ── Palette ─────────────────────────────────────────────────────────────────
BG_SIDEBAR   = "#0F1117"
BG_SIDEBAR_H = "#1A1D27"
ACCENT       = "#3B82F6"
ACCENT_DARK  = "#1D4ED8"
SUCCESS      = "#22C55E"
WARNING      = "#F59E0B"
DANGER       = "#EF4444"
TEXT_MUTED   = "#6B7280"
TEXT_LIGHT   = "#E5E7EB"
BORDER       = "#1F2937"

NAV_ITEMS = [
    ("dashboard", "  Dashboard",  "▣"),
    ("history",   "  History",    "☰"),
    ("settings",  "  Settings",   "⚙"),
]


class SyncMasterWindow(ctk.CTk):
    def __init__(self, event_queue: queue.Queue, server_running_event: threading.Event):
        super().__init__()
        self.event_queue = event_queue
        self.server_running = server_running_event
        self._tray_ref = None
        self._upload_total = 0

        self.title("SyncMaster")
        self.geometry("1020x680")
        self.minsize(820, 560)
        self.configure(fg_color="#13161E")

        self._build_ui()
        self._poll_events()
        self.protocol("WM_DELETE_WINDOW", self.hide_to_tray)

    # ── Layout ───────────────────────────────────────────────────────────────

    def _build_ui(self):
        self.grid_columnconfigure(0, weight=0)
        self.grid_columnconfigure(1, weight=1)
        self.grid_rowconfigure(0, weight=1)

        self._sidebar = self._make_sidebar()
        self._sidebar.grid(row=0, column=0, sticky="nsew")

        content = ctk.CTkFrame(self, fg_color="transparent")
        content.grid(row=0, column=1, sticky="nsew")
        content.grid_rowconfigure(0, weight=1)
        content.grid_columnconfigure(0, weight=1)

        from .tabs.dashboard_tab import DashboardTab
        from .tabs.history_tab import HistoryTab
        from .tabs.settings_tab import SettingsTab

        self._tabs = {
            "dashboard": DashboardTab(content),
            "history":   HistoryTab(content),
            "settings":  SettingsTab(content, on_save=self._on_settings_save),
        }
        for tab in self._tabs.values():
            tab.grid(row=0, column=0, sticky="nsew")

        self._show_tab("dashboard")

    # ── Sidebar ───────────────────────────────────────────────────────────────

    def _make_sidebar(self) -> ctk.CTkFrame:
        sb = ctk.CTkFrame(self, width=220, corner_radius=0, fg_color=BG_SIDEBAR)
        sb.grid_propagate(False)
        sb.grid_columnconfigure(0, weight=1)
        # push footer to bottom
        sb.grid_rowconfigure(5, weight=1)

        # ── Logo block
        logo_frame = ctk.CTkFrame(sb, fg_color="transparent")
        logo_frame.grid(row=0, column=0, padx=20, pady=(28, 24), sticky="ew")

        icon_lbl = ctk.CTkLabel(
            logo_frame, text="⟳",
            font=ctk.CTkFont(size=28, weight="bold"),
            text_color=ACCENT, width=36
        )
        icon_lbl.grid(row=0, column=0, rowspan=2)

        ctk.CTkLabel(
            logo_frame, text="SyncMaster",
            font=ctk.CTkFont(size=17, weight="bold"),
            text_color=TEXT_LIGHT, anchor="w"
        ).grid(row=0, column=1, padx=(10, 0), sticky="w")

        ctk.CTkLabel(
            logo_frame, text="Media Backup Server",
            font=ctk.CTkFont(size=10),
            text_color=TEXT_MUTED, anchor="w"
        ).grid(row=1, column=1, padx=(10, 0), sticky="w")

        # ── Divider
        ctk.CTkFrame(sb, height=1, fg_color=BORDER).grid(
            row=1, column=0, sticky="ew", padx=16)

        # ── Status pill
        status_frame = ctk.CTkFrame(sb, fg_color=BG_SIDEBAR_H, corner_radius=10)
        status_frame.grid(row=2, column=0, padx=16, pady=(16, 8), sticky="ew")
        status_frame.grid_columnconfigure(1, weight=1)

        self._dot = ctk.CTkLabel(status_frame, text="●", font=ctk.CTkFont(size=10),
                                  text_color=SUCCESS, width=18)
        self._dot.grid(row=0, column=0, padx=(12, 4), pady=10)
        self._status_label = ctk.CTkLabel(
            status_frame, text="Server running",
            font=ctk.CTkFont(size=12), text_color=TEXT_LIGHT, anchor="w"
        )
        self._status_label.grid(row=0, column=1, pady=10, sticky="w")

        # ── Nav buttons
        self._nav_btns = {}
        for i, (tab_id, label, icon) in enumerate(NAV_ITEMS, start=3):
            btn = ctk.CTkButton(
                sb,
                text=f"{icon}  {label.strip()}",
                anchor="w",
                fg_color="transparent",
                text_color=TEXT_MUTED,
                hover_color=BG_SIDEBAR_H,
                font=ctk.CTkFont(size=14),
                height=44,
                corner_radius=10,
                command=lambda t=tab_id: self._show_tab(t)
            )
            btn.grid(row=i, column=0, padx=10, pady=2, sticky="ew")
            self._nav_btns[tab_id] = btn

        # ── Footer: IP address
        footer = ctk.CTkFrame(sb, fg_color="transparent")
        footer.grid(row=6, column=0, padx=16, pady=(0, 20), sticky="sew")

        ctk.CTkFrame(footer, height=1, fg_color=BORDER).pack(fill="x", pady=(0, 12))

        ip = get_local_ip()
        cfg = get_config()
        ctk.CTkLabel(footer, text="Server Address", font=ctk.CTkFont(size=10),
                      text_color=TEXT_MUTED, anchor="w").pack(anchor="w")
        ctk.CTkLabel(footer, text=f"{ip}:{cfg['port']}",
                      font=ctk.CTkFont(size=12, weight="bold"),
                      text_color=ACCENT, anchor="w").pack(anchor="w", pady=(2, 0))

        return sb

    # ── Tab switching ─────────────────────────────────────────────────────────

    def _show_tab(self, tab_id: str):
        for k, tab in self._tabs.items():
            tab.tkraise() if k == tab_id else tab.lower()
        for k, btn in self._nav_btns.items():
            if k == tab_id:
                btn.configure(
                    fg_color=ACCENT_DARK,
                    text_color="white",
                    hover_color=ACCENT_DARK
                )
            else:
                btn.configure(
                    fg_color="transparent",
                    text_color=TEXT_MUTED,
                    hover_color=BG_SIDEBAR_H
                )

    # ── Events ────────────────────────────────────────────────────────────────

    def _poll_events(self):
        try:
            while True:
                event = self.event_queue.get_nowait()
                self._handle_event(event)
        except queue.Empty:
            pass
        self.after(250, self._poll_events)

    def _handle_event(self, event: dict):
        t = event.get("type")
        if t == "upload":
            self._upload_total += 1
            self._tabs["dashboard"].on_upload(event)
            self._tabs["history"].on_upload(event)
            if self._tray_ref:
                self._tray_ref.update_tooltip(
                    f"SyncMaster · {self._upload_total} files received")
        elif t == "server_status":
            running = event.get("running", True)
            self._status_label.configure(
                text="Server running" if running else "Server stopped")
            self._dot.configure(
                text_color=SUCCESS if running else DANGER)

    # ── Tray helpers ──────────────────────────────────────────────────────────

    def hide_to_tray(self):
        self.withdraw()

    def show_from_tray(self):
        self.deiconify()
        self.lift()
        self.focus_force()

    def _on_settings_save(self, storage_path: str, port: int):
        update_config(storage_path=storage_path, port=port)
