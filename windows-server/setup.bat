@echo off
echo ============================================
echo   SyncMaster Server - Setup
echo ============================================
python --version >nul 2>&1
if errorlevel 1 ( echo ERROR: Python 3.11+ required. && pause && exit /b 1 )
if not exist "venv" ( python -m venv venv )
call venv\Scripts\activate.bat
pip install --upgrade pip -q
pip install -r requirements.txt -q
echo.
echo Done! Run start.bat to launch.
pause
