# Installation

## Portabel (USB-Laufwerk) oder lokal
1. Ordner auf das Laufwerk kopieren bzw. `Pull.ps1` in den Zielordner legen und ausfuehren:
   `powershell -ExecutionPolicy Bypass -File Pull.ps1`
2. Erster Start mit **Start.cmd** (fragt nach Administratorrechten). Dabei wird **HUMig.exe** erzeugt - ab dann damit starten
   (kein Konsolenfenster, Logo in der Taskleiste, anheftbar). Neu erzeugen / Desktop-Verknuepfung: Einstellungen > Allgemein.
3. Backups landen standardmaessig in `BACKUPS\` neben dem Tool (aenderbar im Tool: Backup-Ordner `...`).
4. **Benutzer-Modus** fuer Benutzer ohne Administratorrechte: **HUMig-Benutzer.exe** (wird zusammen mit HUMig.exe erzeugt) oder **Start-Benutzer.cmd**.
   Der Backup-Ordner muss fuer diese Benutzer beschreibbar sein; wer welche Backups sehen darf, regeln die Ordnerrechte.

## USMT (optional)
Nur fuer das Modul *Windows-Einstellungen (USMT)* noetig - siehe `BIN\LIESMICH.txt`.

## Remote-Backup/-Restore
Am Ziel-PC muessen erreichbar sein:
- Admin-Freigabe `C$` (Datei- und Druckerfreigabe) - fuer alle Dateien
- PowerShell-Remoting (WinRM) - fuer Registry, Drucker, WLAN, Treiber, USMT
Das Tool zeigt beim *Verbinden* an, was erreichbar ist.

## Softwareverteilung
Installer in `Softwareverteilung\` legen (oder im Fenster *Datei hinzufuegen*). Fuer andere PCs wird PowerShell-Remoting (WinRM) benoetigt,
der eigene PC wird direkt installiert.

## Update
Button **Update** laedt die aktuelle Version (Pull.ps1). Lokale Daten (BACKUPS, Config, Softwareverteilung, HUMig.exe) bleiben erhalten.
Nur bei einem privaten Repository: einmalig einen Nur-Lese-Token eingeben (Rechtsklick auf *Update* oder Einstellungen > Update).

## Anleitung
Knopf **Anleitung** oder **F1** - wird bei jedem Aufruf aktuell aus dem Repository geladen, ohne Internet die lokale Kopie `Docs\Anleitung.html`.

## Selbsttest
`powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-HUMig.ps1` - Ergebnis in `Test-HUMig.result.txt`.
