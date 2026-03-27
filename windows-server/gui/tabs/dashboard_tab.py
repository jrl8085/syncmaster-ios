from datetime import datetime
import customtkinter as ctk

# ── Palette (matches app_window) ─────────────────────────────────────────────
BG_CARD   = "#1A1D27"
BG_CARD2  = "#1F2330"
ACCENT    = "#3B82F6"
SUCCESS   = "#22C55E"
WARNING   = "#F59E0B"
DANGER    = "#EF4444"
PURPLE    = "#A855F7"
TEXT_MUTED = "#6B7280"
TEXT_LIGHT = "#E5E7EB"
BORDER    = "#252836"

MEDIA_META = {
    "photo":            ("🖼",  ACCENT),
    "video":            ("🎬",  PURPLE),
    "live_photo_image": ("✨",  "#06B6D4"),
    "live_photo_video": ("✨",  "#06B6D4"),
    "raw":              ("📷",  WARNING),
    "prores":           ("🎥",  DANGER),
    "slow_mo":          ("🐢",  SUCCESS),
    "burst":            ("📸",  WARNING),
    "depth_effect":     ("🌀",  PURPLE),
}

STAT_CONFIG = [
    ("files",  "Files Received",    "0",   ACCENT),
    ("bytes",  "Data Transferred",  "0 B", SUCCESS),
    ("time",   "Last Received",     "—",   PURPLE),
    ("rate",   "Session Active",    "Yes", WARNING),
]


def _fmt(n: float) -> str:
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{n:.1f} {u}"
        n /= 1024
    return f"{n:.1f} PB"


class DashboardTab(ctk.CTkFrame):
    def __init__(self, master):
        super().__init__(master, fg_color="transparent")
        self._files = 0
        self._bytes = 0
        self._rows: list[ctk.CTkFrame] = []
        self._stat_labels: dict[str, ctk.CTkLabel] = {}
        self._build()

    # ── Build ─────────────────────────────────────────────────────────────────

    def _build(self):
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(2, weight=1)

        # Header
        hdr = ctk.CTkFrame(self, fg_color="transparent")
        hdr.grid(row=0, column=0, padx=28, pady=(28, 6), sticky="ew")
        ctk.CTkLabel(
            hdr, text="Dashboard",
            font=ctk.CTkFont(size=24, weight="bold"),
            text_color=TEXT_LIGHT
        ).pack(anchor="w")
        self._subtitle = ctk.CTkLabel(
            hdr, text="Waiting for uploads from your iPhone…",
            font=ctk.CTkFont(size=13), text_color=TEXT_MUTED
        )
        self._subtitle.pack(anchor="w", pady=(3, 0))

        # Stat tiles
        stats_frame = ctk.CTkFrame(self, fg_color="transparent")
        stats_frame.grid(row=1, column=0, padx=28, pady=(10, 8), sticky="ew")
        stats_frame.grid_columnconfigure((0, 1, 2, 3), weight=1)

        for col, (key, title, init, color) in enumerate(STAT_CONFIG):
            lbl = self._stat_tile(stats_frame, title, init, color, col)
            self._stat_labels[key] = lbl

        # Recent uploads
        feed_card = ctk.CTkFrame(self, fg_color=BG_CARD, corner_radius=14)
        feed_card.grid(row=2, column=0, padx=28, pady=(4, 24), sticky="nsew")
        feed_card.grid_columnconfigure(0, weight=1)
        feed_card.grid_rowconfigure(1, weight=1)

        feed_hdr = ctk.CTkFrame(feed_card, fg_color="transparent")
        feed_hdr.grid(row=0, column=0, padx=18, pady=(16, 10), sticky="ew")
        feed_hdr.grid_columnconfigure(0, weight=1)
        ctk.CTkLabel(
            feed_hdr, text="Recent Uploads",
            font=ctk.CTkFont(size=15, weight="bold"), text_color=TEXT_LIGHT
        ).grid(row=0, column=0, sticky="w")
        self._feed_count = ctk.CTkLabel(
            feed_hdr, text="", font=ctk.CTkFont(size=11), text_color=TEXT_MUTED
        )
        self._feed_count.grid(row=0, column=1, sticky="e")

        # Column headers
        col_hdr = ctk.CTkFrame(feed_card, fg_color="transparent")
        col_hdr.grid(row=1, column=0, padx=18, pady=(0, 6), sticky="ew")
        col_hdr.grid_columnconfigure(2, weight=1)
        for ci, (lbl, anchor) in enumerate([
            ("Type", "w"), ("Time", "w"), ("Filename", "w"), ("Size", "e"), ("Status", "e")
        ]):
            ctk.CTkLabel(
                col_hdr, text=lbl, font=ctk.CTkFont(size=10, weight="bold"),
                text_color=TEXT_MUTED, anchor=anchor
            ).grid(row=0, column=ci, padx=(0 if ci else 0, 8), sticky=anchor)

        self._scroll = ctk.CTkScrollableFrame(
            feed_card, fg_color="transparent", scrollbar_button_color=BORDER)
        self._scroll.grid(row=2, column=0, padx=12, pady=(0, 12), sticky="nsew")
        self._scroll.grid_columnconfigure(2, weight=1)
        feed_card.grid_rowconfigure(2, weight=1)

        self._empty = ctk.CTkLabel(
            self._scroll,
            text="No uploads yet  ·  Open SyncMaster on your iPhone to start",
            text_color=TEXT_MUTED, font=ctk.CTkFont(size=13)
        )
        self._empty.grid(row=0, column=0, columnspan=5, pady=50)

    # ── Stat tile ─────────────────────────────────────────────────────────────

    def _stat_tile(self, parent, title: str, value: str, color: str, col: int) -> ctk.CTkLabel:
        card = ctk.CTkFrame(parent, fg_color=BG_CARD, corner_radius=14)
        card.grid(row=0, column=col, padx=5, pady=4, sticky="ew")

        # Colored top bar
        bar = ctk.CTkFrame(card, height=3, corner_radius=2, fg_color=color)
        bar.pack(fill="x", padx=0, pady=0, side="top")

        ctk.CTkLabel(
            card, text=title,
            font=ctk.CTkFont(size=11), text_color=TEXT_MUTED, anchor="w"
        ).pack(padx=16, pady=(12, 2), anchor="w")

        lbl = ctk.CTkLabel(
            card, text=value,
            font=ctk.CTkFont(size=26, weight="bold"),
            text_color=TEXT_LIGHT, anchor="w"
        )
        lbl.pack(padx=16, pady=(0, 14), anchor="w")
        return lbl

    # ── Upload event ─────────────────────────────────────────────────────────

    def on_upload(self, event: dict):
        self._files += 1
        self._bytes += event.get("size_bytes", 0)

        self._stat_labels["files"].configure(text=str(self._files))
        self._stat_labels["bytes"].configure(text=_fmt(self._bytes))
        self._stat_labels["time"].configure(text=datetime.now().strftime("%H:%M:%S"))
        self._feed_count.configure(
            text=f"showing last {min(len(self._rows)+1, 10)} of {self._files}")

        fname = event.get("filename", "")
        self._subtitle.configure(
            text=f"Last received: {fname}  ·  {_fmt(event.get('size_bytes', 0))}",
            text_color=SUCCESS
        )

        if self._empty.winfo_ismapped():
            self._empty.grid_forget()

        self._add_row(event)

    def _add_row(self, event: dict):
        is_dup = event.get("duplicate", False)
        media_type = event.get("media_type", "photo")
        icon, icon_color = MEDIA_META.get(media_type, ("📁", TEXT_MUTED))
        size_str = _fmt(event.get("size_bytes", 0))
        time_str = datetime.now().strftime("%H:%M:%S")
        fname = event.get("filename", "")

        row = ctk.CTkFrame(
            self._scroll, fg_color=BG_CARD2, corner_radius=8, height=46)
        row.grid(row=0, column=0, columnspan=5, sticky="ew", pady=2)
        row.grid_columnconfigure(2, weight=1)
        row.grid_propagate(False)

        # Icon
        ctk.CTkLabel(
            row, text=icon, font=ctk.CTkFont(size=16),
            text_color=icon_color, width=36
        ).grid(row=0, column=0, padx=(10, 4))

        # Time
        ctk.CTkLabel(
            row, text=time_str, font=ctk.CTkFont(size=11),
            text_color=TEXT_MUTED, width=70, anchor="w"
        ).grid(row=0, column=1, padx=4)

        # Filename
        ctk.CTkLabel(
            row, text=fname, font=ctk.CTkFont(size=12, weight="bold"),
            text_color=TEXT_LIGHT, anchor="w"
        ).grid(row=0, column=2, padx=4, sticky="w")

        # Size
        ctk.CTkLabel(
            row, text=size_str, font=ctk.CTkFont(size=11),
            text_color=TEXT_MUTED, width=72, anchor="e"
        ).grid(row=0, column=3, padx=4)

        # Status badge
        badge_color = BG_CARD if is_dup else "#14532D"
        badge_text_color = WARNING if is_dup else SUCCESS
        badge_text = "Duplicate" if is_dup else "✓ Saved"
        badge = ctk.CTkLabel(
            row, text=badge_text, font=ctk.CTkFont(size=10, weight="bold"),
            text_color=badge_text_color, fg_color=badge_color,
            corner_radius=6, width=72
        )
        badge.grid(row=0, column=4, padx=(4, 10))

        # Push older rows down
        for i, r in enumerate(self._rows, start=1):
            r.grid(row=i, column=0, columnspan=5, sticky="ew", pady=2)
        self._rows.insert(0, row)
        if len(self._rows) > 10:
            self._rows.pop().destroy()
