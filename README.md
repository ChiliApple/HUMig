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
| **Programm-Katalog** | erkennt rund 480 Programme, sichert deren Einstellungen, Plug-ins, Datenbanken und **Lizenzdateien** mit, schließt Programme vorher, installiert fehlende am neuen PC nach - mit **Katalog-Editor** |
| **Sicher** | Vorschau vor dem Restore, Prüfsummen-Katalog, Cloud-Dateien (OneDrive, SharePoint …) werden nie heruntergeladen |
| **Werkzeuge** | Fernwartung, AD-Mehrfachaktionen, Inventar, Autopilot-Hash, BitLocker, Profil-Reparatur, Diagnose, Software- und Treiberverteilung |
| **Server-Backup** | Hyper-V-VMs je Schule/Standort auf rotierende USB-Platten (Windows Server-Sicherung), Host-Konfiguration mit Switch-Wiederherstellungs-Skript, Verlauf und Statistik |
| **App-Updates** | installierte Programme über **WinGet** aktualisieren - Liste mit Haken, **Ausnahmen** (z. B. Prüfungssoftware) und Quellen je Standort, Verlauf |
| **Benutzer-Modus** | ohne Administratorrechte: eigenes Profil sichern/wiederherstellen, Dateien aus dem Backup holen |
| **Update** | Kanal **Stabil** (freigegebene Versionen) oder **Test**, Vorversion per Klick, jede Datei per **SHA-256** geprüft, nur **signierte** Releases werden installiert |
| **Anleitung** | im Tool mit **F1** – aus diesem Repository, passend zur installierten Version |

<table>
  <tr>
    <td align="center"><a href="Docs/img/backup.png"><img src="Docs/img/backup.png" width="260" alt="Backup"/></a><br><sub>Backup</sub></td>
    <td align="center"><a href="Docs/img/restore.png"><img src="Docs/img/restore.png" width="260" alt="Restore"/></a><br><sub>Restore</sub></td>
    <td align="center"><a href="Docs/img/werkzeuge.png"><img src="Docs/img/werkzeuge.png" width="260" alt="Werkzeuge"/></a><br><sub>Werkzeuge</sub></td>
  </tr>
</table>

## Schnellstart

1. `Pull.ps1` in einen leeren Ordner legen und ausführen: `powershell -ExecutionPolicy Bypass -File Pull.ps1`
2. **Start.cmd** starten – dabei entstehen **HUMig.exe** (Administrator) und **HUMig-Benutzer.exe** (Benutzer-Modus)
3. Computer und Benutzer wählen → Reiter **Backup** → **Backup starten**

Details: [INSTALL.md](INSTALL.md) und die [Anleitung](Docs/Anleitung.html) (im Tool mit **F1**).

**Inhalt:** [Bedienung](#bedienung) · [Module und Vorlagen](#module-und-vorlagen) · [Programm-Katalog](#programm-katalog) · [Restore](#restore) · [Software- und Treiberverteilung](#software--und-treiberverteilung) · [Werkzeuge](#werkzeuge) · [Server-Backup](#server-backup) · [App-Updates](#app-updates) · [Update und Sicherheit](#update-und-sicherheit) · [Grenzen](#grenzen) · [Konfiguration](#konfiguration)

---

## Bedienung

| Schritt | Ablauf |
|---|---|
| **1 · Verbinden** | Computer wählen (dieser PC, Name/IP oder **Geräte (AD)**) → **Verbinden** → Benutzer wählen. Installierte Programme werden dabei erkannt. |
| **2 · Backup** | Vorlage wählen oder Module anhaken → *Vorab-Prüfung* (Größe, freier Platz) → **Backup starten** |
| **3 · Restore** | am neuen PC Backup markieren → optional *Vorschau* → **Restore starten** → *Fehlende Programme installieren* → Checkliste |
| **4 · Werkzeuge** | Fernwartung, Diagnose, Profil-Reparatur, Verteilung – für den gewählten PC und Benutzer |

- Linksklick = Hauptfunktion, Rechtsklick = Zweitfunktion (steht im Tooltip)
- **Strg + Mausrad** skaliert die Oberfläche, **Strg + 0** = automatisch
- Auswahl, Optionen und die zuletzt gewählte Vorlage bleiben gespeichert
- **Benutzer-Modus** (`HUMig-Benutzer.exe`): eigenes Profil ohne Administratorrechte sichern und wiederherstellen; Updates mit Admin-Anmeldung
- **Standorte** (Einstellungen): eigener Backup-Ordner, Verteilungsordner und USMT-Pfad je Schule/Standort

### So funktioniert es

| Bereich | Technik |
|---|---|
| Dateien | Robocopy mit bis zu 128 Threads, inkrementell, Ausnahmelisten |
| Benutzer-Einstellungen | Registry-Export aus dem Benutzer-Hive, beim Restore auf den Zielbenutzer umgeschrieben |
| Windows-Einstellungen | Microsoft USMT – legt beim Restore auch das Profil an |
| Sicherheit | Platzprüfung, Prüfung nach dem Backup (SHA-256), optional Prüfsummen-Katalog; Nur-Cloud-Dateien werden nie heruntergeladen |
| Protokoll | druckbarer Bericht (HTML), `manifest.json`, Logs, Übersicht `Backups.html` |

## Module und Vorlagen

| Gruppe | Module |
|---|---|
| Profil & Daten | Benutzerprofil, Daten auf C:\\, Zusätzliche Ordner |
| Browser | Edge, Chrome, Firefox |
| Office | Signaturen, Vorlagen, PST, OneNote · Office-Einstellungen (Registry) |
| Windows | Taskleiste/Hintergrund, Desktop-Symbole, Startmenü-Pins, Schnellzugriff, Schriftarten |
| Netzwerk & Drucker | WLAN, Ordnerfreigaben, Netzlaufwerke, Drucker (auch mit Treibern), ODBC, VPN |
| System | Windows-Einstellungen (USMT), Aufgabenplanung, Treiber-Export, Info-Export |
| Programme | iPhone-Backups, KeePass, Autodesk und alle erkannten Programme aus dem [Katalog](#programm-katalog) |

**Vorlagen:** *Standard* und *Komplett* sind eingebaut. Eigene Vorlage: Module anhaken → **Als Vorlage speichern …**. Rechtsklick auf die Vorlagen-Liste = umbenennen, überschreiben, löschen.

> **Hinweis:** *Standard* enthält USMT – das braucht Administratorrechte und *Werkzeuge › USMT einrichten (ADK)*. Ist USMT nicht eingerichtet: Haken entfernen und als eigene Vorlage speichern (z. B. *Standard ohne USMT*). Im Benutzer-Modus ist USMT ohnehin ausgeblendet.

**Zeitplan:** *Zeitplan …* sichert das eigene Profil automatisch – täglich, wöchentlich oder bei Anmeldung, auf USB (an der Bezeichnung erkannt) oder ein Netzlaufwerk, optional mit Auswerfen danach.

## Programm-Katalog

Rund **480 Programme** – Browser, Office- und Medienprogramme, Schul- und Fachsoftware (z. B. Next-Exam, GeoGebra, Untis, SOLIDWORKS) und Admin-Werkzeuge. Je Programm sichert HUMig Einstellungen, Plug-ins, Datenbanken und – wo möglich – **Lizenzdateien**; was nicht übertragbar ist, steht als Nacharbeit in der Checkliste.

- **Geprüft / testweise:** nur Einträge mit Prüfdatum sind an einem echten PC bestätigt, alle anderen sind als *(ungeprüft)* markiert
- **Rückmeldung:** gelbe Knöpfe *Rückmeldung* öffnen ein vorausgefülltes GitHub-Issue oder eine E-Mail – nichts wird automatisch gesendet
- **Katalog-Statistik:** je Programm und PC, ob die Pfade beim Backup Daten hatten
- **Erweitern:** *Programme › + Programm hinzufügen* (Assistent) oder *Katalog bearbeiten* – eigene Einträge in `Config\apps.json`
- **Nie übertragen:** gespeicherte Kennwörter (DPAPI), Geräte-Identitäten (z. B. RustDesk, AnyDesk, VPN-Schlüssel), konto- oder hardwaregebundene Lizenzen

Aufbau der Einträge mit allen Feldern: Anleitung, Kapitel *Programme*.

## Restore

| Funktion | Wirkung |
|---|---|
| Vorschau | je Datei: neu / überschreibt / Ziel neuer / gleich |
| Neuere Dateien am Ziel behalten | Robocopy `/XO` |
| Fehlende Programme installieren | Vergleich Backup ↔ neuer PC, Installation aus der Softwareverteilung, sonst WinGet |
| Checkliste | Nacharbeiten abhaken, Stand landet im Protokoll |
| Backup prüfen · Vergleichen | gegen den Prüfsummen-Katalog · zwei Backups gegenüberstellen |
| Alte Backups | Aufbewahrung je PC und Benutzer, Löschen immer mit Rückfrage |

OneDrive-Dateien werden nie in den Sync-Ordner zurückgeschrieben.

## Software- und Treiberverteilung

| | Softwareverteilung | Treiberverteilung |
|---|---|---|
| Ordner | `Softwareverteilung\` | `Treiberverteilung\` |
| Paket | MSI/EXE/MSP oder ein Unterordner | Unterordner mit INF-Dateien oder Hersteller-Setup (ZIP/CAB werden entpackt) |
| Installation | Silent-Parameter werden aus dem Installer erkannt | INF über `pnputil` oder Setup mit Parametern |
| Prüfung | bereits installierte Programme werden übersprungen | nur PCs mit passender Hardware und anderer Version |
| Extras | – | Treiber **erzwingen**, **vor Windows Update schützen** |

Ziel ist der gewählte PC oder viele PCs aus dem AD (bis zu 8 gleichzeitig). *Installierte Software* zeigt die Programme eines PCs und deinstalliert still.

## Werkzeuge

| Bereich | Auswahl |
|---|---|
| Computer | Fernwartung aktivieren, Umbenennen, IP/DHCP, lokale Gruppen, Autologon, Neustart, **Geräte (AD) / Mehrfach**, Remote-PowerShell, Inventar, BitLocker, Autopilot-Hash, Wake-on-LAN |
| Benutzerprofil | Profil erneuern/zurückholen, Profil anderem Konto zuweisen, alte Profile löschen, Datenbanken und wichtige Dateien suchen, im Backup suchen |
| Diagnose / Wartung | Ereignisse, Akku, Aktivierung, Entra ID/Intune, Domäne/Kerberos, Druckwarteschlange, Speicher aufräumen, DISM/SFC |
| Dieser PC | Systemprogramme, Anmeldedaten, Hersteller-Treiber-Links |

Remote-Werkzeuge brauchen WinRM – *Fernwartung aktivieren* schaltet es über WMI ein. Änderungen immer mit Rückfrage.

## Server-Backup

Hyper-V-VMs oder die Laufwerke eines Servers mit der Windows Server-Sicherung auf **rotierende USB-Platten** sichern:

- Profile je Schule/Standort, Platten werden an ihrer Bezeichnung erkannt
- Online-Sicherung der VMs, optional Host-System, Host-Konfiguration mit Skript zum Wiederherstellen der Switches
- Zeitplan, Verlauf, Bericht je Lauf, Einträge in der Ereignisanzeige
- **Archiv-Platten** gegen Verschlüsselungstrojaner; Platte danach auswerfen oder offline schalten
- Wiederherstellung auch ohne HUMig (`wbadmin`, Installationsmedium)

## App-Updates

Installierte Programme per **WinGet** aktualisieren – am gewählten PC oder in einem ganzen EDV-Saal:

- Liste mit Haken, stille Installation, laufende Programme werden vorher erkannt
- **Ausnahmen** je Standort (z. B. Prüfungssoftware), eigene Quellen, Verlauf
- **Zeitplan** an den Ziel-PCs (als SYSTEM, PC wecken, verpasste Termine nachholen)

## Update und Sicherheit

- Kanal **Stabil** (Standard) oder **Test**; Vorversion per Rechtsklick auf *Update*
- jede Datei per **SHA-256** geprüft, installiert werden nur **signierte** Releases
- automatische Tests bei jedem Push (Windows PowerShell 5.1: Syntax, XAML, PSScriptAnalyzer, Pester)

## Grenzen

- Browser-Kennwörter und Cookies sind an Windows gebunden → Browser-Sync verwenden
- Startmenü- und Taskleisten-Pins unter Windows 11 nur eingeschränkt
- USMT: keine Migration zwischen AD- und Entra-ID-Geräten; Store-Apps nicht übertragbar
- Nur-Cloud-Dateien (OneDrive/SharePoint) werden nie heruntergeladen
- Dienst-Datenbanken per Dateikopie nur bei gleicher Version am Ziel verlässlich

## Konfiguration

Alles über **Einstellungen**, gespeichert in `Config\`:

| Datei | Inhalt |
|---|---|
| `settings.json` | Backup-Ordner, Optionen, Standorte, Checkliste, letzte Vorlage |
| `modules.json` | eigene Module und Vorlagen |
| `apps.json` | eigene Katalog-Einträge |
| `exceptions.json` | Ausnahmen für Profil und C:\\ |
| `appupdates.json` | App-Updates: Ausnahmen und Quellen je Standort |
| `serverbackup.json` | Server-Backup-Profile |
| `update.json` | Update-Quelle und Kanal |

Die `*.default.json` kommen mit dem Update, eigene Dateien bleiben erhalten.

---

**Lizenz:** kostenlose Nutzung erlaubt, Veränderung und Weitergabe veränderter Fassungen nicht – Details in [LICENSE](LICENSE).
