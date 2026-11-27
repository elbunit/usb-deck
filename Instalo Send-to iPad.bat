@echo off
chcp 65001 >nul
copy /Y "%~dp0pc-agent\sendto\Dergo te iPad (USB Deck).bat" "%APPDATA%\Microsoft\Windows\SendTo\" >nul
if errorlevel 1 (
  echo Nuk u instalua. Provo perseri.
) else (
  echo OK - tani: kliko me te djathten nje PDF ose foto - Send to - Dergo te iPad
)
pause
