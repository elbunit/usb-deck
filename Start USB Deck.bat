@echo off
chcp 65001 >nul
title USB Deck - agjenti
cd /d "%~dp0pc-agent"

where py >nul 2>nul
if %errorlevel%==0 (set "PY=py -3") else (set "PY=python")

%PY% --version >nul 2>nul
if errorlevel 1 (
  echo.
  echo  Python nuk u gjet.
  echo  Instaloje nga https://www.python.org/downloads/
  echo  dhe ne instalim zgjidh "Add python.exe to PATH".
  echo.
  pause
  exit /b 1
)

%PY% -c "import keyboard, pycaw, PIL, mss, winrt.windows.media.control, winrt.windows.storage.streams" >nul 2>nul
if errorlevel 1 (
  echo Po instaloj librarite e nevojshme - vetem heren e pare...
  %PY% -m pip install --disable-pip-version-check --quiet keyboard pycaw pillow mss winrt-runtime winrt-Windows.Media.Control winrt-Windows.Foundation winrt-Windows.Foundation.Collections winrt-Windows.Storage.Streams
)

%PY% agent.py %*
echo.
pause
