from datetime import datetime

from PyQt6.QtCore import Qt, QSize
from PyQt6.QtGui import QColor, QFont
from PyQt6.QtWidgets import (QWidget, QVBoxLayout, QHBoxLayout, QFrame,
                              QLabel, QScrollArea, QSizePolicy, QSpacerItem)

C_SUCCESS  = "#22C55E"
C_WARNING  = "#F59E0B"
C_ACCENT   = "#3B82F6"
C_PURPLE   = "#A855F7"
C_CYAN     = "#06B6D4"
C_DANGER   = "#EF4444"
C_TEXT     = "#E5E7EB"
C_MUTED    = "#6B7280"
C_CARD     = "#161B27"
C_ROW      = "#1A2035"
C_ROW_ALT  = "#161B27"
C_BORDER   = "#1F2937"

STAT_CONFIG = [
    ("files",  "Files Received",    "0",    C_ACCENT),
    ("bytes",  "Data Transferred",  "0 B",  C_SUCCESS),
    ("time",   "Last Received",     "—",    C_PURPLE),
    ("status", "Server Status",     "Online", C_WARNING),
]

MEDIA_META = {
    "photo":            ("🖼",  C_ACCENT),
    "video":            ("🎬",  C_PURPLE),
    "live_photo_image": ("✨",  C_CYAN),
    "live_photo_video": ("✨",  C_CYAN),
    "raw":              ("📷",  C_WARNING),
    "prores":           ("🎥",  C_DANGER),
    "slow_mo":          ("🐢",  C_SUCCESS),
    "burst":            ("📸",  C_WARNING),
    "depth_effect":     ("🌀",  C_PURPLE),
}


def _fmt(n: float) -> str:
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{n:.1f} {u}"
        n /= 1024
    return f"{n:.1f} PB"


class DashboardTab(QWidget):
    def __init__(self):
        super().__init__()
        self._files = 0
        self._bytes = 0
        self._row_widgets: list[QFrame] = []
        self._stat_labels: dict[str, QLabel] = {}
        self._build()

    # ── Build ─────────────────────────────────────────────────────────────────

    def _build(self):
        layout = QVBoxLayout(self)
        layout.setContentsMargins(28, 28, 28, 24)
        layout.setSpacing(0)

        # Header
        self._subtitle = self._make_header(layout, "Dashboard",
                                            "Waiting for uploads from your iPhone…")
        layout.addSpacing(18)

        # Stat tiles row
        tiles_row = QHBoxLayout()
        tiles_row.setSpacing(12)
        for key, title, init, color in STAT_CONFIG:
            tile, val_lbl = self._make_stat_tile(title, init, color)
            self._stat_labels[key] = val_lbl
            tiles_row.addWidget(tile)
        layout.addLayout(tiles_row)
        layout.addSpacing(20)

        # Feed card
        feed_card = QFrame()
        feed_card.setObjectName("card")
        feed_layout = QVBoxLayout(feed_card)
        feed_layout.setContentsMargins(0, 0, 0, 0)
        feed_layout.setSpacing(0)

        # Feed header
        feed_hdr = QWidget()
        fh_layout = QHBoxLayout(feed_hdr)
        fh_layout.setContentsMargins(18, 14, 18, 10)
        fh_title = QLabel("Recent Uploads")
        fh_title.setObjectName("sectionTitle")
        self._feed_count = QLabel("")
        self._feed_count.setObjectName("sectionSub")
        fh_layout.addWidget(fh_title)
        fh_layout.addStretch()
        fh_layout.addWidget(self._feed_count)
        feed_layout.addWidget(feed_hdr)

        # Column header row
        col_hdr = QFrame()
        col_hdr.setObjectName("tableHeader")
        ch_layout = QHBoxLayout(col_hdr)
        ch_layout.setContentsMargins(16, 6, 16, 6)
        ch_layout.setSpacing(0)
        for col_name, stretch, align in [
            ("TYPE",  0,  Qt.AlignmentFlag.AlignLeft),
            ("TIME",  0,  Qt.AlignmentFlag.AlignLeft),
            ("FILENAME", 1, Qt.AlignmentFlag.AlignLeft),
            ("SIZE",  0,  Qt.AlignmentFlag.AlignRight),
            ("STATUS",0,  Qt.AlignmentFlag.AlignCenter),
        ]:
            lbl = QLabel(col_name)
            lbl.setObjectName("colHeader")
            lbl.setAlignment(align)
            if col_name == "TYPE":
                lbl.setFixedWidth(48)
            elif col_name == "TIME":
                lbl.setFixedWidth(80)
            elif col_name == "SIZE":
                lbl.setFixedWidth(80)
            elif col_name == "STATUS":
                lbl.setFixedWidth(90)
            ch_layout.addWidget(lbl, stretch)
        feed_layout.addWidget(col_hdr)

        # Scrollable feed
        scroll_area = QScrollArea()
        scroll_area.setWidgetResizable(True)
        scroll_area.setFrameShape(QFrame.Shape.NoFrame)
        scroll_area.setHorizontalScrollBarPolicy(
            Qt.ScrollBarPolicy.ScrollBarAlwaysOff)

        self._feed_container = QWidget()
        self._feed_layout = QVBoxLayout(self._feed_container)
        self._feed_layout.setContentsMargins(8, 8, 8, 8)
        self._feed_layout.setSpacing(4)
        self._feed_layout.setAlignment(Qt.AlignmentFlag.AlignTop)

        self._empty_lbl = QLabel(
            "No uploads yet  ·  open SyncMaster on your iPhone to start")
        self._empty_lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._empty_lbl.setStyleSheet(
            f"color: {C_MUTED}; font-size: 13px; padding: 48px 0;")
        self._feed_layout.addWidget(self._empty_lbl)

        scroll_area.setWidget(self._feed_container)
        feed_layout.addWidget(scroll_area)

        layout.addWidget(feed_card, stretch=1)

    # ── Widgets ───────────────────────────────────────────────────────────────

    def _make_header(self, layout: QVBoxLayout, title: str, subtitle: str) -> QLabel:
        title_lbl = QLabel(title)
        title_lbl.setObjectName("pageTitle")
        layout.addWidget(title_lbl)
        layout.addSpacing(4)
        sub_lbl = QLabel(subtitle)
        sub_lbl.setObjectName("pageSubtitle")
        layout.addWidget(sub_lbl)
        return sub_lbl

    def _make_stat_tile(self, title: str, value: str, color: str) -> tuple[QFrame, QLabel]:
        tile = QFrame()
        tile.setObjectName("statTile")

        outer = QVBoxLayout(tile)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.setSpacing(0)

        # Colored accent bar at top
        bar = QFrame()
        bar.setFixedHeight(3)
        bar.setStyleSheet(
            f"background-color: {color}; border-radius: 2px; border-bottom-left-radius: 0; border-bottom-right-radius: 0;")
        outer.addWidget(bar)

        inner = QVBoxLayout()
        inner.setContentsMargins(16, 10, 16, 14)
        inner.setSpacing(4)

        title_lbl = QLabel(title)
        title_lbl.setObjectName("statLabel")

        val_lbl = QLabel(value)
        val_lbl.setObjectName("statValue")

        inner.addWidget(title_lbl)
        inner.addWidget(val_lbl)
        outer.addLayout(inner)
        return tile, val_lbl

    # ── Upload event ──────────────────────────────────────────────────────────

    def on_upload(self, event: dict):
        self._files += 1
        self._bytes += event.get("size_bytes", 0)

        self._stat_labels["files"].setText(str(self._files))
        self._stat_labels["bytes"].setText(_fmt(self._bytes))
        self._stat_labels["time"].setText(datetime.now().strftime("%H:%M:%S"))
        self._feed_count.setText(
            f"showing last {min(len(self._row_widgets)+1, 10)} of {self._files}")

        fname = event.get("filename", "")
        self._subtitle.setText(
            f"Last received: {fname}  ·  {_fmt(event.get('size_bytes', 0))}")
        self._subtitle.setStyleSheet(f"color: {C_SUCCESS}; font-size: 13px;")

        if self._empty_lbl.isVisible():
            self._empty_lbl.hide()

        self._prepend_row(event)

    def _prepend_row(self, event: dict):
        is_dup = event.get("duplicate", False)
        media_type = event.get("media_type", "photo")
        icon, icon_color = MEDIA_META.get(media_type, ("📁", C_MUTED))
        fname = event.get("filename", "")
        size_str = _fmt(event.get("size_bytes", 0))
        time_str = datetime.now().strftime("%H:%M:%S")

        odd = len(self._row_widgets) % 2 == 0
        row = QFrame()
        row.setObjectName("feedRow" if odd else "feedRowAlt")
        row.setFixedHeight(44)
        row_layout = QHBoxLayout(row)
        row_layout.setContentsMargins(12, 0, 12, 0)
        row_layout.setSpacing(0)

        # Icon
        icon_lbl = QLabel(icon)
        icon_lbl.setFixedWidth(48)
        icon_lbl.setStyleSheet(f"color: {icon_color}; font-size: 16px;")
        row_layout.addWidget(icon_lbl)

        # Time
        time_lbl = QLabel(time_str)
        time_lbl.setFixedWidth(80)
        time_lbl.setStyleSheet(f"color: {C_MUTED}; font-size: 11px;")
        row_layout.addWidget(time_lbl)

        # Filename
        name_lbl = QLabel(fname)
        name_lbl.setStyleSheet(
            f"color: {C_TEXT}; font-size: 12px; font-weight: bold;")
        name_lbl.setSizePolicy(
            QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Preferred)
        row_layout.addWidget(name_lbl, stretch=1)

        # Size
        size_lbl = QLabel(size_str)
        size_lbl.setFixedWidth(80)
        size_lbl.setAlignment(Qt.AlignmentFlag.AlignRight |
                               Qt.AlignmentFlag.AlignVCenter)
        size_lbl.setStyleSheet(f"color: {C_MUTED}; font-size: 11px;")
        row_layout.addWidget(size_lbl)

        # Badge
        badge_bg = "#14532D" if not is_dup else "#1F2937"
        badge_text_color = C_SUCCESS if not is_dup else C_WARNING
        badge = QLabel("✓ Saved" if not is_dup else "Duplicate")
        badge.setFixedWidth(90)
        badge.setAlignment(Qt.AlignmentFlag.AlignCenter)
        badge.setStyleSheet(
            f"color: {badge_text_color}; background: {badge_bg}; "
            f"border-radius: 6px; font-size: 10px; font-weight: bold; padding: 3px 0;")
        row_layout.addWidget(badge)

        self._feed_layout.insertWidget(0, row)
        self._row_widgets.insert(0, row)

        # Keep at most 10 rows visible
        if len(self._row_widgets) > 10:
            old = self._row_widgets.pop()
            self._feed_layout.removeWidget(old)
            old.deleteLater()
