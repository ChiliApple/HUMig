@echo off
rem HUMig im Benutzer-Modus starten (ohne Administratorrechte): eigenes Profil sichern/wiederherstellen.
rem Besser: HUMig-Benutzer.exe (wird beim ersten Start des Tools erzeugt, ohne Konsolenfenster)
set "HM=%~dp0HUMig.ps1"
if not exist "%HM%" (
  echo HUMig.ps1 nicht gefunden in %~dp0
  pause
  exit /b 1
)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%HM%" -HideConsole -UserMode
