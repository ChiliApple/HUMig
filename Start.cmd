@echo off
rem HUMig starten (fordert Administratorrechte an). Besser: HUMig.exe (wird beim ersten Start erzeugt, ohne Konsolenfenster)
rem Ordnerpfad nur ueber Variablen und ausserhalb von Klammerbloecken verwenden: ein ")" im Ordnernamen (z.B. "Test (1)")
rem beendet sonst einen Klammerblock vorzeitig, ein Apostroph wuerde den PowerShell-Befehl zerbrechen.
set "HM=%~dp0HUMig.ps1"
set "HMDIR=%~dp0."
if not exist "%HM%" goto fehlt
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "Start-Process -FilePath powershell.exe -Verb RunAs -WorkingDirectory $env:HMDIR -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('\"' + $env:HM + '\"'),'-HideConsole'"
exit /b
:fehlt
echo HUMig.ps1 nicht gefunden in "%~dp0" - Pull.ps1 ausfuehren.
pause
exit /b 1
