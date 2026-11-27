@echo off
chcp 65001 >nul
copy /Y "%~dp0pc-agent\sendto\Dergo te iPad (USB Deck).bat" "%APPDATA%\Microsoft\Windows\SendTo\" >nul
copy /Y "%~dp0pc-agent\sendto\Shto si rruge (USB Deck).bat" "%APPDATA%\Microsoft\Windows\SendTo\" >nul
if errorlevel 1 (
  echo Nuk u instalua. Provo perseri.
) else (
  echo OK - tani me te djathten ne Explorer:
  echo   - nje PDF ose foto - Send to - Dergo te iPad
  echo   - nje dosje        - Send to - Shto si rruge  ^(del te "Rruget" ne iPad^)
)
pause
