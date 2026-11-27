@echo off
rem USB Deck - "Send to" > Shto si rruge. Shton dosjet e zgjedhura te "Rruget" ne iPad (agjenti duhet te jete hapur).
for %%F in (%*) do curl -s -X POST "http://127.0.0.1:8790/api/paths_add" --data-urlencode "path=%%~fF" >nul
