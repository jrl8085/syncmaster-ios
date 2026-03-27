from typing import Callable
import pystray
from PIL import Image, ImageDraw


def _make_icon(size=64) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.ellipse([0, 0, size-1, size-1], fill=(37, 99, 235, 255))
    m = size // 5
    draw.arc([m, m, size-m, size-m], start=30, end=330, fill="white", width=size//8)
    cx, cy, h = size//2, m+2, size//10
    draw.polygon([(cx, cy-h), (cx+h*2, cy+h), (cx-h*2, cy+h)], fill="white")
    return img


class SyncMasterTray:
    def __init__(self, on_show: Callable, on_quit: Callable, on_pause_toggle: Callable):
        self._on_show = on_show
        self._on_quit = on_quit
        self._on_pause_toggle = on_pause_toggle
        self._paused = False
        self._icon = None

    def start(self):
        self._icon = pystray.Icon("syncmaster", _make_icon(), "SyncMaster · Running", self._make_menu())
        self._icon.run()

    def _make_menu(self):
        return pystray.Menu(
            pystray.MenuItem("Open SyncMaster", self._show, default=True),
            pystray.MenuItem(lambda _: "Resume Sync" if self._paused else "Pause Sync", self._toggle),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("Quit", self._quit),
        )

    def update_tooltip(self, text: str):
        if self._icon: self._icon.title = text

    def _show(self, *_): self._on_show()
    def _quit(self, *_):
        if self._icon: self._icon.stop()
        self._on_quit()

    def _toggle(self, *_):
        self._paused = not self._paused
        self._on_pause_toggle(self._paused)
        if self._icon: self._icon.menu = self._make_menu()

    def stop(self):
        if self._icon: self._icon.stop()
