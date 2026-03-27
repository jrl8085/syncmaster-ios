"""
Main application window — PyQt6 + qt-material.
Includes sidebar navigation, stacked content area, and system tray icon.
"""
import queue
import threading

from PyQt6.QtCore import Qt, QTimer, QSize, QPoint
from PyQt6.QtGui import (QIcon, QPixmap, QPainter, QColor, QBrush,
                          QFont, QAction, QPen)
from PyQt6.QtWidgets import (QMainWindow, QWidget, QHBoxLayout, QVBoxLayout,
                              QFrame, QLabel, QPushButton, QStackedWidget,
                              QSizePolicy, QSystemTrayIcon, QMenu, QApplication,
                              QSpacerItem)

from ..server.config import get_config, update_config
from ..server.ssl_utils import get_local_ip

# ── Palette ──────────────────────────────────────────────────────────────────
C_BG          = "#0D1117"
C_SIDEBAR     = "#090D14"
C_SIDEBAR_SEL = "#1D4ED8"
C_BORDER      = "#1F2937"
C_ACCENT      = "#3B82F6"
C_SUCCESS     = "#22C55E"
C_DANGER      = "#EF4444"
C_TEXT        = "#E5E7EB"
C_MUTED       = "#6B7280"

NAV = [
    ("dashboard", "Dashboard",  "▣"),
    ("history",   "History",    "☰"),
    ("settings",  "Settings",   "⚙"),
]

EXTRA_CSS = f"""
/* ── Window ── */
QMainWindow, QWidget#central {{
    background-color: {C_BG};
}}

/* ── Sidebar ── */
QFrame#sidebar {{
    background-color: {C_SIDEBAR};
    border-right: 1px solid {C_BORDER};
}}
QFrame#statusPill {{
    background-color: #111827;
    border-radius: 8px;
    padding: 2px;
}}
QFrame#divider {{
    background-color: {C_BORDER};
    max-height: 1px;
    min-height: 1px;
}}

/* ── Nav buttons ── */
QPushButton#navBtn {{
    text-align: left;
    padding: 10px 16px 10px 20px;
    border-radius: 9px;
    border: none;
    color: {C_MUTED};
    font-size: 14px;
    background: transparent;
}}
QPushButton#navBtn:hover {{
    background-color: #1F2937;
    color: {C_TEXT};
}}
QPushButton#navBtn:checked {{
    background-color: {C_SIDEBAR_SEL};
    color: white;
    font-weight: bold;
}}

/* ── Cards ── */
QFrame#card {{
    background-color: #161B27;
    border-radius: 12px;
    border: 1px solid #1F2937;
}}
QFrame#cardElevated {{
    background-color: #1A2035;
    border-radius: 10px;
}}

/* ── Labels ── */
QLabel#pageTitle {{
    color: {C_TEXT};
    font-size: 22px;
    font-weight: bold;
}}
QLabel#pageSubtitle {{
    color: {C_MUTED};
    font-size: 13px;
}}
QLabel#sectionTitle {{
    color: {C_TEXT};
    font-size: 15px;
    font-weight: bold;
}}
QLabel#sectionSub {{
    color: {C_MUTED};
    font-size: 11px;
}}
QLabel#logoName {{
    color: {C_TEXT};
    font-size: 16px;
    font-weight: bold;
}}
QLabel#logoSub {{
    color: {C_MUTED};
    font-size: 10px;
}}
QLabel#statusDot {{
    font-size: 10px;
}}
QLabel#serverAddr {{
    color: {C_ACCENT};
    font-size: 12px;
    font-weight: bold;
}}
QLabel#footerLabel {{
    color: {C_MUTED};
    font-size: 10px;
}}

/* ── Stat tile ── */
QFrame#statTile {{
    background-color: #161B27;
    border-radius: 12px;
    border: 1px solid #1F2937;
}}
QLabel#statValue {{
    font-size: 26px;
    font-weight: bold;
    color: {C_TEXT};
}}
QLabel#statLabel {{
    font-size: 11px;
    color: {C_MUTED};
}}

/* ── Feed / table rows ── */
QFrame#feedRow {{
    background-color: #1A2035;
    border-radius: 8px;
}}
QFrame#feedRowAlt {{
    background-color: #161B27;
    border-radius: 8px;
}}

/* ── Scrollbar ── */
QScrollBar:vertical {{
    background: transparent;
    width: 6px;
}}
QScrollBar::handle:vertical {{
    background: #374151;
    border-radius: 3px;
}}
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {{
    height: 0;
}}

/* ── Inputs ── */
QLineEdit {{
    background-color: #0F1117;
    border: 1px solid {C_BORDER};
    border-radius: 6px;
    color: {C_TEXT};
    padding: 6px 10px;
    font-size: 13px;
}}
QLineEdit:focus {{
    border-color: {C_ACCENT};
}}

/* ── Buttons ── */
QPushButton#primaryBtn {{
    background-color: {C_ACCENT};
    color: white;
    border: none;
    border-radius: 8px;
    padding: 10px 24px;
    font-size: 14px;
    font-weight: bold;
}}
QPushButton#primaryBtn:hover {{
    background-color: #2563EB;
}}
QPushButton#secondaryBtn {{
    background-color: #1F2937;
    color: {C_TEXT};
    border: 1px solid {C_BORDER};
    border-radius: 8px;
    padding: 8px 16px;
    font-size: 13px;
}}
QPushButton#secondaryBtn:hover {{
    background-color: #374151;
}}
QPushButton#ghostBtn {{
    background-color: transparent;
    color: {C_MUTED};
    border: 1px solid {C_BORDER};
    border-radius: 8px;
    padding: 8px 16px;
    font-size: 13px;
}}
QPushButton#ghostBtn:hover {{
    background-color: #1F2937;
    color: {C_TEXT};
}}

/* ── Table header ── */
QFrame#tableHeader {{
    background-color: #0D1117;
    border-radius: 0px;
    border-bottom: 1px solid {C_BORDER};
}}
QLabel#colHeader {{
    color: {C_MUTED};
    font-size: 10px;
    font-weight: bold;
    letter-spacing: 1px;
}}
"""


def _make_tray_icon(size: int = 64) -> QIcon:
    from PIL import Image, ImageDraw
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.ellipse([0, 0, size - 1, size - 1], fill=(37, 99, 235, 255))
    m = size // 5
    draw.arc([m, m, size - m, size - m], start=30, end=330, fill="white", width=size // 8)
    cx, cy, h = size // 2, m + 2, size // 10
    draw.polygon([(cx, cy - h), (cx + h * 2, cy + h), (cx - h * 2, cy + h)], fill="white")
    data = img.tobytes("raw", "RGBA")
    qimg_format = __import__("PyQt6.QtGui", fromlist=["QImage"]).QImage
    qi = qimg_format(data, size, size, qimg_format.Format.Format_RGBA8888)
    return QIcon(QPixmap.fromImage(qi))


class SyncMasterWindow(QMainWindow):
    def __init__(self, event_queue: queue.Queue, server_running_event: threading.Event):
        super().__init__()
        self.event_queue = event_queue
        self.server_running = server_running_event
        self._upload_total = 0

        self.setWindowTitle("SyncMaster")
        self.resize(1060, 700)
        self.setMinimumSize(820, 560)

        # Apply custom CSS on top of qt-material
        QApplication.instance().setStyleSheet(
            QApplication.instance().styleSheet() + EXTRA_CSS
        )

        self._build_ui()
        self._setup_tray()

        # Poll event queue every 250 ms
        self._timer = QTimer(self)
        self._timer.timeout.connect(self._poll_events)
        self._timer.start(250)

    # ── Layout ────────────────────────────────────────────────────────────────

    def _build_ui(self):
        central = QWidget()
        central.setObjectName("central")
        self.setCentralWidget(central)

        root = QHBoxLayout(central)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        root.addWidget(self._make_sidebar())

        self._stack = QStackedWidget()
        root.addWidget(self._stack)

        from .tabs.dashboard_tab import DashboardTab
        from .tabs.history_tab import HistoryTab
        from .tabs.settings_tab import SettingsTab

        self._tabs = {
            "dashboard": DashboardTab(),
            "history":   HistoryTab(),
            "settings":  SettingsTab(on_save=self._on_settings_save),
        }
        for tab in self._tabs.values():
            self._stack.addWidget(tab)

        self._show_tab("dashboard")

    # ── Sidebar ───────────────────────────────────────────────────────────────

    def _make_sidebar(self) -> QFrame:
        sb = QFrame()
        sb.setObjectName("sidebar")
        sb.setFixedWidth(224)

        layout = QVBoxLayout(sb)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        # Logo
        logo_wrap = QWidget()
        logo_layout = QHBoxLayout(logo_wrap)
        logo_layout.setContentsMargins(18, 26, 18, 22)
        logo_layout.setSpacing(12)

        icon_lbl = QLabel("⟳")
        icon_lbl.setStyleSheet(
            f"color: {C_ACCENT}; font-size: 26px; font-weight: bold;")
        icon_lbl.setFixedWidth(32)
        logo_layout.addWidget(icon_lbl)

        text_col = QVBoxLayout()
        text_col.setSpacing(1)
        name = QLabel("SyncMaster")
        name.setObjectName("logoName")
        sub = QLabel("Media Backup Server")
        sub.setObjectName("logoSub")
        text_col.addWidget(name)
        text_col.addWidget(sub)
        logo_layout.addLayout(text_col)
        layout.addWidget(logo_wrap)

        # Divider
        div = QFrame()
        div.setObjectName("divider")
        div.setFixedHeight(1)
        layout.addWidget(div)

        # Status pill
        pill_wrap = QWidget()
        pill_layout = QHBoxLayout(pill_wrap)
        pill_layout.setContentsMargins(14, 12, 14, 8)

        pill = QFrame()
        pill.setObjectName("statusPill")
        pill_inner = QHBoxLayout(pill)
        pill_inner.setContentsMargins(12, 8, 12, 8)
        pill_inner.setSpacing(8)

        self._dot = QLabel("●")
        self._dot.setObjectName("statusDot")
        self._dot.setStyleSheet(f"color: {C_SUCCESS}; font-size: 10px;")
        self._status_lbl = QLabel("Server running")
        self._status_lbl.setStyleSheet(f"color: {C_TEXT}; font-size: 12px;")

        pill_inner.addWidget(self._dot)
        pill_inner.addWidget(self._status_lbl)
        pill_inner.addStretch()
        pill_layout.addWidget(pill)
        layout.addWidget(pill_wrap)

        # Nav spacer
        layout.addSpacing(6)

        # Nav buttons
        self._nav_btns: dict[str, QPushButton] = {}
        for tab_id, label, icon in NAV:
            btn = QPushButton(f"  {icon}   {label}")
            btn.setObjectName("navBtn")
            btn.setCheckable(True)
            btn.setAutoExclusive(True)
            btn.setFixedHeight(44)
            btn.setCursor(Qt.CursorShape.PointingHandCursor)
            btn.clicked.connect(lambda _, t=tab_id: self._show_tab(t))
            layout.addWidget(btn)
            layout.setContentsMargins(0, 0, 0, 0)
            self._nav_btns[tab_id] = btn

        # Push footer down
        layout.addStretch()

        # Footer divider
        foot_div = QFrame()
        foot_div.setObjectName("divider")
        foot_div.setFixedHeight(1)
        layout.addWidget(foot_div)

        # Footer: server address
        footer = QWidget()
        foot_layout = QVBoxLayout(footer)
        foot_layout.setContentsMargins(18, 12, 18, 20)
        foot_layout.setSpacing(2)

        cfg = get_config()
        ip = get_local_ip()

        addr_lbl = QLabel("Server Address")
        addr_lbl.setObjectName("footerLabel")
        addr_val = QLabel(f"{ip}:{cfg['port']}")
        addr_val.setObjectName("serverAddr")

        foot_layout.addWidget(addr_lbl)
        foot_layout.addWidget(addr_val)
        layout.addWidget(footer)

        return sb

    # ── Navigation ────────────────────────────────────────────────────────────

    def _show_tab(self, tab_id: str):
        self._stack.setCurrentWidget(self._tabs[tab_id])
        for k, btn in self._nav_btns.items():
            btn.setChecked(k == tab_id)

    # ── Events ────────────────────────────────────────────────────────────────

    def _poll_events(self):
        try:
            while True:
                event = self.event_queue.get_nowait()
                self._handle_event(event)
        except Exception:
            pass

    def _handle_event(self, event: dict):
        t = event.get("type")
        if t == "upload":
            self._upload_total += 1
            self._tabs["dashboard"].on_upload(event)
            self._tabs["history"].on_upload(event)
            if self._tray:
                self._tray.setToolTip(
                    f"SyncMaster · {self._upload_total} files received")
        elif t == "server_status":
            running = event.get("running", True)
            self._status_lbl.setText("Server running" if running else "Server stopped")
            self._dot.setStyleSheet(
                f"color: {C_SUCCESS if running else C_DANGER}; font-size: 10px;")

    # ── System tray ───────────────────────────────────────────────────────────

    def _setup_tray(self):
        self._tray = QSystemTrayIcon(self)
        try:
            self._tray.setIcon(_make_tray_icon())
        except Exception:
            self._tray.setIcon(self.style().standardIcon(
                self.style().StandardPixmap.SP_ComputerIcon))
        self._tray.setToolTip("SyncMaster · Running")

        menu = QMenu()
        open_action = QAction("Open SyncMaster", self)
        open_action.triggered.connect(self.show_from_tray)
        menu.addAction(open_action)
        menu.addSeparator()
        quit_action = QAction("Quit", self)
        quit_action.triggered.connect(QApplication.quit)
        menu.addAction(quit_action)

        self._tray.setContextMenu(menu)
        self._tray.activated.connect(self._tray_activated)
        self._tray.show()

    def _tray_activated(self, reason):
        if reason == QSystemTrayIcon.ActivationReason.DoubleClick:
            self.show_from_tray()

    # ── Window events ─────────────────────────────────────────────────────────

    def closeEvent(self, event):
        event.ignore()
        self.hide()
        self._tray.showMessage(
            "SyncMaster", "Running in the background.",
            QSystemTrayIcon.MessageIcon.Information, 2000)

    def show_from_tray(self):
        self.showNormal()
        self.raise_()
        self.activateWindow()

    def _on_settings_save(self, storage_path: str, port: int):
        update_config(storage_path=storage_path, port=port)
