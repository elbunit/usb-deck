@echo off
chcp 65001 >nul
title USB Deck - hiq nisjen automatike
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p=[Environment]::GetFolderPath('Startup')+'\USB Deck.lnk'; if (Test-Path $p) { Remove-Item $p; 'U hoq: USB Deck nuk niset me vete me Windows-in.' } else { 'Nisja automatike nuk ishte e instaluar.' }"
echo.
echo Nese agjenti eshte duke punuar: kliko me te djathten ikonen prane ores ^> "Mbyll USB Deck".
echo.
pause
