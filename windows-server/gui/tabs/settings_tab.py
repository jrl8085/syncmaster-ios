import tkinter as tk
from pathlib import Path
from tkinter import filedialog
from typing import Callable
import customtkinter as ctk

from ...server.config import get_config, update_config
from ...server.ssl_utils import get_cert_fingerprint, get_local_ip

# ── Palette ───────────────────────────────────────────────────────────────────
BG_CARD   = "#1A1D27"
BG_INPUT  = "#0F1117"
ACCENT    = "#3B82F6"
SUCCESS   = "#22C55E"
WARNING   = "#F59E0B"
DANGER    = "#EF4444"
TEXT_MUTED = "#6B7280"
TEXT_LIGHT = "#E5E7EB"
BORDER    = "#252836"


class SettingsTab(ctk.CTkFrame):
    def __init__(self, master, on_save: Callable):
        super().__init__(master, fg_color="transparent")
        self._on_save = on_save
        self._after_id = None
        self._build()

    # ── Build ─────────────────────────────────────────────────────────────────

    def _build(self):
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(1, weight=1)

        # Page header (outside scroll)
        hdr = ctk.CTkFrame(self, fg_color="transparent")
        hdr.grid(row=0, column=0, padx=28, pady=(28, 6), sticky="ew")
        ctk.CTkLabel(
            hdr, text="Settings",
            font=ctk.CTkFont(size=24, weight="bold"), text_color=TEXT_LIGHT
        ).pack(anchor="w")
        ctk.CTkLabel(
            hdr, text="Server configuration and security options",
            font=ctk.CTkFont(size=13), text_color=TEXT_MUTED
        ).pack(anchor="w", pady=(3, 0))

        scroll = ctk.CTkScrollableFrame(
            self, fg_color="transparent", scrollbar_button_color=BORDER)
        scroll.grid(row=1, column=0, sticky="nsew", padx=28, pady=(8, 24))
        scroll.grid_columnconfigure(0, weight=1)

        r = 0

        # ── Storage card
        r = self._card_header(scroll, r, "Storage Location",
                               "Where uploaded media files are saved on disk")
        card, cr = self._open_card(scroll, r); r += 1

        path_row = ctk.CTkFrame(card, fg_color="transparent")
        path_row.grid(row=cr, column=0, sticky="ew", pady=4); cr += 1
        path_row.grid_columnconfigure(0, weight=1)
        self._path_var = tk.StringVar(value=get_config()["storage_path"])
        ctk.CTkEntry(
            path_row, textvariable=self._path_var,
            height=38, fg_color=BG_INPUT, border_color=BORDER,
            text_color=TEXT_LIGHT, font=ctk.CTkFont(size=13)
        ).grid(row=0, column=0, sticky="ew", padx=(0, 8))
        ctk.CTkButton(
            path_row, text="Browse…", width=100, height=38,
            fg_color=BORDER, hover_color="#374151",
            text_color=TEXT_LIGHT, command=self._browse
        ).grid(row=0, column=1)

        # ── Network card
        r = self._card_header(scroll, r, "Network",
                               "Port the server listens on (requires restart to apply)")
        card, cr = self._open_card(scroll, r); r += 1

        row_frame = ctk.CTkFrame(card, fg_color="transparent")
        row_frame.grid(row=cr, column=0, sticky="ew", pady=4); cr += 1
        self._port_var = tk.StringVar(value=str(get_config()["port"]))
        self._field_row(row_frame, "Port", self._port_var, width=110)

        ip_row = ctk.CTkFrame(card, fg_color="transparent")
        ip_row.grid(row=cr, column=0, sticky="ew", pady=4); cr += 1
        ctk.CTkLabel(
            ip_row, text="Local IP", font=ctk.CTkFont(size=13),
            text_color=TEXT_MUTED, width=110, anchor="w"
        ).grid(row=0, column=0, sticky="w")
        ctk.CTkLabel(
            ip_row, text=get_local_ip(),
            font=ctk.CTkFont(size=13, weight="bold"),
            text_color=ACCENT
        ).grid(row=0, column=1, padx=(0, 0), sticky="w")

        # ── Security card
        r = self._card_header(scroll, r, "Security",
                               "API key for iPhone authentication · SSL certificate")
        card, cr = self._open_card(scroll, r); r += 1

        key_label_row = ctk.CTkFrame(card, fg_color="transparent")
        key_label_row.grid(row=cr, column=0, sticky="ew"); cr += 1
        ctk.CTkLabel(
            key_label_row, text="API Key",
            font=ctk.CTkFont(size=13), text_color=TEXT_MUTED
        ).pack(anchor="w", pady=(0, 4))

        key_row = ctk.CTkFrame(card, fg_color="transparent")
        key_row.grid(row=cr, column=0, sticky="ew", pady=(0, 10)); cr += 1
        key_row.grid_columnconfigure(0, weight=1)
        self._key_entry = ctk.CTkEntry(
            key_row, height=38, show="•",
            fg_color=BG_INPUT, border_color=BORDER,
            text_color=TEXT_LIGHT, font=ctk.CTkFont(size=12, family="Courier")
        )
        self._key_entry.insert(0, get_config()["api_key"])
        self._key_entry.grid(row=0, column=0, sticky="ew", padx=(0, 8))
        ctk.CTkButton(
            key_row, text="Show", width=72, height=38,
            fg_color=BORDER, hover_color="#374151",
            text_color=TEXT_LIGHT, command=self._toggle_key
        ).grid(row=0, column=1, padx=(0, 6))
        ctk.CTkButton(
            key_row, text="Copy", width=72, height=38,
            fg_color=ACCENT, hover_color="#2563EB",
            text_color="white", command=lambda: self._copy(get_config()["api_key"])
        ).grid(row=0, column=2)

        # Fingerprint
        fp = get_cert_fingerprint()
        if fp:
            fp_frame = ctk.CTkFrame(card, fg_color="#0A0C12", corner_radius=8)
            fp_frame.grid(row=cr, column=0, sticky="ew", pady=(0, 8)); cr += 1
            ctk.CTkLabel(
                fp_frame, text="SSL Fingerprint",
                font=ctk.CTkFont(size=10), text_color=TEXT_MUTED
            ).pack(anchor="w", padx=12, pady=(8, 2))
            ctk.CTkLabel(
                fp_frame, text=fp,
                font=ctk.CTkFont(size=10, family="Courier"),
                text_color=SUCCESS, wraplength=520, justify="left"
            ).pack(anchor="w", padx=12, pady=(0, 8))

        ctk.CTkButton(
            card, text="Regenerate SSL Certificate",
            height=36, fg_color="transparent",
            border_width=1, border_color=BORDER,
            text_color=TEXT_MUTED, hover_color=BORDER,
            command=self._regen_cert
        ).grid(row=cr, column=0, sticky="w", pady=(4, 0)); cr += 1

        # ── Save row (outside scroll card)
        save_frame = ctk.CTkFrame(scroll, fg_color="transparent")
        save_frame.grid(row=r, column=0, sticky="ew", pady=(20, 0)); r += 1

        ctk.CTkButton(
            save_frame, text="Save Settings",
            height=42, width=160,
            fg_color=ACCENT, hover_color="#2563EB",
            font=ctk.CTkFont(size=14, weight="bold"),
            command=self._save
        ).grid(row=0, column=0, sticky="w")

        self._saved_lbl = ctk.CTkLabel(
            save_frame, text="",
            text_color=SUCCESS, font=ctk.CTkFont(size=13)
        )
        self._saved_lbl.grid(row=0, column=1, padx=14)

    # ── Helpers ───────────────────────────────────────────────────────────────

    def _card_header(self, parent, row: int, title: str, subtitle: str = "") -> int:
        frame = ctk.CTkFrame(parent, fg_color="transparent")
        frame.grid(row=row, column=0, sticky="ew", pady=(20, 4))
        ctk.CTkLabel(
            frame, text=title,
            font=ctk.CTkFont(size=15, weight="bold"), text_color=TEXT_LIGHT
        ).pack(anchor="w")
        if subtitle:
            ctk.CTkLabel(
                frame, text=subtitle,
                font=ctk.CTkFont(size=11), text_color=TEXT_MUTED
            ).pack(anchor="w", pady=(1, 0))
        return row + 1

    def _open_card(self, parent, row: int):
        card = ctk.CTkFrame(parent, fg_color=BG_CARD, corner_radius=12)
        card.grid(row=row, column=0, sticky="ew", pady=(0, 4))
        card.grid_columnconfigure(0, weight=1)
        inner = ctk.CTkFrame(card, fg_color="transparent")
        inner.grid(row=0, column=0, sticky="ew", padx=16, pady=12)
        inner.grid_columnconfigure(0, weight=1)
        return inner, 0

    def _field_row(self, parent, label: str, var: tk.StringVar, width: int = 200):
        parent.grid_columnconfigure(1, weight=1)
        ctk.CTkLabel(
            parent, text=label, font=ctk.CTkFont(size=13),
            text_color=TEXT_MUTED, width=110, anchor="w"
        ).grid(row=0, column=0, sticky="w")
        ctk.CTkEntry(
            parent, textvariable=var, width=width, height=38,
            fg_color=BG_INPUT, border_color=BORDER, text_color=TEXT_LIGHT
        ).grid(row=0, column=1, sticky="w")

    def _browse(self):
        folder = filedialog.askdirectory(
            title="Select Storage Folder", initialdir=self._path_var.get())
        if folder:
            self._path_var.set(folder)

    def _toggle_key(self):
        self._key_entry.configure(
            show="" if self._key_entry.cget("show") == "•" else "•")

    def _copy(self, text: str):
        self.clipboard_clear()
        self.clipboard_append(text)

    def _save(self):
        path = self._path_var.get()
        try:
            port = int(self._port_var.get())
        except ValueError:
            port = 8443
        Path(path).mkdir(parents=True, exist_ok=True)
        update_config(storage_path=path, port=port)
        self._on_save(path, port)
        self._saved_lbl.configure(text="✓  Settings saved", text_color=SUCCESS)
        if self._after_id:
            self.after_cancel(self._after_id)
        self._after_id = self.after(
            3000, lambda: self._saved_lbl.configure(text=""))

    def _regen_cert(self):
        from ...server.ssl_utils import generate_self_signed_cert
        generate_self_signed_cert(force=True)
        self._saved_lbl.configure(
            text="✓  New certificate generated — restart server to apply",
            text_color=WARNING
        )
