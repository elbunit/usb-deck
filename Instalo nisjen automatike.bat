@echo off
chcp 65001 >nul
title USB Deck - nisja automatike
cd /d "%~dp0pc-agent"

where python >nul 2>nul
if errorlevel 1 (
  echo Python nuk u gjet. Instaloje nga python.org dhe zgjidh "Add python.exe to PATH".
  pause
  exit /b 1
)

echo.
echo  1/3  Po kontrolloj librarite...
python -m pip install --disable-pip-version-check --quiet keyboard pycaw pillow mss numpy pystray winrt-runtime winrt-Windows.Media.Control winrt-Windows.Foundation winrt-Windows.Foundation.Collections winrt-Windows.Storage.Streams

for /f "delims=" %%i in ('python -c "import sys;print(sys.executable)"') do set "PYEXE=%%i"
set "PYW=%PYEXE:python.exe=pythonw.exe%"
if not exist "%PYW%" (
  echo pythonw.exe nuk u gjet te "%PYW%".
  pause
  exit /b 1
)
set "AGENTDIR=%CD%"

echo  2/3  Po e shtoj te programet qe nisen me Windows-in...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p=[Environment]::GetFolderPath('Startup')+'\USB Deck.lnk'; $s=(New-Object -ComObject WScript.Shell).CreateShortcut($p); $s.TargetPath=$env:PYW; $s.Arguments='\"'+$env:AGENTDIR+'\agent.py\" --tray --no-browser'; $s.WorkingDirectory=$env:AGENTDIR; $s.Description='USB Deck'; $s.Save()"
if errorlevel 1 (
  echo Shkurtesa nuk u krijua.
  pause
  exit /b 1
)

echo  3/3  Po e nis tani...
echo.
echo  KUJDES: nese dritarja e zeze e "Start USB Deck" eshte e hapur, mbylle tani.
timeout /t 4 >nul
start "" "%PYW%" "%AGENTDIR%\agent.py" --tray --no-browser

echo.
echo  Gati! USB Deck tani punon pa dritare dhe niset vete kur ndez PC-ne.
echo  Do ta gjesh si ikone te vogel prane ores (poshte djathtas, ndoshta te shigjeta ^^).
echo  Kliko me te djathten mbi ikonen per: editorin, perditesimin, log-un ose per ta mbyllur.
echo.
pause
