# Installation

## Portabel (USB-Laufwerk) oder lokal
1. Ordner auf das Laufwerk kopieren bzw. `Pull.ps1` in den Zielordner legen und ausfuehren:
   `powershell -ExecutionPolicy Bypass -File Pull.ps1`
2. Erster Start mit **Start.cmd** (fragt nach Administratorrechten). Dabei wird **HUMig.exe** erzeugt - ab dann damit starten
   (kein Konsolenfenster, Logo in der Taskleiste, anheftbar). Neu erzeugen / Desktop-Verknuepfung: Einstellungen > Allgemein.
3. Backups landen standardmaessig in `BACKUPS\` neben dem Tool (aenderbar im Tool: Backup-Ordner `...`).
4. **Benutzer-Modus** fuer Benutzer ohne Administratorrechte: **HUMig-Benutzer.exe** (wird zusammen mit HUMig.exe erzeugt) oder **Start-Benutzer.cmd**.
   Der Backup-Ordner muss fuer diese Benutzer beschreibbar sein; wer welche Backups sehen darf, regeln die Ordnerrechte.

## Ordnerrechte (wichtig auf Servern und gemeinsam genutzten PCs)
HUMig laeuft als Administrator. Liegt der Tool-Ordner z. B. unter `C:\Tools`, duerfen normale Benutzer dort standardmaessig Dateien anlegen.
HUMig prueft das beim Start und bietet an abzusichern: Administratoren + SYSTEM Vollzugriff, Benutzer nur Lesen; `Logs` und ein
Backup-Ordner im Tool-Ordner bleiben fuer den Benutzer-Modus beschreibbar (nur eigene Dateien). Pruefen: `icacls C:\Tools\HUMig`.
HUMig nicht im persoenlichen Ordner (OneDrive, Desktop) eines Benutzers betreiben, wenn es dort als Administrator gestartet wird.

## USMT (optional)
Noetig fuer das Modul *Windows-Einstellungen (USMT)* - und damit auch fuer den **Restore auf einen neuen PC, auf dem der Benutzer noch kein Profil hat**: LoadState legt das Profil an (Domaenenkonten). Ohne USMT muss sich der Benutzer vorher einmal am Ziel-PC anmelden, sonst werden die Benutzer-Module uebersprungen. Einrichten: Werkzeug *USMT einrichten (ADK)* oder siehe `BIN\LIESMICH.txt`.

## Remote-Backup/-Restore
Am Ziel-PC muessen erreichbar sein:
- Admin-Freigabe `C$` (Datei- und Druckerfreigabe) - fuer alle Dateien
- PowerShell-Remoting (WinRM) - fuer Registry, Drucker, WLAN, Treiber, USMT
Das Tool zeigt beim *Verbinden* an, was erreichbar ist.

## Softwareverteilung
Installer in `Softwareverteilung\` legen (oder im Fenster *Datei hinzufuegen*). Fuer andere PCs wird PowerShell-Remoting (WinRM) benoetigt,
der eigene PC wird direkt installiert.

## Treiberverteilung
Entpackte Treiber (Ordner mit INF-Dateien) oder Hersteller-Setups in `Treiberverteilung\` legen (oder im Fenster *Ordner/Datei hinzufuegen*,
ZIP/CAB werden entpackt). Remote wie die Softwareverteilung ueber PowerShell-Remoting (WinRM), Administratorrechte noetig.
Kopiert wird bevorzugt ueber die Admin-Freigabe `C$` (Robocopy, deutlich schneller), sonst ueber PowerShell-Remoting.
*Vor Treiber-Updates schuetzen* wirkt nur auf Windows Pro, Education und Enterprise.

## Server-Backup
Am Hyper-V-Host bzw. Server als Administrator starten; Feature *Windows Server-Sicherung* noetig (installierbar aus dem Reiter).
Eine USB-Platte, die schon anders genutzt wird, kann ohne Formatieren uebernommen werden (*Platte einrichten* > *Uebernehmen*, aendert nur die Bezeichnung).
Geplante Sicherungen laufen als Aufgabe unter `\HUMig` in der Aufgabenplanung (SYSTEM) - der Tool-Ordner muss dafuer lokal am Host liegen oder fuer SYSTEM lesbar sein.

## App-Updates (WinGet)
Reiter *App-Updates*, HUMig als Administrator. Am Ziel-PC noetig: WinGet (App Installer; Windows 10 1809+/11, Server 2025), Internet
(PowerShell Gallery fuer das Modul `Microsoft.WinGet.Client`, GitHub fuer PowerShell 7 und viele Installer). Andere PCs ueber
PowerShell-Remoting (WinRM). Ohne angemeldeten Benutzer und fuer den Zeitplan legt HUMig eine eigene PowerShell 7 unter
`C:\Program Files\HUMig\PowerShell7` ab (offizielles ZIP, Pruefsumme geprueft), sofern kein MSI-PowerShell vorhanden ist.

## Update
Button **Update** laedt die neueste Version im Kanal (Pull.ps1): **Stabil** (Standard, freigegebene Versionen) oder **Test** (Einstellungen > Update).
Jede Datei wird per SHA256 gegen `HUMig-files.sha256` des Releases geprueft, ersetzt wird erst, wenn alles stimmt. Ist beim Ersetzen eine Datei gesperrt oder bricht das Update ab, wird auf die bisherige Version zurueckgestellt (Journal `Config\pull-journal.json`). Dateien, die es in der neuen Version nicht mehr gibt, werden entfernt (nur frueher per Update installierte). Lokale Daten (BACKUPS, Config, Softwareverteilung, Treiberverteilung, HUMig.exe) bleiben erhalten.
Bestimmte oder aeltere Version: Rechtsklick auf *Update* > *Andere Version / Vorversion installieren ...* bzw. `powershell -ExecutionPolicy Bypass -File Pull.ps1 -Version 2.0.53`.
Signatur: installiert werden nur Releases, die der Herausgeber signiert hat (Zertifikat ist eingebaut, nichts einzustellen). Der Herausgeber gibt eine getestete Version danach frei (Kanal Stabil). HUMig laeuft je Ordner nur einmal und startet nicht, solange ein Update-Journal liegt. Von v2.0.52 und aelter einmalig auf *Update* klicken - danach gilt das automatisch.
Nur bei einem privaten Repository: einmalig einen Nur-Lese-Token eingeben (Rechtsklick auf *Update* oder Einstellungen > Update).

## Anleitung
Knopf **Anleitung** oder **F1** - wird bei jedem Aufruf aktuell aus dem Repository geladen, ohne Internet die lokale Kopie `Docs\Anleitung.html`.

## Selbsttest
`powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-HUMig.ps1` - Ergebnis in `Test-HUMig.result.txt`.
