@echo off
rem HUMig starten (fordert Administratorrechte an). Besser: HUMig.exe (wird beim ersten Start erzeugt, ohne Konsolenfenster)
set "HM=%~dp0HUMig.ps1"
if not exist "%HM%" (
  echo HUMig.ps1 nicht gefunden in %~dp0 - Pull.ps1 ausfuehren.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "Start-Process -FilePath powershell.exe -Verb RunAs -WorkingDirectory '%~dp0.' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('\"' + $env:HM + '\"'),'-HideConsole'"
