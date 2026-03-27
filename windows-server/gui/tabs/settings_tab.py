from pathlib import Path
from typing import Callable

from PyQt6.QtCore import Qt, QTimer
from PyQt6.QtWidgets import (QWidget, QVBoxLayout, QHBoxLayout, QFrame,
                              QLabel, QPushButton, QLineEdit, QScrollArea,
                              QFileDialog, QSizePolicy)

from ...server.config import get_config, update_config
from ...server.ssl_utils import get_cert_fingerprint, get_local_ip, get_all_local_ips

C_SUCCESS = "#22C55E"
C_WARNING = "#F59E0B"
C_ACCENT  = "#3B82F6"
C_TEXT    = "#E5E7EB"
C_MUTED   = "#6B7280"
C_CARD    = "#161B27"
C_BORDER  = "#1F2937"
C_INPUT   = "#0F1117"


class SettingsTab(QWidget):
    def __init__(self, on_save: Callable):
        super().__init__()
        self._on_save = on_save
        self._save_timer: QTimer | None = None
        self._build()

    # ── Build ─────────────────────────────────────────────────────────────────

    def _build(self):
        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.setSpacing(0)

        # Page header (non-scrolling)
        hdr_widget = QWidget()
        hdr_layout = QVBoxLayout(hdr_widget)
        hdr_layout.setContentsMargins(28, 28, 28, 8)
        hdr_layout.setSpacing(4)
        title = QLabel("Settings")
        title.setObjectName("pageTitle")
        sub = QLabel("Server configuration and security options")
        sub.setObjectName("pageSubtitle")
        hdr_layout.addWidget(title)
        hdr_layout.addWidget(sub)
        outer.addWidget(hdr_widget)

        # Scroll area for card content
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)

        content = QWidget()
        self._cl = QVBoxLayout(content)
        self._cl.setContentsMargins(28, 12, 28, 28)
        self._cl.setSpacing(0)
        self._cl.setAlignment(Qt.AlignmentFlag.AlignTop)

        self._build_storage_card()
        self._build_network_card()
        self._build_security_card()
        self._build_save_row()

        scroll.setWidget(content)
        outer.addWidget(scroll, stretch=1)

    # ── Storage card ──────────────────────────────────────────────────────────

    def _build_storage_card(self):
        self._add_section_header(
            "Storage Location",
            "Directory where uploaded media files are saved on disk")

        card, cl = self._make_card()

        # Path field + browse
        row = QHBoxLayout()
        row.setSpacing(8)
        self._path_edit = QLineEdit(get_config()["storage_path"])
        self._path_edit.setPlaceholderText("Storage path…")
        row.addWidget(self._path_edit, stretch=1)

        browse_btn = QPushButton("Browse…")
        browse_btn.setObjectName("secondaryBtn")
        browse_btn.setFixedWidth(100)
        browse_btn.clicked.connect(self._browse)
        row.addWidget(browse_btn)
        cl.addLayout(row)

        self._cl.addWidget(card)
        self._cl.addSpacing(8)

    # ── Network card ──────────────────────────────────────────────────────────

    def _build_network_card(self):
        self._add_section_header(
            "Network",
            "Listening port · changes apply after server restart")

        card, cl = self._make_card()

        port_row = QHBoxLayout()
        port_row.setSpacing(12)
        port_lbl = QLabel("Port")
        port_lbl.setStyleSheet(f"color: {C_MUTED}; font-size: 13px;")
        port_lbl.setFixedWidth(60)
        self._port_edit = QLineEdit(str(get_config()["port"]))
        self._port_edit.setFixedWidth(110)
        port_row.addWidget(port_lbl)
        port_row.addWidget(self._port_edit)
        port_row.addStretch()
        cl.addLayout(port_row)

        cl.addSpacing(8)

        all_ips = get_all_local_ips()
        for i, ip in enumerate(all_ips):
            ip_row = QHBoxLayout()
            ip_row.setSpacing(12)
            ip_label = QLabel("Local IP" if i == 0 else "")
            ip_label.setStyleSheet(f"color: {C_MUTED}; font-size: 13px;")
            ip_label.setFixedWidth(60)
            ip_val = QLabel(ip)
            ip_val.setStyleSheet(
                f"color: {C_ACCENT}; font-size: 13px; font-weight: bold;")
            ip_row.addWidget(ip_label)
            ip_row.addWidget(ip_val)
            ip_row.addStretch()
            cl.addLayout(ip_row)

        self._cl.addWidget(card)
        self._cl.addSpacing(8)

    # ── Security card ─────────────────────────────────────────────────────────

    def _build_security_card(self):
        self._add_section_header(
            "Security",
            "API key presented by the iPhone · SSL certificate fingerprint")

        card, cl = self._make_card()

        # API key label
        key_lbl = QLabel("API Key")
        key_lbl.setStyleSheet(f"color: {C_MUTED}; font-size: 12px;")
        cl.addWidget(key_lbl)
        cl.addSpacing(6)

        # API key field + buttons
        key_row = QHBoxLayout()
        key_row.setSpacing(8)
        self._key_edit = QLineEdit(get_config()["api_key"])
        self._key_edit.setEchoMode(QLineEdit.EchoMode.Password)
        self._key_edit.setFont(self._mono_font())
        key_row.addWidget(self._key_edit, stretch=1)

        show_btn = QPushButton("Show")
        show_btn.setObjectName("secondaryBtn")
        show_btn.setFixedWidth(70)
        show_btn.clicked.connect(self._toggle_key)
        key_row.addWidget(show_btn)

        copy_btn = QPushButton("Copy")
        copy_btn.setObjectName("primaryBtn")
        copy_btn.setFixedWidth(70)
        copy_btn.clicked.connect(
            lambda: self._copy_to_clipboard(get_config()["api_key"]))
        key_row.addWidget(copy_btn)
        cl.addLayout(key_row)

        # Fingerprint display
        fp = get_cert_fingerprint()
        if fp:
            cl.addSpacing(14)
            fp_card = QFrame()
            fp_card.setObjectName("cardElevated")
            fp_layout = QVBoxLayout(fp_card)
            fp_layout.setContentsMargins(14, 10, 14, 10)
            fp_layout.setSpacing(4)
            fp_title = QLabel("SSL Certificate Fingerprint")
            fp_title.setStyleSheet(f"color: {C_MUTED}; font-size: 11px;")
            fp_val = QLabel(fp)
            fp_val.setFont(self._mono_font(10))
            fp_val.setStyleSheet(f"color: {C_SUCCESS}; font-size: 10px;")
            fp_val.setWordWrap(True)
            fp_layout.addWidget(fp_title)
            fp_layout.addWidget(fp_val)
            cl.addWidget(fp_card)

        # Regenerate cert button
        cl.addSpacing(12)
        regen_btn = QPushButton("Regenerate SSL Certificate")
        regen_btn.setObjectName("ghostBtn")
        regen_btn.setFixedHeight(36)
        regen_btn.clicked.connect(self._regen_cert)
        cl.addWidget(regen_btn, alignment=Qt.AlignmentFlag.AlignLeft)

        self._cl.addWidget(card)
        self._cl.addSpacing(8)

    # ── Save row ──────────────────────────────────────────────────────────────

    def _build_save_row(self):
        self._cl.addSpacing(12)
        row = QHBoxLayout()
        row.setSpacing(16)

        save_btn = QPushButton("Save Settings")
        save_btn.setObjectName("primaryBtn")
        save_btn.setFixedHeight(42)
        save_btn.setFixedWidth(160)
        save_btn.clicked.connect(self._save)
        row.addWidget(save_btn)

        self._saved_lbl = QLabel("")
        self._saved_lbl.setStyleSheet(f"color: {C_SUCCESS}; font-size: 13px;")
        row.addWidget(self._saved_lbl)
        row.addStretch()

        self._cl.addLayout(row)

    # ── Helpers ───────────────────────────────────────────────────────────────

    def _add_section_header(self, title: str, subtitle: str = ""):
        self._cl.addSpacing(20)
        t = QLabel(title)
        t.setObjectName("sectionTitle")
        self._cl.addWidget(t)
        if subtitle:
            s = QLabel(subtitle)
            s.setObjectName("sectionSub")
            self._cl.addWidget(s)
        self._cl.addSpacing(8)

    def _make_card(self) -> tuple[QFrame, QVBoxLayout]:
        card = QFrame()
        card.setObjectName("card")
        cl = QVBoxLayout(card)
        cl.setContentsMargins(18, 16, 18, 16)
        cl.setSpacing(6)
        return card, cl

    @staticmethod
    def _mono_font(size: int = 12):
        from PyQt6.QtGui import QFont
        f = QFont("Courier New", size)
        return f

    def _browse(self):
        folder = QFileDialog.getExistingDirectory(
            self, "Select Storage Folder", self._path_edit.text())
        if folder:
            self._path_edit.setText(folder)

    def _toggle_key(self):
        if self._key_edit.echoMode() == QLineEdit.EchoMode.Password:
            self._key_edit.setEchoMode(QLineEdit.EchoMode.Normal)
        else:
            self._key_edit.setEchoMode(QLineEdit.EchoMode.Password)

    def _copy_to_clipboard(self, text: str):
        from PyQt6.QtWidgets import QApplication
        QApplication.clipboard().setText(text)

    def _save(self):
        path = self._path_edit.text().strip()
        try:
            port = int(self._port_edit.text().strip())
        except ValueError:
            port = 8443
        Path(path).mkdir(parents=True, exist_ok=True)
        update_config(storage_path=path, port=port)
        self._on_save(path, port)
        self._saved_lbl.setText("✓  Settings saved")
        self._saved_lbl.setStyleSheet(f"color: {C_SUCCESS}; font-size: 13px;")
        if self._save_timer:
            self._save_timer.stop()
        self._save_timer = QTimer.singleShot(
            3000, lambda: self._saved_lbl.setText(""))

    def _regen_cert(self):
        from ...server.ssl_utils import generate_self_signed_cert
        generate_self_signed_cert(force=True)
        self._saved_lbl.setText(
            "✓  New certificate generated — restart server to apply")
        self._saved_lbl.setStyleSheet(f"color: {C_WARNING}; font-size: 13px;")
