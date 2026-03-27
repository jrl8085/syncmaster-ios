import json
import secrets
from pathlib import Path
from typing import Optional

APP_DATA_DIR = Path.home() / "AppData" / "Local" / "SyncMaster"
CONFIG_FILE = APP_DATA_DIR / "config.json"
CERT_FILE = APP_DATA_DIR / "server.crt"
KEY_FILE = APP_DATA_DIR / "server.key"
DB_FILE = APP_DATA_DIR / "manifest.db"
APP_DATA_DIR.mkdir(parents=True, exist_ok=True)

_defaults = {
    "storage_path": str(Path.home() / "Pictures" / "SyncMaster"),
    "port": 8443,
    "api_key": secrets.token_hex(32),
    "host": "0.0.0.0",
}

_config: Optional[dict] = None


def get_config() -> dict:
    global _config
    if _config is None:
        _config = _load()
    return _config


def update_config(**kwargs) -> dict:
    global _config
    cfg = get_config()
    cfg.update(kwargs)
    _save(cfg)
    return cfg


def _load() -> dict:
    if CONFIG_FILE.exists():
        try:
            data = json.loads(CONFIG_FILE.read_text())
            for k, v in _defaults.items():
                data.setdefault(k, v)
            return data
        except Exception:
            pass
    cfg = dict(_defaults)
    _save(cfg)
    return cfg


def _save(cfg: dict):
    CONFIG_FILE.write_text(json.dumps(cfg, indent=2))
