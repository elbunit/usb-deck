@echo off
rem USB Deck - "Send to" > Dergo te iPad. Dergon skedaret e zgjedhur te iPad-i (agjenti duhet te jete hapur).
for %%F in (%*) do curl -s -X POST "http://127.0.0.1:8790/api/send_file" --data-urlencode "path=%%~fF" >nul
