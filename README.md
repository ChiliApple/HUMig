<h1 align="center"><img src="Assets/logo64.png" width="44" alt="" align="absmiddle"/> HUMig v2</h1>

<p align="center"><b>Benutzerprofil-Migration, PC-Werkzeuge und Hyper-V-Server-Backup für Windows</b><br>
Profile sichern und auf denselben oder einen neuen PC zurückspielen – per USB-Laufwerk oder über das Netzwerk.<br>
Hyper-V-VMs und Host auf rotierende USB-Platten sichern – mit Zeitplan, Prüfung und Verlauf.</p>

<p align="center">
  <a href="https://github.com/ChiliApple/HUMig/releases/latest"><img src="https://img.shields.io/github/v/release/ChiliApple/HUMig?label=Version&color=b9a88a" alt="Version"></a>
  <img src="https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white" alt="PowerShell 5.1">
  <img src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078D6" alt="Windows 10 | 11">
  <img src="https://img.shields.io/badge/Windows%20Server-Hyper--V%20Backup-2E7D32" alt="Windows Server Hyper-V Backup">
  <img src="https://img.shields.io/badge/Oberfl%C3%A4che-WPF-8839ef" alt="WPF">
  <a href="LICENSE"><img src="https://img.shields.io/badge/Lizenz-Nutzung%20frei-orange" alt="Lizenz"></a>
</p>

<p align="center">
  <a href="Docs/Anleitung.html"><b>Anleitung</b></a> ·
  <a href="INSTALL.md">Installation</a> ·
  <a href="CHANGELOG.md">Änderungen</a> ·
  <a href="LICENSE">Lizenz</a>
</p>

---

| | |
|---|---|
| **Backup & Restore** | Dateien, Browser, Office, Windows-Einstellungen, Drucker, WLAN, Netzlaufwerke – Robocopy mit bis zu 128 Threads, inkrementell, mit Prüfung, **Zeitplan** (automatisch auf USB/Netz) |
| **Programm-Katalog** | erkennt rund 280 Programme, sichert deren Einstellungen, Plug-ins, Datenbanken und **Lizenzdateien** mit, schliesst Programme vorher, installiert fehlende am neuen PC nach - mit **Katalog-Editor** |
| **Sicher** | Vorschau vor dem Restore, Prüfsummen-Katalog, Cloud-Dateien (OneDrive, SharePoint …) werden nie heruntergeladen |
| **Werkzeuge** | Fernwartung, AD-Mehrfachaktionen, Inventar, Autopilot-Hash, BitLocker, Profil-Reparatur, Diagnose, Software- und Treiberverteilung |
| **Server-Backup** | Hyper-V-VMs je Schule/Standort auf rotierende USB-Platten (Windows Server-Sicherung), Host-Konfiguration mit Switch-Wiederherstellungs-Skript, Verlauf und Statistik |
| **App-Updates** | installierte Programme ueber **WinGet** aktualisieren - Liste mit Haken, **Ausnahmen** (z.B. Pruefungssoftware) und Quellen je Standort, Verlauf |
| **Benutzer-Modus** | ohne Administratorrechte: eigenes Profil sichern/wiederherstellen, Dateien aus dem Backup holen |
| **Update** | Kanal **Stabil** (freigegebene Versionen) oder **Test**, Vorversion per Klick, jede Datei per **SHA256** geprüft, nur **signierte** Releases werden installiert |
| **Anleitung** | im Tool mit **F1** – aus diesem Repository, passend zur installierten Version |

<table>
  <tr>
    <td align="center"><a href="Docs/img/backup.png"><img src="Docs/img/backup.png" width="260" alt="Backup"/></a><br><sub>Backup</sub></td>
    <td align="center"><a href="Docs/img/restore.png"><img src="Docs/img/restore.png" width="260" alt="Restore"/></a><br><sub>Restore</sub></td>
    <td align="center"><a href="Docs/img/werkzeuge.png"><img src="Docs/img/werkzeuge.png" width="260" alt="Werkzeuge"/></a><br><sub>Werkzeuge</sub></td>
  </tr>
</table>

**Schnellstart:** `Pull.ps1` in einen Ordner legen und ausführen (`powershell -ExecutionPolicy Bypass -File Pull.ps1`), dann **Start.cmd** – ab dem zweiten Start **HUMig.exe** (Administrator) bzw. **HUMig-Benutzer.exe** (Benutzer-Modus).

## Prinzip

| Was | Wie |
|---|---|
| Dateien (Profil, C:\, Zusatzordner, App-Ordner) | Robocopy mit bis zu 128 Threads und Ausnahmelisten |
| Benutzer-Einstellungen | Registry-Export aus dem Hive des Benutzers - wird automatisch geladen, wenn er nicht angemeldet ist |
| Windows-Einstellungen (optional) | Microsoft USMT (ScanState/LoadState), legt beim Restore auch das Profil an |
| Inkrementell | Vorhandenes Backup desselben PCs/Benutzers wird weitergefuehrt - nur neue/geaenderte Dateien werden kopiert |
| Sicherheit | Platzpruefung vor dem Start, Pruefung danach (Vergleich + SHA-256-Stichprobe), **Pruefsummen-Katalog** (spaeter jederzeit pruefbar), Warnung bei unverschluesseltem USB-Laufwerk (BitLocker To Go direkt aus dem Tool) |
| Programme | **Programm-Katalog** erkennt installierte Programme, sichert deren Einstellungen mit, nennt Lizenz-Hinweise und Nacharbeiten und installiert fehlende Programme am neuen PC aus der Softwareverteilung oder ueber WinGet |
| Protokoll | `Bericht_Backup.html` / `Bericht_Restore_*.html` (druckbar, mit Unterschriftsfeldern und abgehakter Checkliste), `manifest.json`, `Pruefsummen.tsv`, `HUMig.log`, `Robocopy.log`; `Backups.html` = Uebersicht aller Backups im Backup-Ordner. Absichtlich ausgelassene Dateien (versteckt/System wie `pagefile.sys`, Nur-Cloud, Ausschlussmuster) werden getrennt ausgewiesen - kein Fehler |

## Bedienung

1. **Computer** waehlen (dieser PC, Name/IP oder **Geraete (AD) ...**) -> **Verbinden** -> **Benutzer** waehlen
2. Reiter **Backup**: Vorlage oder Module anhaken -> *Vorab-Pruefung* / *Groesse ermitteln* (Groesse je Modul + Summe, Rechtsklick = alle Module) -> **Backup starten**.
   Beim Verbinden werden installierte Programme erkannt: deren Einstellungen erscheinen in der Gruppe *Programme* und sind angehakt (Knopf *Programme* = Uebersicht)
3. Reiter **Restore**: Backup waehlen (vorhandene Module werden angehakt), Zielbenutzer im Kopfbereich -> optional *Vorschau* -> **Restore starten** -> Checkliste abhaken
   (*Fehlende Programme installieren ...* vergleicht Backup und neuen PC und installiert aus der Softwareverteilung, sonst ueber WinGet)
4. Reiter **Werkzeuge**: fuer den gewaehlten Computer/Benutzer (lokal oder remote) - siehe unten

Linksklick = Hauptfunktion, Rechtsklick = Zweitfunktion (steht im Tooltip). Konsole: Rechtsklick = leeren.
Anzeige-Groesse: **Strg + Mausrad** bzw. Strg + Plus/Minus, **Strg + 0** = automatisch (kleine Bildschirme werden automatisch verkleinert) - auch in Einstellungen > Allgemein.
Alle Haekchen, Optionen und die zuletzt gewaehlte Vorlage werden gespeichert und beim naechsten Start wieder gesetzt.
Am Ende laengerer Vorgaenge: Ton, Windows-Hinweis und blinkendes Taskleisten-Symbol (mit Fortschritt im Symbol); Dauer immer lesbar (z.B. *1 h 05 min*).
Ein **pulsierender gruener Punkt** (Statusleiste, Reiter Server-Backup) zeigt, dass im Hintergrund noch gelesen/gearbeitet wird. Tabellenspalten passen sich dem Inhalt an.
Start ueber **HUMig.exe** (wird beim ersten Start erzeugt, an Taskleiste anheftbar) oder **Start.cmd**.
**Benutzer-Modus** (ohne Administratorrechte): **HUMig-Benutzer.exe** bzw. **Start-Benutzer.cmd** - nur das eigene Profil auf diesem PC, Module mit Systemzugriff und die meisten Werkzeuge sind ausgeblendet, die Backup-Liste zeigt nur eigene Backups.
Mehrere Standorte: Einstellungen > **Standorte** (Name frei waehlbar; eigener Backup-Ordner, Software-/Treiberverteilung, USMT, Netzwerk-Standardwerte je Standort) - Umschalten oben rechts im Hauptfenster.

## Module (Auszug)

Profil-Dateien, Daten auf C:\, Zusatzordner, Edge, Chrome, Firefox, Office (Signaturen, Vorlagen, PST, OneNote), Office-Registry,
Taskleiste/Hintergrund/Farben, Desktop-Symbole, Startmenue (best effort), Schnellzugriff + Kurznotizen, Schriftarten,
WLAN, Netzlaufwerke, Netzwerkdrucker, Drucker komplett (PrintBrm), Ordnerfreigaben (mit Rechten), ODBC, VPN, USMT, Aufgabenplanung, Treiber, Info-Export,
iPhone-Backups, KeePass, Autodesk. Eigene Module: `Config\modules.json` (Ordner, Dateien, Registry-Schluessel - ohne Programmierung).

**Programm-Katalog** (`Config\apps.default.json`, eigene Eintraege in `Config\apps.json`): rund 280 Programme - u.a. Firefox, Chrome, Edge, Microsoft 365,
Thunderbird, Notepad++, 7-Zip, VLC, LibreOffice, Acrobat/Foxit, GIMP, Inkscape, Audacity, Paint.NET, OBS, VS Code, KeePass/KeePassXC,
FileZilla, PuTTY, WinSCP, mRemoteNG, AnyDesk, TeamViewer, FortiClient VPN, Zotero, Citavi, Arduino, GeoGebra, SketchUp, Autodesk,
SMART Notebook, ActivInspire, Untis, Packet Tracer, Zoom, Teams, dazu Brave, Vivaldi, LibreWolf, Git, GitHub Desktop/CLI, Windows Terminal,
PowerToys, VeraCrypt, KiCad, QGIS, Blender, FreeCAD, PrusaSlicer, Cura, Bambu Studio, Krita, MuseScore, OpenBoard, Wireshark, VirtualBox,
JetBrains-IDEs, DBeaver, HeidiSQL, MobaXterm, RustDesk, Citrix Workspace, Slack, Discord, Telegram, Signal, Opera, Docker Desktop, SSMS, pgAdmin, MySQL Workbench,
WinMerge, TortoiseGit/SVN, Veyon, NVDA, calibre, Anki, OrcaSlicer, Kodi u.v.m. Je Programm: was uebertragbar ist (Einstellungen), Lizenz-Hinweis,
Nacharbeiten (landen in der Checkliste) und passendes Paket der Softwareverteilung. Eintraege ohne Dateien/Registry dienen nur als Hinweis.
**Nicht uebertragbar** steht je Eintrag dabei - z.B. gespeicherte Kennwoerter und Cookies in Chrome, Edge, Brave, Vivaldi (an Windows-Konto und PC gebunden: vorher Browser-Sync oder Kennwort-Export). Geraete-Identitaeten (RustDesk-ID, Syncthing-Schluessel, Chrome-Remotedesktop-Host) werden absichtlich nicht kopiert. Neue Eintraege sind *ungeprueft*, bis sie an einem echten PC bestaetigt sind (Katalog-Editor > Quelle).
**Lizenzen mitnehmen:** Programme mit Lizenzdatei/-schluessel (z.B. WinRAR `rarreg.key`, Total Commander `wincmd.key`, Beyond Compare, Sublime Text) werden mit Lizenz gesichert und sind am neuen PC gleich registriert (Modulname *(+ Lizenz)*).
Eigene Programme in `Config\apps.json` - Eintrag mit `"License": true`, z.B.:
`{ "Apps": [ { "Id": "App_MeinTool", "Name": "Mein Tool", "Detect": "^Mein Tool", "Items": [ { "Type": "Files", "Name": "LIC", "Path": "{PROGRAMFILES}\\MeinTool", "Filter": [ "*.lic" ], "License": true } ] } ] }`
Nicht uebertragbar sind Lizenzen, die an Konto oder Hardware gebunden sind (Microsoft 365, Adobe, Autodesk ...) - dafuer gibt es Hinweise in der Checkliste.

### Programm hinzufuegen (Assistent)

*Programme* > **+ Programm hinzufuegen ...** (auch im Katalog-Editor): installiertes Programm aus der Liste waehlen - HUMig sucht am gewaehlten PC Ordner und Registry-Schluessel mit Programm-/Herstellernamen (AppData Roaming/Local/LocalLow, Dokumente, ProgramData, HKCU\Software, HKLM\SOFTWARE) sowie im Programmordner Plug-ins/Add-ins, Vorlagen, Konfiguration und Lizenzdateien.
Vorschlaege mit Groesse zum Abhaken, Caches/Logs automatisch ausgelassen, Programm-Schliessen mit Prozessnamen vorbelegt, Erkennung automatisch. *Speichern* - oder *Erweitert (Editor)*. Vorschlaege beruhen auf Ordnernamen (immer pruefen); so angelegte Eintraege gelten als ungeprueft.

### Katalog-Editor

*Programme* > **Katalog bearbeiten ...** (auch Einstellungen > Module): alle Eintraege mit Suche und Filter (am PC erkannt, geprueft, ungeprueft, nur Hinweis, eigene, geaendert).
Reiter **Allgemein** (Id, Name, Erkennung + *Testen am PC*, Paket + *Testen*), **Sichern** (Ordner, Dateien, Registry - *Ordner waehlen* wandelt in Platzhalter um, *Pfad pruefen* am gewaehlten PC mit Groesse, Anzeige Benutzer/Maschine),
**Schliessen & Dienste**, **Hinweise** (uebertragbar, nicht uebertragbar, Lizenz, Version, Nacharbeiten), **Quelle** (geprueft am, Links, Notiz).
Gespeichert wird nur in `Configpps.json` (vorher `apps.json.bak`); `apps.default.json` bleibt unveraendert. Eintrag exportieren/importieren (JSON), *Auf Standard zuruecksetzen*. Benutzer-Modus: nur Ansicht.

| Feld | Bedeutung |
|---|---|
| `Id`, `Name`, `Detect` | `App_...`, Anzeigename, regulaerer Ausdruck auf den Programmnamen in *Apps & Features* |
| `Items` | `Type` Folder/Files/Reg, `Name` (Ordner im Backup), `Path` mit Platzhaltern `{APPDATA}` `{LOCALAPPDATA}` `{PROFILE}` `{PROGRAMFILES}` `{PROGRAMFILESX86}` `{PROGRAMDATA}` `{SYSTEMDRIVE}` `{WINDIR}` `{PUBLIC}` oder `Key` (HKCU/HKLM), `Filter`, `XD`, `XF`, `NoHidden`, `License` |
| `Role`, `DbKind` (je Item) | Settings / Plugins / Data / **Database** / License / Template; bei Database `File` (SQLite, Access, KeePass - SQLite `-wal`/`-shm`/`-journal` werden mitkopiert) oder `Service` |
| `CloseProcess` | Prozessnamen ohne .exe - laeuft das Programm, fragt HUMig vor Backup/Restore: **schliessen**, *schliessen, notfalls beenden*, *ueberspringen* oder *trotzdem kopieren*. Geplante Backups beenden nie ein Programm (Modul wird uebersprungen) |
| `StopService` | Dienstnamen - vor dem Kopieren gestoppt, danach **immer** wieder gestartet (nur als Administrator; fuer Dienst-Datenbanken wie SQL Server Express) |
| `Transfer`, `NotTransfer`, `License`, `Version`, `After` | Hinweise; `NotTransfer`, `Version` und Datenbank-Hinweise kommen zusaetzlich zu `After` in die Checkliste nach dem Restore |
| `Package` | regulaerer Ausdruck auf das Paket in der Softwareverteilung |
| `Verified` | `{ "Date": "JJJJ-MM-TT", "Sources": [ "https://..." ], "Note": "..." }` - fehlt = ungeprueft (Spalte *Geprueft* in der Uebersicht) |

Beispiel: `{ "Id": "App_Beispiel", "Name": "Beispiel", "Detect": "^Beispiel", "Items": [ { "Type": "Folder", "Name": "CFG", "Path": "{APPDATA}\\Beispiel", "Role": "Settings" }, { "Type": "Files", "Name": "DB", "Path": "{APPDATA}\\Beispiel\\data", "Filter": [ "*.sqlite" ], "Role": "Database", "DbKind": "File" } ], "CloseProcess": [ "beispiel" ], "NotTransfer": "Gespeicherte Kennwoerter (DPAPI)", "Verified": { "Date": "2026-09-29", "Sources": [ "https://..." ] } }`

Robocopy-Fehler (z.B. gesperrte Datei) nennen jetzt die betroffenen Dateien im Protokoll und Bericht.

### Datenbanken suchen

Werkzeuge > Benutzerprofil > **Datenbanken suchen**: findet lokale Datenbanken (SQLite, Access, KeePass, SQL Server, Firebird) im Profil (auf Wunsch aller Benutzer), in ProgramData, Programmordnern und auf allen Festplatten sowie Datenbank-Dienste (SQL Server, Firebird, MySQL/MariaDB, PostgreSQL).
Ergebnis je Ordner mit Art, Ort, Anzahl, Groesse, zuletzt geaendert und *Geoeffnet* (Programm laeuft). Uebernehmen als **Zusaetzliche Ordner** oder **Als Katalog-Eintrag anlegen** (Editor vorausgefuellt: Rolle Datenbank, Platzhalter-Pfad, Dienste - dann schliesst HUMig das Programm vor Backup/Restore selbst).
Fehlt beim Restore das Ziel-Laufwerk (z.B. `D:` am neuen PC), kommt ein verstaendlicher Hinweis statt eines Kopierfehlers - die Daten bleiben im Backup.

## Backup-Optionen

| Option | Wirkung |
|---|---|
| Vorhandenes Backup aktualisieren | Gibt es schon ein Backup dieses PCs/Benutzers, wird es weitergefuehrt (umbenannt auf das aktuelle Datum). Nicht gewaehlte Module aus frueheren Durchlaeufen bleiben erhalten; geloeschte Dateien bleiben im Backup. |
| Platz vor dem Start pruefen | Simuliert das Backup gegen das Ziel (zaehlt nur, was wirklich kopiert wird) und startet nicht, wenn der Platz nicht reicht (Rueckfrage: trotzdem starten). |
| Backup danach pruefen | Vergleich Quelle/Backup und Pruefsummen-Stichprobe (SHA-256) unveraenderter Dateien. |
| Pruefsummen-Katalog | Standard aus. SHA-256 aller Dateien im Backup (`Pruefsummen.tsv`, inkrementell - der erste Lauf dauert lange). Reiter Restore > *Backup pruefen* erkennt spaeter beschaedigte/fehlende Dateien (USB-Stick, NAS). Rechtsklick = Katalog fuer aeltere Backups erstellen. |
| OneDrive/SharePoint: lokale Dateien mitsichern | Aus: Cloud-Ordner werden ausgelassen. Ein: nur Dateien, die am PC vorhanden sind - Nur-Cloud-Dateien werden nie heruntergeladen. |
| Pfade ausschliessen | Einzelne Ordner/Dateien weglassen - auch direkt aus *Grosse Dateien ...* (groesste Ordner und Dateien der letzten Messung). |
| Zusaetzliche Ordner | Beliebige Ordner mit vollem Pfad. Sind Ordner eingetragen, bleibt das Modul angehakt (auch nach *Keine*/Vorlagenwechsel) - so lassen sich auch nur diese Ordner sichern. |

### Zeitplan (automatisches Backup)

Knopf **Zeitplan ...** im Reiter Backup: das **eigene Profil** an diesem PC automatisch sichern - mit der aktuellen Auswahl (Module, Zusaetzliche Ordner, Ausschluesse, Optionen, Backup-Ordner). HUMig muss dafuer nicht geoeffnet sein.
- **Fortlaufend** (vorhandenes Backup aktualisieren, nur Aenderungen) oder **Neues Backup** (eigener Stand) - kombinierbar, z.B. taeglich fortlaufend + sonntags neu = je Woche ein fester Stand plus ein aktueller
- **Taeglich**, **woechentlich** oder **bei Anmeldung** (mit Verzoegerung); verpasste Laeufe werden nachgeholt
- Geplante Aufgabe im Konto des Benutzers **ohne Kennwort** (laeuft, solange er angemeldet ist) - auch im Benutzer-Modus; ohne Adminrechte nur Module des eigenen Profils
- Ziel: USB-Laufwerk wird an seiner **Bezeichnung** erkannt (Buchstabe darf wechseln), Netzlaufwerk als UNC-Pfad; fehlt das Ziel, wird der Lauf uebersprungen und gemeldet
- Optional **alte Backups automatisch loeschen** (neueste N dieses Benutzers/PCs bleiben, Standard aus, nur nach erfolgreichem Lauf)
- Optional **USB-Laufwerk danach auswerfen** (Schutz vor Verschluesselungstrojanern, auch ohne Adminrechte; vor dem naechsten Lauf wieder anstecken) - nur bei USB-/Wechsellaufwerk als Ziel
- Windows-Meldung nach jedem Lauf oder nur bei Problemen; Rechtsklick auf *Zeitplan ...* = verwalten (jetzt starten, Protokoll, Bericht, loeschen)
- Dateien: `%LOCALAPPDATA%\HUMig\Zeitplaene\` (Definition + `Logs\`), Aufgabe *HUMig Backup - Benutzer - Name* in der Aufgabenplanung

Vorlagen: Standard, Komplett, Nur Browser + Office, Neuer PC (mit USMT), **Notebook** (ohne C:\\), **Buero-PC** (mit Druckertreibern, Schriftarten), **Minimal** - eigene in `Config\modules.json`.

## Restore und Backups verwalten

| Knopf / Option | Wirkung |
|---|---|
| Vorschau: was wird ueberschrieben? | Zeigt je Datei: neu / ueberschreibt aeltere Zieldatei / **Zieldatei neuer** / gleich - nach dem Restore auch als Kontrolle |
| Neuere Dateien am Ziel behalten | Robocopy `/XO`: am Ziel neuere Dateien werden nicht ueberschrieben |
| Checkliste | Nach dem Restore abhaken (Punkte in Einstellungen > Restore + Nacharbeiten der erkannten Programme) - Stand und Bemerkung landen im Restore-Protokoll |
| Fehlende Programme installieren ... | Programmliste des Backups mit dem Ziel-PC vergleichen, fehlende nacheinander installieren (Softwareverteilung, sonst WinGet) |
| Backup pruefen | Gegen den Pruefsummen-Katalog (Ergebnis `Pruefung_*.txt`, Status in der Uebersicht) |
| Vergleichen ... | Zwei Backups (z.B. derselbe Benutzer vorher/nachher): geaendert, nur in A, nur in B |
| Uebersicht | `Backups.html` im Backup-Ordner: alle Backups mit Status, Groesse, Pruefung, Links zu den Protokollen (Filter, Sortierung) |
| Alte Backups ... | Aufbewahrung nach Regel: je PC + Benutzer die neuesten N behalten, aeltere nach X Tagen vorschlagen (Einstellungen > Allgemein) - Loeschen immer mit Rueckfrage, ganz oder gar nicht (vorher jede Datei geprueft; schreibgeschuetzte Dateien/Ordner und Backups in OneDrive-Ordnern werden mit geloescht) |

Beim Restore werden mitgesicherte OneDrive-Dateien nie in den Sync-Ordner geschrieben (dort koennten neuere Cloud-Versionen ueberschrieben werden);
optional landen sie in `Profil\OneDrive-Wiederherstellung`.

## Softwareverteilung

Pakete in den Ordner `Softwareverteilung\` legen (oder im Fenster *Datei hinzufuegen*; anderer Ordner/Freigabe: Einstellungen > Allgemein):
- **eine Datei** (`.msi`, `.exe`, `.msp`) = ein Paket
- **ein Unterordner** = ein Paket mit allen Dateien (Installer + Zubehoer); Ordner mit `_` am Anfang werden ignoriert

Das Tool liest die Installer aus und schlaegt die Silent-Parameter vor (MSI-Eigenschaften, Inno Setup, NSIS, WiX Burn, InstallShield,
Advanced Installer, Squirrel, 7-Zip-SFX - bei unbekanntem Framework nur geraten, Herstellerdoku pruefen). Pro Paket gespeichert:
Name, Installer, Parameter, Erkennung (ProductCode oder Name + Mindestversion), Erfolgs-ExitCodes, Timeout.
Installiert wird auf dem **gewaehlten Computer** oder auf **mehreren PCs** (Auswahl aus dem AD mit OU/Filter oder Namen eintragen; bis zu 8 gleichzeitig); bereits installierte werden uebersprungen.

**Installierte Software** (Werkzeuge): Liste des gewaehlten Computers mit Filter, CSV und Drucken. Markierte Programme
lassen sich direkt **deinstallieren** (nacheinander, still, ohne automatischen Neustart): MSI per `msiexec /x`, sonst der
stille Befehl des Herstellers bzw. der Deinstaller mit Parametern (Vorschlag fuer Inno Setup/NSIS, vor dem Start pruefbar).
Ergebnis je Programm in der Konsole (entfernt / Neustart noetig / Fehler mit ExitCode), danach wird die Liste neu geladen.

## Treiberverteilung

Eigene Treiber (z.B. eine bestimmte Grafiktreiber-Version) aus einem eigenen Ordner `Treiberverteilung\` ausrollen
(Werkzeuge > *Treiber installieren*; anderer Ordner/Freigabe: Einstellungen > Allgemein oder je Standort):
- **ein Unterordner** = ein Paket: entpackter Treiber mit INF-Dateien (auch in Unterordnern) und/oder Hersteller-Setup; `_` am Anfang = ignoriert
- **eine EXE/MSI** direkt im Ordner = Setup-Paket; *Datei hinzufuegen* entpackt ZIP und CAB (z.B. Microsoft Update-Katalog) als eigenes Paket

Pro Paket (`hu-driver.json`): Art **INF** (`pnputil /add-driver *.inf /subdirs /install` - Windows installiert, wenn der Treiber besser/neuer ist)
oder **Setup** (Silent-Parameter, Erfolgs-ExitCodes, Timeout), *nur passende Hardware* (sonst nur in den Treiberspeicher),
**Treiber erzwingen** (nur INF: diese Version auch ueber einen neueren/besser bewerteten Treiber, per `UpdateDriverForPlugAndPlayDevices` mit Force).
Das Tool liest die INF-Dateien (Klasse, Anbieter, Version, Hardware-IDs) und vergleicht am Ziel-PC mit den Geraeten
(`Win32_PnPEntity`) und dem aktiven Treiber (`Win32_PnPSignedDriver`): *Am gewaehlten PC pruefen* zeigt das ohne Installation;
beim Verteilen (gewaehlter Computer, mehrere PCs aus der AD-Auswahl oder Mehrfachaktion, bis zu 8 gleichzeitig) werden PCs ohne passende Hardware
bzw. mit derselben aktiven Version uebersprungen - diese Pruefung laeuft vor der Kopie, uebersprungene PCs bekommen nichts kopiert.
Kopiert wird ueber die Admin-Freigabe `C$` (Robocopy, schnell; sonst ueber PowerShell-Remoting), bei Art INF nur die Unterordner mit INF-Dateien.
Erweiterungs-INFs (Klasse Extension/SoftwareComponent) werden mitinstalliert, zaehlen aber nicht fuer Versionsvergleich, Erzwingen und Schutz. Ergebnis je PC mit aktiver Version und Neustart-Hinweis, Log `C:\Windows\Temp\HU_DRV_*.log`.
**Vor Treiber-Updates schuetzen** (je Paket, nur Windows **Pro/Education/Enterprise**): nach der Installation setzt HUMig die Richtlinie
*Installation von Geraeten verhindern, die diesen Geraete-IDs entsprechen* fuer die betroffenen Geraete - Windows Update ersetzt den Treiber dann nicht mehr.
Eigene Sperren hebt HUMig fuer spaetere Installationen selbst auf; *Sperren am PC ...* zeigt und entfernt sie. GPO/Intune-Richtlinien zur Geraeteinstallation haben Vorrang.

## Werkzeuge

| Bereich | Werkzeuge |
|---|---|
| Computer | Fernwartung aktivieren (WinRM, RDP, C$, Firewall - ueber WMI), Umbenennen, IP-Adresse/DHCP, lokale Gruppen (Admins, Netzwerkkonfigurations-Operatoren, RDP, Benutzer), Autologon (LSA-Geheimnis), Sperrbildschirm/Energie, Firewall/Netzwerkprofil, angemeldete Benutzer abmelden, Nachricht, Neustart/Herunterfahren, Netzwerktest, **Geraete (AD) / Mehrfach** (Aktionen auf vielen PCs parallel), **Remote-PowerShell/-CMD**, **Inventar mehrerer PCs** (CSV, optional mit Software), **BitLocker-Schluessel** (in AD/Entra ID sichern), **Autopilot-Hash** (auch viele PCs in einer CSV), **Wake-on-LAN**, **Laufwerke (C$)** (auch USB-Sticks und Freigaben am Remote-PC im Explorer), **Uebermittlungsoptimierung**, **Ordnerfreigaben** (Rechte anzeigen, aus Backup uebernehmen), **USMT einrichten (ADK)** |
| Benutzerprofil | Profil erneuern (Test) + zurueckholen, Profilordner umbenennen, **Profil einem anderen Konto zuweisen** (Domaene -> lokal), Windows-Apps neu registrieren, Gruppenrichtlinien-Ergebnis, Aufgaben aus Backup importieren, **alte Profile loeschen**, **Datenbanken suchen** (lokale Datenbanken + Datenbank-Dienste, als Zusatzordner oder Katalog-Eintrag uebernehmen), **wichtige Dateien suchen** (PST, KeePass, Access ... ausserhalb des Profils), **im Backup suchen** (einzelne Dateien herauskopieren) |
| Diagnose / Wartung | Ereignisse, Akku-Bericht, Aktivierung Windows/Office, Entra ID/Intune (Status + Sync), Domaene/Zeit/Kerberos, Druckwarteschlange, Speicher aufraeumen (inkl. Windows.old), Systemdateien reparieren (DISM/SFC) |
| Software | Softwareverteilung, **Treiberverteilung**, installierte Software + Deinstallation |
| Dieser PC | Systemprogramme, .exe als Admin, Anmeldedaten (credwiz, anzeigen/loeschen), Hersteller-Treiber-Links (Seriennummer des gewaehlten Computers, auch remote) |

Remote-Werkzeuge brauchen PowerShell-Remoting (WinRM) am Ziel-PC - fehlt es, schaltet *Fernwartung aktivieren* es ueber WMI (Port 135) ein. Aenderungen erfolgen immer mit Rueckfrage;
Profil-Werkzeuge sichern vorher Registry (und Dateirechte) unter `C:\ProgramData\HUMig` am Ziel-PC.

**Profil einem anderen Konto zuweisen:** nicht uebertragbar sind mit Windows-DPAPI verschluesselte Daten
(gespeicherte Kennwoerter in Browser/Anmeldeinformationsverwaltung, Zertifikate mit privatem Schluessel, EFS);
OneDrive/Office/Teams neu anmelden. Entra-ID-Konten werden nicht unterstuetzt. Vorher ein Backup machen.

## Server-Backup (Hyper-V-Host)

Reiter **Server-Backup** (als Administrator auf Windows Server - Hyper-V-Host: VMs; Server ohne Hyper-V: Laufwerke und System des Servers selbst):

- **Profile** je Schule/Standort (Name frei, umbenennbar mit Verlauf; Kopie auf jeder Platte): VMs, Platten-Bezeichnung (z.B. `HUMIG-SCHULE1-1`, `-2` ...), Anzahl Platten (Rotation + ausgelagert), Optionen
- **Platte einrichten**: nur USB-Platten, loeschen + GPT + NTFS 64K + Bezeichnung; Platten werden beim Anstecken an der Bezeichnung erkannt
- **Platte uebernehmen** (ohne Formatieren): schon anders genutzte Platte nur umbenennen, Daten bleiben; Rueckfrage mit Belegung/Ordnern, zweite Warnung wenn schon eine Windows-Sicherung dieses Hosts darauf liegt (gleicher Ordner `WindowsImageBackup\<Host>`), doppelte Bezeichnung wird abgelehnt
- **Sichern** mit `wbadmin start backup -hyperv` (online ueber VSS), danach Pruefung (Version + enthaltene VMs), optional Host-System (`-allCritical`)
- **Laufwerke dieses Servers**: Volume-Sicherung (blockbasiert, einzelne Dateien wiederherstellbar) - z.B. fuer physische Server ohne Hyper-V
- **Host-System** (Option, `-allCritical`): nur der Host selbst - Systemlaufwerk C: mit Windows, Hyper-V-Rolle, Switches, Einstellungen sowie EFI-/Boot-/Wiederherstellungspartition. Datenlaufwerke mit den VMs (z.B. D:) sind **nicht** enthalten - dafuer die VM-Sicherung. Fuer eine komplette Wiederherstellung nach Totalausfall: Host-System **und** VMs sichern
- Die Sicherungen sind normale Windows-Server-Sicherungen (`WindowsImageBackup`) - wiederherstellbar auch ohne HUMig mit `wbadmin.msc`, `wbadmin` oder dem Windows-Server-Installationsmedium (Systemimage-Wiederherstellung)
- **Host-Konfiguration**: virtuelle Switches, SET-Teams, Host-vNICs mit VLAN, IP, Netzwerkkarten, VM-Einstellungen als HTML/JSON + `Restore-VMSwitches.ps1`
- **Verlauf/Statistik** (mit Hinweis je Lauf, Doppelklick = Bericht) auf der Platte und im Tool-Ordner: letzte Sicherung je Platte, Rotationsempfehlung, Warnung nach 14 Tagen
- **Archiv-Platten** (`<Bezeichnung>-A1`, `-A2` ... - Profil *Bearbeiten*): von der Rotation ausgenommen, faellig nach einstellbarem Abstand (Standard 30 Tage), Erinnerung zum Abziehen und getrennten Lagern - damit die Sicherung weit genug zurueckreicht, wenn Schadsoftware laenger unbemerkt war
- **Status je Lauf**: *OK* (alles gesichert und geprueft), *OK (Hinweis)* (vollstaendig, aber etwas zu wissen - z.B. VM offline gesichert), *Warnung* (nicht alles einwandfrei, z.B. Pruefung oder Host-System), *Fehler*
- **Bericht je Lauf** (`Bericht.html`, Doppelklick im Verlauf): Status mit Erklaerung, Hinweise mit "Was tun", alle Dateien als Links mit Erklaerung, komplettes Protokoll. *wbadmin* = Befehlszeile der Windows Server-Sicherung, die HUMig aufruft
- **Offline-Hinweis**: VMs, die Hyper-V nur offline sichern kann (z.B. dynamische Datentraeger im Gast), werden markiert, vor dem Start gemeldet und der Grund steht im Bericht
- **Zeitplan**: einmalig, taeglich oder woechentlich als geplante Aufgabe (SYSTEM, ohne Anmeldung) - z.B. grosse VMs ueber Nacht
- **Ereignisanzeige**: jeder Lauf schreibt ins Protokoll *Anwendung*, Quelle `HUMig` - ID 1000 OK, 1001 Warnung, 1002 Fehler (Ueberwachung der Nachtsicherung)
- **Host-System-Pruefung**: VMs mit Dateien auf C: werden angezeigt (werden beim Host-System mitgesichert)
- **Zeitplan-Pruefung**: sucht in der ganzen Aufgabenplanung nach anderen Sicherungsaufgaben (frei definierbare Suchwoerter, Standard *backup, sicherung, wbadmin, veeam, acronis*, `-Wort` schliesst aus) und Zeitplaenen anderer Profile; Ueberschneidungen in den naechsten 14 Tagen werden beim Planen gemeldet
- **Nur ein Vorgang gleichzeitig**: vor dem Start prueft HUMig auf eine laufende Sicherung/Wiederherstellung am Host - manuell mit Rueckfrage, im Zeitplan automatisch warten (hoechstens 8 h); meldet wbadmin trotzdem einen weiteren Vorgang, bis zu zwei neue Versuche
- **Verlauf pflegen**: Rechtsklick im Verlauf entfernt markierte oder alle fehlgeschlagenen Laeufe (Sicherung und Bericht auf der Platte bleiben); abgebrochene Laeufe stehen mit Status *Fehler* und Bericht im Verlauf; Dauer lesbar (z.B. *6 h 12 min*)
- **HUMig schliessen waehrend einer Sicherung**: Rueckfrage - Sicherung stoppen, im Hintergrund weiterlaufen lassen (ohne Verlauf/Bericht) oder offen lassen
- **Auswerfen** (Schreibcache leeren), **Versionen**, **Wiederherstellen** ueber die Windows Server-Sicherung
- **Nach Sicherung** je Platte (auch im Zeitplan): nichts tun, **auswerfen** oder **offline schalten** (kein Laufwerksbuchstabe; naechster geplanter Lauf bzw. *Aktualisieren* schaltet wieder online) - Anzeige unter der Ziel-Platte

Voraussetzung: Feature *Windows Server-Sicherung* (installierbar aus dem Reiter).

**Schnellstart:** HUMig als Administrator am Hyper-V-Host starten -> USB-Platte anstecken, *Aktualisieren* -> VMs anhaken, *Neu ...*, *Profil speichern*
-> Zeile unter der Ziel-Platte gruen (Platte des Profils erkannt) -> *Server-Backup starten* -> *Auswerfen*, abziehen, naechstes Mal die Platte laut Rotation.

Erfahrungswerte: VMs laufen weiter (Online-Sicherung). Jede Sicherung liest die VMs komplett (USB 3 rund 2 GB/min, 34-GB-VM ca. 18 min);
auf der Platte braucht jede weitere Version nur die Aenderungen (zweite Version einer 34-GB-VM unter 1 GB).

## App-Updates (WinGet)

Reiter **App-Updates** (neben *Werkzeuge*, HUMig als Administrator): installierte Programme ueber WinGet aktualisieren - am oben gewaehlten PC oder an **mehreren PCs / EDV-Saal** (AD-Auswahl, WinRM, parallel).
- **Updates suchen** -> Liste je PC mit Haken (installiert, neu, Bereich, Quelle, Paket-ID) -> **Angehakte** bzw. **Alle aktualisieren** (still, je PC nacheinander, Ergebnis sofort in der Konsole); laufende Programme werden an diesem PC vorher erkannt (schliessen / notfalls beenden / nicht aktualisieren)
- Gelesen wird am Ziel-PC im Konto des **angemeldeten Benutzers** (sieht Programme fuer alle Benutzer und nur fuer ihn installierte); ist niemand angemeldet, als **SYSTEM mit PowerShell 7** (Programme fuer alle Benutzer). Das Modul `Microsoft.WinGet.Client` installiert HUMig bei Bedarf (alle Benutzer); PowerShell 7: vorhandenes MSI oder eigene Kopie aus dem offiziellen ZIP-Paket (Pruefsumme geprueft) unter `Programme\HUMig\PowerShell7`. Aktualisiert wird fuer alle Benutzer als **SYSTEM** (winget.exe, ohne UAC), eigene Programme im Benutzerkonto
- **Zeitplan**: geplante Aufgabe *HUMig App-Updates* an den Ziel-PCs (taeglich / Wochentage, Uhrzeit, PC wecken, verpasste Termine nachholen) - aktualisiert als SYSTEM alle Programme fuer alle Benutzer ausser den Ausnahmen; **Zeitplaene ansehen**: naechster/letzter Lauf, Ergebnis, Fortschritt eines laufenden Laufs, Protokoll, Verlauf uebernehmen, entfernen
- **Ausnahmen** je Standort (Muster auf Paket-ID oder Name, mit Grund) - nie aktualisiert, auch nicht vom Zeitplan; vorbelegt: selbstaktualisierende Programme (Edge, Chrome, Teams, Office, OneDrive, Autodesk Fusion), Pruefungssoftware (Next-Exam, Safe Exam Browser) und WSL (ueber WinGet nicht aktualisierbar)
- Findet WinGet ein Programm als SYSTEM nicht (nur fuer einen Benutzer installiert), versucht HUMig es automatisch im Konto des angemeldeten Benutzers; WinGet-Fehlercodes werden als Klartext angezeigt (z.B. *Datei in Benutzung*, *Pruefsumme passt nicht*)
- **Quellen** je Standort (Standard nur *winget*), eigene Quelle hinzufuegen/entfernen; **Verlauf** aller Updates
- **Fehlende Programme installieren** (nach dem Restore): ohne Paket in der Softwareverteilung ueber WinGet, wenn der Katalog-Eintrag eine `WingetId` hat
- Grenzen: andere PCs brauchen WinRM; Programme nur fuer einen Benutzer nur, wenn er angemeldet ist; Installer im Benutzerbereich, die Adminrechte verlangen, schlagen fehl; Windows Server 2019/2022 ohne WinGet

## Update

- **Kanal Stabil** (Standard): nur freigegebene Versionen - fuer Server und Schul-PCs. **Kanal Test**: neue Versionen vor der Freigabe (Einstellungen > Update)
- **Vorversion**: Rechtsklick auf *Update* > *Andere Version / Vorversion installieren ...*
- **Pruefung**: jede Version hat `HUMig-files.sha256` (von den automatischen Tests erstellt); das Update laedt alle Dateien, prueft sie und ersetzt erst dann - bei einer Abweichung bleibt alles unveraendert
- **Signatur**: der Herausgeber signiert die Pruefsummen-Datei jedes Releases (`HUMig-files.sha256.p7s`). HUMig installiert nur Releases mit gueltiger Signatur des eingebauten Zertifikats - nichts einzustellen. Eine Version, die jemand anderer auf GitHub ablegt, wird abgelehnt. Neue Versionen werden erst nach der Signatur angeboten
- **Eigene Quelle** (eigenes Repo): Fingerabdruck des eigenen Zertifikats unter Einstellungen > Update; signieren mit Rechtsklick auf *Update* > *Release signieren* (erscheint nur auf dem PC mit dem privaten Schluessel) oder `Tools\Sign-HUMigRelease.ps1`
- **Ordnerrechte**: HUMig prueft beim Start als Administrator, ob Nicht-Admins im HUMig-Ordner schreiben/anlegen duerfen, und bietet an abzusichern (Admins + SYSTEM Vollzugriff, Benutzer Lesen; Logs/Backup-Ordner fuer den Benutzer-Modus nur eigene Dateien). Ein Nach-Skript laeuft nur, wenn die Datei nicht fuer Nicht-Admins beschreibbar ist
- **Automatische Tests** bei jedem Push (Windows PowerShell 5.1): Syntax, XAML und Steuerelemente, PSScriptAnalyzer, Pester-Tests, Selbsttest, beim Release zusaetzlich der komplette Update-Weg

## Grenzen

- Gespeicherte Browser-Kennwoerter/Cookies: durch Windows-Verschluesselung meist nicht uebertragbar -> Browser-Sync verwenden
- Taskleisten- und Startmenue-Pins unter Windows 11 nur eingeschraenkt
- USMT: keine Migration zwischen AD- und Entra-ID-Geraeten (laut Microsoft)
- OneDrive/SharePoint: Standard = auslassen (Cloud); Nur-Cloud-Dateien werden auch mit Option nie heruntergeladen
- Restore: Besitzer der wiederhergestellten Profil-Ordner wird auf den Zielbenutzer gesetzt (Rechte unveraendert), Schreibprobe im Protokoll; nach einem harten Abbruch geladen gebliebene Benutzer-Registry wird beim naechsten Start entladen
- Backup mit nicht gesicherten Dateien = Fehler (rot); Restore daraus nur nach ausdruecklicher Rueckfrage. Weitergefuehrtes Backup: geloeschte Dateien bleiben drin (Bericht zeigt die Anzahl)
- Pruefsummen-Stichprobe direkt nach dem Backup = Stichprobe; die Vollpruefung macht *Backup pruefen* mit dem Katalog
- Programm-Katalog: Pfade/Registry-Schluessel nach Herstellerangaben bzw. Erfahrung (best effort, Spalte *Geprueft*) - Lizenzdateien nur bei Programmen mit *(+ Lizenz)*, konto-/hardwaregebundene Lizenzen nie; gespeicherte Kennwoerter (DPAPI) und Store-Apps sind nicht uebertragbar
- Dienst-Datenbanken per Dateikopie nur bei gleicher Datenbank-Version am Ziel verlaesslich - sonst die Sicherung des Herstellers verwenden
- Wake-on-LAN ueber VPN/Router meist nur mit *Senden ueber PC* im selben Netz

## Konfiguration

Alles ueber **Einstellungen** (Fenster). Die Werte landen in:

| Datei | Inhalt |
|---|---|
| `Config\settings.json` | Backup-Ordner, Threads, Aufbewahrung (Tage + Anzahl je PC/Benutzer), USMT-Pfad, Software-/Treiberverteilung-Ordner (`SoftwareFolder`, `DriverFolder`), WLAN-Klartext, Backup-Optionen, Nacharbeiten, Checkliste, Standorte (`Profiles`, `ActiveProfile`), Links, Modul-Anzeige, letzte Vorlage, Benachrichtigung (`Notify`), Uebersicht (`OverviewAuto`) |
| `Config\apps.json` | eigene Eintraege fuer den Programm-Katalog (Aufbau wie `apps.default.json`) |
| `Config\exceptions.json` | Ausnahmen Ordner/Dateitypen fuer Profil und C:\ |
| `Config\modules.json` | eigene Module und Vorlagen |
| `Config\appupdates.json` | App-Updates: Ausnahmen und Quellen je Standort (Vorlage `appupdates.default.json`), Verlauf `Config\AppUpdates\history.json` |
| `Config\serverbackup.json` | Server-Backup-Profile (VMs, Platten, Optionen), Suchwoerter der Zeitplan-Pruefung (`ConflictWords`) |
| `Config\update.json` | Update: Quelle (`Owner`, `Repo`), `Channel` (`Stable`/`Test`), `SignerThumbprint` (nur eigene Quelle), `AllowUnsigned` (Signaturpruefung aus - nicht empfohlen), Entwicklung `Branch` + `UseBranch` (nur ohne Signaturpflicht) |
| `Config\installed.json` | installierte Version, Kanal und Pruefung (schreibt das Update) |

Die `*.default.json` kommen mit dem Update, eigene Dateien bleiben erhalten.

Installation: [INSTALL.md](INSTALL.md) | Anleitung: [Docs/Anleitung.html](Docs/Anleitung.html) | Aenderungen: [CHANGELOG.md](CHANGELOG.md)

**Lizenz:** kostenlose Nutzung erlaubt, Veraenderung und Weitergabe veraenderter Fassungen nicht - Details in [LICENSE](LICENSE).
