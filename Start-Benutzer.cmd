@echo off
rem HUMig im Benutzer-Modus starten (ohne Administratorrechte): eigenes Profil sichern/wiederherstellen.
rem Besser: HUMig-Benutzer.exe (wird beim ersten Start des Tools erzeugt, ohne Konsolenfenster)
rem Ordnerpfad nur ausserhalb von Klammerbloecken verwenden: ein ")" im Ordnernamen (z.B. "Test (1)") beendet sonst den Block.
set "HM=%~dp0HUMig.ps1"
if not exist "%HM%" goto fehlt
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%HM%" -HideConsole -UserMode
exit /b
:fehlt
echo HUMig.ps1 nicht gefunden in "%~dp0"
pause
exit /b 1
