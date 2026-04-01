# -*- mode: python ; coding: utf-8 -*-
import sys
from pathlib import Path
from PyInstaller.utils.hooks import collect_data_files, collect_submodules

block_cipher = None

# Bundle qt_material themes/resources
qt_material_datas = collect_data_files("qt_material")

a = Analysis(
    ["main.py"],
    pathex=["."],
    binaries=[],
    datas=qt_material_datas,
    hiddenimports=[
        # uvicorn
        "uvicorn.logging",
        "uvicorn.loops",
        "uvicorn.loops.auto",
        "uvicorn.loops.asyncio",
        "uvicorn.protocols",
        "uvicorn.protocols.http",
        "uvicorn.protocols.http.auto",
        "uvicorn.protocols.http.h11_impl",
        "uvicorn.protocols.http.httptools_impl",
        "uvicorn.protocols.websockets",
        "uvicorn.protocols.websockets.auto",
        "uvicorn.protocols.websockets.websockets_impl",
        "uvicorn.protocols.websockets.wsproto_impl",
        "uvicorn.lifespan",
        "uvicorn.lifespan.off",
        "uvicorn.lifespan.on",
        # fastapi / starlette internals
        "fastapi",
        "starlette",
        "anyio",
        "anyio._backends._asyncio",
        "anyio._backends._trio",
        # crypto (for SSL cert generation)
        "cryptography",
        "cryptography.hazmat.backends.openssl",
        "cryptography.hazmat.primitives.asymmetric.rsa",
        "cryptography.hazmat.primitives.serialization",
        "cryptography.x509",
        # misc
        "aiosqlite",
        "aiofiles",
        "multipart",
        "multipart.multipart",
        "sniffio",
        "uvicorn.main",
        "email.mime.text",
        "email.mime.multipart",
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.zipfiles,
    a.datas,
    [],
    name="SyncMaster",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=True,           # temporarily enabled for debugging
    disable_windowed_traceback=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon=None,
)
