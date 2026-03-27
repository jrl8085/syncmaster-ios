from datetime import datetime
import customtkinter as ctk

# ── Palette ───────────────────────────────────────────────────────────────────
BG_CARD   = "#1A1D27"
BG_ROW_A  = "#1F2330"
BG_ROW_B  = "#1A1D27"
ACCENT    = "#3B82F6"
SUCCESS   = "#22C55E"
WARNING   = "#F59E0B"
TEXT_MUTED = "#6B7280"
TEXT_LIGHT = "#E5E7EB"
BORDER    = "#252836"

MEDIA_META = {
    "photo":            ("🖼",  ACCENT),
    "video":            ("🎬",  "#A855F7"),
    "live_photo_image": ("✨",  "#06B6D4"),
    "live_photo_video": ("✨",  "#06B6D4"),
    "raw":              ("📷",  WARNING),
    "prores":           ("🎥",  "#EF4444"),
    "slow_mo":          ("🐢",  SUCCESS),
    "burst":            ("📸",  WARNING),
    "depth_effect":     ("🌀",  "#A855F7"),
}

COL_HEADERS = [
    ("",         30,  "center"),
    ("Time",     78,  "w"),
    ("Filename", 0,   "w"),    # weight=1
    ("Type",     100, "center"),
    ("Size",     80,  "e"),
    ("Status",   90,  "center"),
]


def _fmt(n: float) -> str:
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{n:.1f} {u}"
        n /= 1024
    return f"{n:.1f} PB"


class HistoryTab(ctk.CTkFrame):
    def __init__(self, master):
        super().__init__(master, fg_color="transparent")
        self._rows: list[dict] = []
        self._build()

    # ── Build ─────────────────────────────────────────────────────────────────

    def _build(self):
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(2, weight=1)

        # Header
        hdr = ctk.CTkFrame(self, fg_color="transparent")
        hdr.grid(row=0, column=0, padx=28, pady=(28, 6), sticky="ew")
        hdr.grid_columnconfigure(0, weight=1)
        ctk.CTkLabel(
            hdr, text="Upload History",
            font=ctk.CTkFont(size=24, weight="bold"), text_color=TEXT_LIGHT
        ).grid(row=0, column=0, sticky="w")
        self._count_lbl = ctk.CTkLabel(
            hdr, text="0 files total",
            font=ctk.CTkFont(size=13), text_color=TEXT_MUTED
        )
        self._count_lbl.grid(row=1, column=0, sticky="w", pady=(3, 0))

        # Table card
        table_card = ctk.CTkFrame(self, fg_color=BG_CARD, corner_radius=14)
        table_card.grid(row=2, column=0, padx=28, pady=(8, 24), sticky="nsew")
        table_card.grid_columnconfigure(0, weight=1)
        table_card.grid_rowconfigure(1, weight=1)

        # Column header row
        col_hdr = ctk.CTkFrame(table_card, fg_color="#151720", corner_radius=0)
        col_hdr.grid(row=0, column=0, sticky="ew", padx=0, pady=0)
        col_hdr.grid_columnconfigure(2, weight=1)

        for ci, (lbl, width, anchor) in enumerate(COL_HEADERS):
            kw = {"width": width} if width else {}
            ctk.CTkLabel(
                col_hdr, text=lbl,
                font=ctk.CTkFont(size=10, weight="bold"),
                text_color=TEXT_MUTED, anchor=anchor, **kw
            ).grid(row=0, column=ci, padx=6, pady=8, sticky="ew" if not width else anchor)
            if not width:
                col_hdr.grid_columnconfigure(ci, weight=1)

        # Scrollable list
        self._scroll = ctk.CTkScrollableFrame(
            table_card, fg_color="transparent",
            scrollbar_button_color=BORDER
        )
        self._scroll.grid(row=1, column=0, sticky="nsew", padx=8, pady=(0, 8))
        self._scroll.grid_columnconfigure(2, weight=1)

        self._empty = ctk.CTkLabel(
            self._scroll,
            text="No history yet  ·  uploads will appear here",
            text_color=TEXT_MUTED, font=ctk.CTkFont(size=13)
        )
        self._empty.grid(row=0, column=0, columnspan=6, pady=60)

    # ── Events ────────────────────────────────────────────────────────────────

    def on_upload(self, event: dict):
        if self._empty.winfo_ismapped():
            self._empty.grid_forget()
        # stamp the time now
        event = dict(event, _received=datetime.now().strftime("%H:%M:%S"))
        self._rows.insert(0, event)
        self._count_lbl.configure(text=f"{len(self._rows)} files total")
        self._redraw()

    def _redraw(self):
        for w in self._scroll.winfo_children():
            w.destroy()
        self._scroll.grid_columnconfigure(2, weight=1)

        for idx, row in enumerate(self._rows[:500]):
            bg = BG_ROW_A if idx % 2 == 0 else BG_ROW_B
            is_dup = row.get("duplicate", False)
            media_type = row.get("media_type", "photo")
            icon, icon_color = MEDIA_META.get(media_type, ("📁", TEXT_MUTED))
            type_label = media_type.replace("_", " ").title()

            f = ctk.CTkFrame(self._scroll, fg_color=bg, corner_radius=6, height=38)
            f.grid(row=idx, column=0, columnspan=6, sticky="ew", pady=1)
            f.grid_columnconfigure(2, weight=1)
            f.grid_propagate(False)

            # Icon
            ctk.CTkLabel(
                f, text=icon, font=ctk.CTkFont(size=14),
                text_color=icon_color, width=30, anchor="center"
            ).grid(row=0, column=0, padx=(8, 2))

            # Time
            ctk.CTkLabel(
                f, text=row.get("_received", ""),
                font=ctk.CTkFont(size=11), text_color=TEXT_MUTED,
                width=78, anchor="w"
            ).grid(row=0, column=1, padx=4)

            # Filename
            ctk.CTkLabel(
                f, text=row.get("filename", ""),
                font=ctk.CTkFont(size=12), text_color=TEXT_LIGHT,
                anchor="w"
            ).grid(row=0, column=2, padx=4, sticky="w")

            # Type
            ctk.CTkLabel(
                f, text=type_label,
                font=ctk.CTkFont(size=10), text_color=icon_color,
                width=100, anchor="center"
            ).grid(row=0, column=3, padx=4)

            # Size
            ctk.CTkLabel(
                f, text=_fmt(row.get("size_bytes", 0)),
                font=ctk.CTkFont(size=11), text_color=TEXT_MUTED,
                width=80, anchor="e"
            ).grid(row=0, column=4, padx=4)

            # Status
            status_color = WARNING if is_dup else SUCCESS
            ctk.CTkLabel(
                f, text="Duplicate" if is_dup else "✓ Saved",
                font=ctk.CTkFont(size=10, weight="bold"),
                text_color=status_color, width=90, anchor="center"
            ).grid(row=0, column=5, padx=(4, 8))
