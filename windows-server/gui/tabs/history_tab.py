from datetime import datetime

from PyQt6.QtCore import Qt
from PyQt6.QtWidgets import (QWidget, QVBoxLayout, QHBoxLayout, QFrame,
                              QLabel, QScrollArea, QSizePolicy)

C_SUCCESS = "#4CAF50"
C_WARNING = "#FF9800"
C_ACCENT  = "#1A73E8"
C_PURPLE  = "#9C27B0"
C_CYAN    = "#00BCD4"
C_DANGER  = "#F44336"
C_TEXT    = "#E8EAED"
C_MUTED   = "#9AA0A6"
C_ROW_A   = "#1E2532"
C_ROW_B   = "#181D2A"
C_BORDER  = "#2D3142"

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

COL_HEADERS = [
    ("",         40,   Qt.AlignmentFlag.AlignCenter),
    ("TIME",     80,   Qt.AlignmentFlag.AlignLeft),
    ("FILENAME", -1,   Qt.AlignmentFlag.AlignLeft),
    ("TYPE",     110,  Qt.AlignmentFlag.AlignCenter),
    ("SIZE",     80,   Qt.AlignmentFlag.AlignRight),
    ("STATUS",   90,   Qt.AlignmentFlag.AlignCenter),
]

MAX_ROWS = 300


def _fmt(n: float) -> str:
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{n:.1f} {u}"
        n /= 1024
    return f"{n:.1f} PB"


class HistoryTab(QWidget):
    def __init__(self):
        super().__init__()
        self._total_count = 0          # all uploads ever seen (including batched)
        self._row_widgets: list[QFrame] = []
        self._build()

    def _build(self):
        layout = QVBoxLayout(self)
        layout.setContentsMargins(28, 28, 28, 24)
        layout.setSpacing(0)

        title = QLabel("Upload History")
        title.setObjectName("pageTitle")
        layout.addWidget(title)
        layout.addSpacing(4)
        self._count_lbl = QLabel("0 files received")
        self._count_lbl.setObjectName("pageSubtitle")
        layout.addWidget(self._count_lbl)
        layout.addSpacing(20)

        card = QFrame()
        card.setObjectName("card")
        card_layout = QVBoxLayout(card)
        card_layout.setContentsMargins(0, 0, 0, 0)
        card_layout.setSpacing(0)

        col_hdr = QFrame()
        col_hdr.setObjectName("tableHeader")
        col_hdr.setFixedHeight(36)
        ch_layout = QHBoxLayout(col_hdr)
        ch_layout.setContentsMargins(12, 0, 12, 0)
        ch_layout.setSpacing(0)
        for col_name, width, align in COL_HEADERS:
            lbl = QLabel(col_name)
            lbl.setObjectName("colHeader")
            lbl.setAlignment(align)
            if width > 0:
                lbl.setFixedWidth(width)
            ch_layout.addWidget(lbl, 0 if width > 0 else 1)
        card_layout.addWidget(col_hdr)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)

        self._rows_container = QWidget()
        self._rows_layout = QVBoxLayout(self._rows_container)
        self._rows_layout.setContentsMargins(8, 8, 8, 8)
        self._rows_layout.setSpacing(3)
        self._rows_layout.setAlignment(Qt.AlignmentFlag.AlignTop)

        self._empty_lbl = QLabel("No history yet  ·  uploads will appear here")
        self._empty_lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._empty_lbl.setStyleSheet(
            f"color: {C_MUTED}; font-size: 13px; padding: 60px 0;")
        self._rows_layout.addWidget(self._empty_lbl)

        scroll.setWidget(self._rows_container)
        card_layout.addWidget(scroll)
        layout.addWidget(card, stretch=1)

    def on_upload(self, event: dict, batch_count: int = 1):
        """Called once per poll tick; batch_count covers any skipped events."""
        self._total_count += batch_count
        self._count_lbl.setText(f"{self._total_count} files received")

        if self._empty_lbl.isVisible():
            self._empty_lbl.hide()

        row_data = dict(event, _received=datetime.now().strftime("%H:%M:%S"))
        row = self._make_row(row_data, len(self._row_widgets))
        self._rows_layout.insertWidget(0, row)
        self._row_widgets.insert(0, row)

        # Prune oldest rows beyond the cap
        while len(self._row_widgets) > MAX_ROWS:
            old = self._row_widgets.pop()
            self._rows_layout.removeWidget(old)
            old.deleteLater()

    def on_reconcile(self, event: dict):
        """Insert a system-event row when the hourly reconcile fires."""
        if self._empty_lbl.isVisible():
            self._empty_lbl.hide()

        pruned = event.get("pruned", 0)
        folders = event.get("folders", 0)
        ts = datetime.now().strftime("%H:%M:%S")
        msg = (f"Pruned {pruned} stale entry(s) across {folders} folder(s)"
               if pruned else
               f"Reconcile OK — {folders} folder(s) verified")
        row = self._make_system_row(ts, msg, C_WARNING if pruned else C_SUCCESS,
                                    len(self._row_widgets))
        self._rows_layout.insertWidget(0, row)
        self._row_widgets.insert(0, row)
        while len(self._row_widgets) > MAX_ROWS:
            old = self._row_widgets.pop()
            self._rows_layout.removeWidget(old)
            old.deleteLater()

    def _make_system_row(self, ts: str, message: str, color: str, idx: int) -> QFrame:
        f = QFrame()
        f.setFixedHeight(34)
        f.setStyleSheet(
            f"background-color: {C_ROW_A if idx % 2 == 0 else C_ROW_B}; "
            f"border-radius: 6px; border-left: 3px solid {color};")
        row_layout = QHBoxLayout(f)
        row_layout.setContentsMargins(12, 0, 12, 0)
        row_layout.setSpacing(10)
        ts_lbl = QLabel(ts)
        ts_lbl.setFixedWidth(80)
        ts_lbl.setStyleSheet(f"color: {C_MUTED}; font-size: 12px;")
        msg_lbl = QLabel(message)
        msg_lbl.setStyleSheet(f"color: {color}; font-size: 12px;")
        row_layout.addWidget(ts_lbl)
        row_layout.addWidget(msg_lbl, stretch=1)
        return f

    def _make_row(self, row: dict, idx: int) -> QFrame:
        is_dup = row.get("duplicate", False)
        media_type = row.get("media_type", "photo")
        icon, icon_color = MEDIA_META.get(media_type, ("📁", C_MUTED))
        type_label = media_type.replace("_", " ").title()

        f = QFrame()
        f.setFixedHeight(38)
        f.setStyleSheet(
            f"background-color: {C_ROW_A if idx % 2 == 0 else C_ROW_B}; "
            f"border-radius: 6px;")

        row_layout = QHBoxLayout(f)
        row_layout.setContentsMargins(12, 0, 12, 0)
        row_layout.setSpacing(0)

        def cell(text, width, color,
                 align=Qt.AlignmentFlag.AlignLeft, bold=False, stretch=0):
            lbl = QLabel(text)
            lbl.setAlignment(align | Qt.AlignmentFlag.AlignVCenter)
            style = f"color: {color}; font-size: 12px;"
            if bold:
                style += " font-weight: bold;"
            lbl.setStyleSheet(style)
            if width > 0:
                lbl.setFixedWidth(width)
            row_layout.addWidget(lbl, stretch)

        icon_lbl = QLabel(icon)
        icon_lbl.setFixedWidth(40)
        icon_lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
        icon_lbl.setStyleSheet(f"color: {icon_color}; font-size: 14px;")
        row_layout.addWidget(icon_lbl)

        cell(row.get("_received", ""),          80,  C_MUTED)
        cell(row.get("filename", ""),           -1,  C_TEXT, bold=True, stretch=1)
        cell(type_label,                        110, icon_color,
             align=Qt.AlignmentFlag.AlignCenter)
        cell(_fmt(row.get("size_bytes", 0)),    80,  C_MUTED,
             align=Qt.AlignmentFlag.AlignRight)

        badge = QLabel("Duplicate" if is_dup else "✓ Saved")
        badge.setFixedWidth(90)
        badge.setAlignment(Qt.AlignmentFlag.AlignCenter)
        badge.setStyleSheet(
            f"color: {C_WARNING if is_dup else C_SUCCESS}; "
            f"font-size: 10px; font-weight: bold;")
        row_layout.addWidget(badge)

        return f
