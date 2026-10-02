# Changelog

## v2.0.58 - 2026-10-02
### Neu
- **Reiter App-Updates (WinGet)**: installierte Programme dieses PCs aktualisieren - Liste mit Haken (installiert/neu/Quelle/Paket-ID), *Angehakte* bzw. *Alle aktualisieren* (still, nacheinander), laufende Programme werden vorher erkannt (schliessen / notfalls beenden / nicht aktualisieren), Ergebnis je Programm mit Fehlertext und Neustart-Hinweis, Verlauf
- **Ausnahmen je Standort** (Muster auf Paket-ID oder Name, mit Grund) - werden nie aktualisiert; vorbelegt: Edge, Chrome, Teams, Office, OneDrive (aktualisieren sich selbst) und Pruefungssoftware (Next-Exam, Safe Exam Browser)
- **Quellen je Standort** (Standard nur *winget*), eigene Quelle hinzufuegen/entfernen
- **WinGet einrichten**: Modul Microsoft.WinGet.Client (PowerShell Gallery, alle Benutzer) installieren und WinGet fuer das Konto registrieren/reparieren
- Programme ohne bekannte Version nur auf Wunsch (Zuordnung unsicher)

## v2.0.57 - 2026-10-02
### Neu
- Zeitplan (normales Backup): **USB-Laufwerk nach der Sicherung auswerfen** - Schutz vor Verschluesselungstrojanern; auch ohne Administratorrechte, auch nach einem Fehler; nur bei USB-/Wechsellaufwerk als Ziel (nicht Systemplatte, nicht Netzwerkpfad). Klappt es nicht, endet der Lauf mit Warnung und Grund. Verwaltung: neue Spalte *Danach*

## v2.0.56 - 2026-10-01
### Behoben
- *Release signieren*: Konsole zeigt je Release eine eigene Zeile (statt einer Sammelzeile)
- Info-Fenster: Zeilen werden umgebrochen statt abgeschnitten; Version, Kanal und Pruefung je in eigener Zeile; Fingerabdruck gekuerzt
- Versionsliste: Spalte *Aenderungen* ohne Formatierungszeichen (`**`)

## v2.0.55 - 2026-10-01
### Neu
- **Nur signierte Updates** (Standard): der Herausgeber signiert jedes Release; HUMig und `Pull.ps1` installieren nur Releases mit gueltiger Signatur des eingebauten Zertifikats - nichts einzustellen. Eine Version, die jemand anderer auf GitHub ablegt, wird abgelehnt
- Neue Versionen werden erst nach der Signatur angeboten (Update-Knopf, Kanal Stabil/Test); Versionsliste: Spalte *Signatur*, nicht signierte Versionen sind nicht installierbar
- **Release signieren**: Rechtsklick auf *Update* > *Release signieren (Herausgeber)* - nur sichtbar auf dem PC mit dem privaten Schluessel; signiert alle Releases mit Pruefsumme ohne Signatur, prueft und laedt hoch (Token mit Schreibrecht wird einmalig abgefragt und verschluesselt gespeichert)
- Eigene Quelle (eigenes Repo): eigener Fingerabdruck unter Einstellungen > Update
### Geaendert
- Einstellungen > Update: *Nur signierte Updates annehmen (empfohlen)* ist eingeschaltet; Ausschalten nur nach Rueckfrage; Branch-Modus nur ohne Signaturpflicht
- `Config\update.json`: `AllowUnsigned` statt `RequireSignature`; der eingebaute Fingerabdruck wird nicht in die Datei geschrieben
- Automatische Tests: Selbsttest blockiert jetzt (Fehler = Test fehlgeschlagen)
### Hinweis
- Von v2.0.52 und aelter: einmal auf *Update* klicken - danach gilt die Signaturpruefung automatisch

## v2.0.54 - 2026-10-01
### Behoben
- Cloud-Ordner sichern (nur lokale Dateien): relative Pfade werden beim Durchlaufen gebildet - funktionierte nicht, wenn der Ordnerpfad in Kurzform (8.3, z.B. `C:\Users\LANGER~1\...`) angegeben war (gefunden durch die automatischen Tests)
- Selbsttest: Modul-Handler *DesktopIconPositions* war in der Pruefliste nicht eingetragen

## v2.0.53 - 2026-10-01
### Neu
- **Update ueber Releases mit Kanal**: *Stabil* (Standard, nur freigegebene Versionen - fuer Server und Schul-PCs) oder *Test* (neue Versionen vor der Freigabe) - Einstellungen > Update bzw. Rechtsklick auf *Update*
- **Vorversion / bestimmte Version installieren**: Rechtsklick auf *Update* > *Andere Version / Vorversion installieren ...* (Liste mit Kanal, Datum, Pruefsumme, Aenderungen); `Pull.ps1 -Version x.y.z`
- **Pruefsumme**: jedes Release bekommt `HUMig-files.sha256` (SHA256 aller Dateien); das Update laedt zuerst alle Dateien, prueft sie und ersetzt erst dann - bei einer Abweichung bleibt alles unveraendert
- **Signatur (in Vorbereitung)**: *Nur signierte Updates annehmen* + Fingerabdruck des eigenen Code-Signatur-Zertifikats; `Tools\Sign-HUMigRelease.ps1` signiert die Pruefsummen-Datei (PKCS#7) - ohne Haken Updates wie bisher
- **Automatische Tests auf GitHub** (Windows PowerShell 5.1) bei jedem Push: Syntax + BOM, XAML und alle verwendeten Steuerelemente, Update-Bibliothek, PSScriptAnalyzer, Pester-Tests, Selbsttest; beim Release zusaetzlich Pruefsummen-Datei und Test des kompletten Update-Wegs
- Info-Fenster: Kanal und Pruefung der installierten Version (`Config\installed.json`); Anleitung (F1) passend zur installierten Version
### Hinweis
- Von v2.0.52 und aelter kommt dieses Update einmalig noch ueber den bisherigen Weg (ohne Pruefsumme); danach gilt der eingestellte Kanal

## v2.0.52 - 2026-09-30
### Neu
- Server-Backup **Host-System**: Pruefung, ob VMs Dateien auf C: haben (virtuelle Festplatten = werden mitgesichert, Warnung; nur Konfiguration = Hinweis) - Zeile unter *Host-System mitsichern* (orange, Details im Tooltip), Konsole beim Anhaken, Startabfrage, Zeitplan-Dialog und Protokoll des Laufs
- Server-Backup schreibt jeden Lauf in die **Ereignisanzeige** (Anwendung, Quelle HUMig): ID 1000 OK, 1001 Warnung, 1002 Fehler - auch geplante Laeufe ohne Platte/Profil

## v2.0.51 - 2026-09-30
### Behoben
- Server-Backup *Auswerfen*: warf die Platte auf manchen Servern nicht aus (Explorer-Befehl). Jetzt ueber die Geraeteverwaltung (CM_Request_Device_Eject, zweiter Versuch nach 5 s) mit Grund, falls Windows ablehnt (z. B. Dateien noch geoeffnet), und Angebot, die Platte stattdessen offline zu schalten
- *Nach Sicherung: auswerfen*: drei Versuche im Abstand von 10 s, danach wird die Platte offline geschaltet

## v2.0.50 - 2026-09-30
### Verbessert
- Reiter Restore: Knopf **Im Backup suchen ...** neben *Vergleichen ...* (sucht im markierten Backup)
- Reiter Backup: Knopf **Wichtige Dateien suchen ...** unter *Zusaetzliche Ordner* (Treffer als Zusaetzliche Ordner uebernehmen)
- beide weiterhin auch unter Werkzeuge

## v2.0.49 - 2026-09-30
### Verbessert
- Server-Backup, Bereich *Platten / Verlauf des Profils* uebersichtlicher: je Platte eine Zeile (farbiger Punkt, Bezeichnung, Datum, Alter) getrennt nach *Rotation* und *Archiv*, Markierungen *naechste laut Rotation*, *faellig* / *naechste in ... Tagen*, *letzter Lauf fehlgeschlagen*; Warnungen als farbige Hinweiszeilen; groessere Schrift

## v2.0.48 - 2026-09-30
### Neu
- Server-Backup: **Nach Sicherung** je Platte (Auswahl neben *Auswerfen*, gespeichert im Profil als `DiskAfter`, gilt auch fuer den Zeitplan): *nichts tun*, *auswerfen* (CM_Request_Device_Eject - funktioniert auch ohne Anmeldung als SYSTEM) oder *offline schalten* (Set-Disk -IsOffline); Anzeige in der Zeile unter der Ziel-Platte und in der Startabfrage
- Von HUMig offline geschaltete Platten bleiben beim automatischen Einlesen offline; *Aktualisieren* und der naechste geplante Lauf schalten sie wieder online

## v2.0.47 - 2026-09-30
### Neu
- Server-Backup: **Archiv-Platten** gegen Verschluesselungstrojaner - je Profil Anzahl und Abstand (Profil *Bearbeiten ...*, Standard 30 Tage); Bezeichnung `<Prefix>-A1`, `-A2` ... (Vorschlag in *Platte einrichten*); von der Rotation ausgenommen; rechts im Reiter letzte Archiv-Sicherung und *faellig*-Hinweis; nach einer Archiv-Sicherung Erinnerung zum Auswerfen, Abziehen und getrennten Lagern; Zeitplan nimmt bevorzugt Rotations-Platten; Statistik mit Spalte *Art*
- Anleitung: Abschnitt *Archiv-Platten* mit Faustregel 3-2-1-1-0

## v2.0.46 - 2026-09-30
### Dokumentation
- README, Anleitung und INSTALL ergaenzt: Server-Backup (Vorab-Pruefung auf laufende Sicherung, Zeitplan-Pruefung mit `ConflictWords`, Verlauf pflegen, abgebrochene Laeufe, Rueckfrage beim Schliessen), Treiberverteilung (Pruefung vor der Kopie, Kopie ueber `C$`, Erweiterungs-INFs), pulsierender Punkt, lesbare Dauer, automatische Spaltenbreite

## v2.0.45 - 2026-09-30
### Verbessert
- **Pulsierender gruener Punkt**, solange im Hintergrund gelesen/gearbeitet wird: im Reiter Server-Backup neben dem Ladehinweis (VMs/Laufwerke, Platten, USB-Datentraeger, Versionen, Host-Konfiguration, Platte einrichten) und in der Statusleiste fuer alle Hintergrund-Aufgaben - HUMig wirkt beim Laden nicht mehr eingefroren
- *Zeitplan-Pruefung*: Sanduhr, waehrend die Aufgabenplanung gelesen wird

## v2.0.44 - 2026-09-30
### Verbessert
- Server-Backup: Knopf **Zeitplan-Pruefung** neben *Zeitplan ...* - zeigt alle geplanten Sicherungsaufgaben am Host (fremde Programme, alte Aufgaben, HUMig-Zeitplaene aller Profile) mit Ausloeser, naechstem/letztem Lauf und *Suchwoerter aendern ...*

## v2.0.43 - 2026-09-30
### Neu
- Server-Backup-Zeitplan: **Pruefung auf andere Sicherungsaufgaben** in der ganzen Aufgabenplanung - frei definierbare Suchwoerter (Standard backup, sicherung, wbadmin, veeam, acronis; `-Wort` schliesst aus, Standard -RegIdleBackup) plus Zeitplaene anderer Profile; Ueberschneidung mit dem geplanten Lauf in den naechsten 14 Tagen wird gemeldet (trotzdem planen / nicht planen / Liste); Liste und *Suchwoerter aendern ...* auch ueber Rechtsklick auf *Zeitplan ...*
- **HUMig beenden waehrend einer Server-Sicherung:** Rueckfrage - Sicherung stoppen (wbadmin stop job), im Hintergrund weiterlaufen lassen oder HUMig offen lassen (bisher lief wbadmin nach dem Schliessen unbemerkt weiter)

## v2.0.42 - 2026-09-30
### Behoben
- Server-Backup: ein abgebrochener oder mit Fehler beendeter Lauf (nach Anlegen des Berichtsordners) landet jetzt im Verlauf (Status FEHLER, Hinweis *abgebrochen* bzw. Fehlertext) und bekommt einen Bericht - bisher blieb nur ein Berichtsordner auf der Platte ohne Eintrag

## v2.0.41 - 2026-09-30
### Neu
- Server-Backup: **Vorab-Pruefung auf eine laufende Sicherung/Wiederherstellung** am Host (Get-WBJob, laufende wbadmin-Befehle mit Benutzer und Startzeit) - manueller Start fragt, ob gewartet werden soll; Zeitplan wartet automatisch (hoechstens 8 h, abbrechbar); meldet wbadmin trotzdem "Ein weiterer Sicherungs- oder Wiederherstellungsvorgang wird ausgefuehrt", wartet HUMig und versucht es bis zu zweimal erneut; verstaendlicher Hinweis im Bericht statt nur Exitcode -3
- Server-Backup: **Laeufe aus dem Verlauf entfernen** - Rechtsklick im Verlauf (markierte oder alle fehlgeschlagenen des Profils) bzw. im Fenster *alle Laeufe*; entfernt die Eintraege im Tool-Ordner und auf angesteckten Platten, Sicherung und Berichtsordner bleiben

## v2.0.40 - 2026-09-29
### Verbessert
- Alle Tabellen (Backups, Server-Backup-Verlauf, Ergebnis-/Listenfenster, Geraete (AD), Einstellungen): Spaltenbreite richtet sich nach dem Inhalt - Text wird ganz angezeigt, bei Bedarf waagrechter Bildlauf statt abgeschnittener Spalten

## v2.0.39 - 2026-09-29
### Verbessert
- Dauer ueberall lesbar (z.B. *6 h 12 min*, *3 min 24 s*, *45 s*): Server-Backup (Konsole, Bericht, Verlauf-Spalte *Dauer*, Statistik *Mittlere_Dauer*, alle Laeufe), Backup/Restore (Konsole, Bericht, Manifest, Meldung, geplantes Backup), Software- und Treiberverteilung

## v2.0.38 - 2026-09-29
### Verbessert
- Treiberverteilung: **Vorpruefung vor der Kopie** - PCs ohne passende Hardware, mit derselben aktiven Version (setzt ggf. nur den Schutz) oder mit fremder Geraete-Sperre werden sofort erledigt, ohne das Paket zu kopieren
- Treiberverteilung: Kopie zum Client per Admin-Freigabe (C$) mit Robocopy (mehrere Threads) statt ueber die PowerShell-Sitzung - bei grossen Paketen deutlich schneller; ohne C$-Zugriff wie bisher ueber WinRM

## v2.0.37 - 2026-09-29
### Verbessert
- Treiberverteilung: Erweiterungs-INFs (Klasse Extension/SoftwareComponent, z.B. Audio-Bus-Erweiterung im Intel-Grafikpaket) zaehlen nicht mehr fuer Versionsvergleich, Erzwingen und Schutz - sie werden per pnputil mitinstalliert; Pruefung zeigt sie als *Erweiterung* statt *wuerde installiert*

## v2.0.36 - 2026-09-29
### Verbessert
- Treiberverteilung, Art INF: zum Client werden nur die Unterordner mit INF-Dateien kopiert (z.B. `driver\` statt des ganzen entpackten Pakets mit Setup); Infofeld und Rueckfrage zeigen die Kopiergroesse
- *Am gewaehlten PC pruefen* zeigt nur die passenden Geraete - nur wenn keines passt, zum Vergleich die Geraete derselben Klasse

## v2.0.35 - 2026-09-29
### Verbessert
- Treiberverteilung: wird bei *Ordner hinzufuegen* ein Ordner innerhalb eines Pakets gewaehlt (z.B. entpackter Treiber im Ordner des Setups), kann er als eigenes Paket in den Treiber-Ordner verschoben werden

## v2.0.34 - 2026-09-29
### Verbessert
- Treiberverteilung: *Ordner hinzufuegen* und *Datei hinzufuegen* starten im Treiber-Ordner; ein Ordner bzw. eine EXE/MSI, die schon direkt im Treiber-Ordner liegt, wird nicht nochmals kopiert, sondern als Paket ausgewaehlt

## v2.0.33 - 2026-09-29
### Behoben
- Links (Werkzeuge): Seriennummer (`{SERIAL}`, *Seriennummer in Zwischenablage*) und `{COMPUTER}` kommen jetzt vom **gewaehlten Computer** - remote per PowerShell-Remoting, sonst per WMI (DCOM); nicht lesbar = Hinweis, Link ohne Seriennummer (bisher immer der eigene PC)

## v2.0.32 - 2026-09-29
### Neu
- Treiberverteilung: **Vor Treiber-Updates schuetzen** (je Paket) - nach der Installation setzt HUMig am PC die Richtlinie *Installation von Geraeten verhindern, die diesen Geraete-IDs entsprechen* fuer die Geraete mit diesem Treiber (genaueste Hardware-ID, ohne Retroactive); Windows Update ersetzt den Treiber dann nicht mehr. **Nur Windows Pro, Education und Enterprise** (bei Home wird nichts gesetzt, Hinweis im Ergebnis)
- HUMig hebt eigene Sperren fuer spaetere Installationen automatisch auf und stellt sie bei Fehlern wieder her; fremde Sperren (GPO/Intune) werden gemeldet; ist die Version schon aktiv, wird nur der Schutz gesetzt
- **Sperren am PC ...**: gesperrte Hardware-IDs des gewaehlten Computers mit Geraet, Paket, Version und Herkunft, HUMig-Sperren aufheben; *Am gewaehlten PC pruefen* zeigt Spalte *Gesperrt* und warnt bei nicht unterstuetzter Windows-Edition
### Behoben
- Software-/Treiberverteilung: Anzeige *Gewaehlter Computer* wird beim Aktivieren des Fensters aktualisiert (zeigte den PC beim Oeffnen)

## v2.0.31 - 2026-09-29
### Verbessert
- Software- und Treiberverteilung: *Mehrere PCs ...* oeffnet die PC-Auswahl aus dem Active Directory (anhaken mit OU/Filter, weitere Namen eintragbar, zuletzt gewaehlte PCs vorgehakt) statt eines Textfelds

## v2.0.30 - 2026-09-29
### Neu
- **Treiberverteilung** (Werkzeuge > *Treiber installieren*): eigene Funktion mit eigenem Ordner `Treiberverteilung\` (Einstellungen > Allgemein bzw. je Standort), Paketliste und Verwaltung; Pakete = Ordner mit INF-Dateien und/oder Setup, EXE/MSI, ZIP/CAB werden beim Hinzufuegen entpackt
- Art **INF** per `pnputil /add-driver /subdirs /install` oder **Setup** mit Silent-Parametern; **Treiber erzwingen** installiert eine bestimmte (auch aeltere) Version ueber einen neueren/besser bewerteten Treiber
- INF-Auswertung (Klasse, Anbieter, Version, Datum, Geraete/Hardware-IDs); **Am gewaehlten PC pruefen** zeigt passende Geraete und aktiven Treiber ohne Installation
- Verteilen auf gewaehlten Computer, mehrere PCs oder als Mehrfachaktion *Treiber verteilen* (bis 8 parallel): ueberspringt PCs ohne passende Hardware bzw. mit derselben aktiven Version, Ergebnis mit aktiver Version, Neustart-Hinweis und Log
- Einstellung `DriverFolder` (Allgemein + Standorte)

## v2.0.29 - 2026-09-29
### Neu
- Assistent **Programm hinzufuegen** (Programme > *+ Programm hinzufuegen ...*, auch im Katalog-Editor): installiertes Programm waehlen, HUMig schlaegt Ordner (AppData, Dokumente, ProgramData), Registry-Schluessel (HKCU/HKLM) sowie Plug-ins, Vorlagen, Konfiguration und Lizenzdateien im Programmordner vor - mit Groesse zum Abhaken; Caches/Logs automatisch ausgelassen; Erkennung und Programm-Schliessen automatisch vorbelegt; Speichern oder im Editor verfeinern
### Verbessert
- Katalog-Editor: Knopf *+ Programm hinzufuegen ...* (Assistent), *+ Leer* fuer einen leeren Eintrag; Platzhalter-Umwandlung fuer Profile am Remote-PC ohne lokales Laufwerk

## v2.0.28 - 2026-09-29
### Neu
- Werkzeug **Datenbanken suchen**: lokale Datenbanken (SQLite, Access, KeePass, SQL Server, Firebird) und Datenbank-Dienste am PC finden, je Ordner mit Art, Ort, Groesse, Datum und *Geoeffnet*; uebernehmen als Zusaetzliche Ordner oder als Katalog-Eintrag (Editor vorausgefuellt); auch im Benutzer-Modus
### Verbessert
- Restore: fehlt das Ziel-Laufwerk (z.B. D: am neuen PC), verstaendlicher Hinweis statt Kopierfehler - Daten bleiben im Backup
- Katalog-Editor: Erkennung, die auf jedes Programm passt (z.B. nur ^), wird abgelehnt; *Ordner waehlen* bzw. Uebernahme wandelt auch Pfade eines Remote-PCs in Platzhalter um

## v2.0.27 - 2026-09-29
### Neu
- **Katalog-Editor** (Programme > *Katalog bearbeiten ...*, auch Einstellungen > Module): Eintraege mit Suche/Filter bearbeiten, anlegen, exportieren/importieren; Tests am gewaehlten PC (Erkennung, Paket, Pfad/Registry vorhanden + Groesse, laufende Prozesse, Dienste); *Ordner waehlen* wandelt in Platzhalter um; Anzeige Benutzer/Maschine je Eintrag; Pruefung vor dem Speichern; speichert nur in `Config\apps.json` (Sicherung `apps.json.bak`), Standard-Katalog bleibt unveraendert; Benutzer-Modus nur Ansicht
- Katalog-Felder: `NotTransfer`, `Version`, `CloseProcess`, `StopService`, `Verified` (Datum, Quellen, Notiz), je Eintrag `Role` und `DbKind` (abwaertskompatibel)
- **Programm vorher schliessen:** laeuft ein Programm, fragt HUMig vor Backup/Restore einmal fuer alle: schliessen, schliessen (notfalls beenden), ueberspringen oder trotzdem kopieren - auch remote (Schliessen in der Sitzung des Benutzers); geplante Backups beenden nie ein Programm, das Modul wird uebersprungen und gemeldet; Vorab-Pruefung zeigt laufende Programme
- **Dienste stoppen** fuer Dienst-Datenbanken (nur als Administrator), danach immer wieder starten (auch bei Fehler/Abbruch)
- Datenbanken: SQLite-Begleitdateien (-wal/-shm/-journal) werden mitkopiert, Warnung bei geoeffneter Access-Datenbank (.laccdb/.ldb)
- Uebersicht *Programme*: Spalten Nicht uebertragbar, DB, Schliessen, Geprueft; Checkliste nach dem Restore mit nicht Uebertragbarem, Versionshinweis und Datenbank-Hinweisen
### Verbessert
- Robocopy-Fehler nennen die betroffenen (z.B. gesperrten) Dateien in Protokoll und Bericht; fehlgeschlagene Dateien machen den Eintrag mindestens zur Warnung
- Manifest/Bericht halten je Modul fest, ob ein Programm geschlossen/uebersprungen/trotzdem kopiert und ob Dienste gestoppt wurden

## v2.0.26 - 2026-09-28
### Verbessert
- Zeitplan-Verwaltung (Rechtsklick auf *Zeitplan ...*): neue Spalte **Was** - gesicherte Module, Zusaetzliche Ordner mit Pfad

## v2.0.25 - 2026-09-28
### Behoben
- *Groesse ermitteln* / *Vorab-Pruefung*: mit genau einem angehakten Modul (z.B. nur Zusaetzliche Ordner) kam "Keine Module gewaehlt" und keine Groesse

## v2.0.24 - 2026-09-28
### Neu
- Backup: **Zeitplan** - eigenes Profil automatisch sichern (taeglich, woechentlich oder bei Anmeldung), fortlaufend oder als neues Backup, auf USB-Laufwerk (Erkennung ueber die Bezeichnung) oder Netzlaufwerk (UNC); geplante Aufgabe im Konto des Benutzers ohne Kennwort, auch im Benutzer-Modus; HUMig muss nicht geoeffnet sein
- Zeitplan: optional alte Backups automatisch loeschen (neueste N bleiben, Standard aus), Windows-Meldung mit Link zum Bericht, Verwaltung per Rechtsklick (jetzt starten, Protokoll, Bericht, loeschen)
### Behoben
- Nur Zusaetzliche Ordner sichern/messen: war das Modul nach *Keine* oder einem Vorlagenwechsel nicht mehr angehakt, kam "Keine Module gewaehlt" und keine Groesse - sind Ordner eingetragen, bleibt das Modul jetzt angehakt

## v2.0.23 - 2026-09-28
### Doku
- USMT: klargestellt, dass USMT auch fuer den Restore auf einen **neuen PC ohne Profil** noetig ist (LoadState legt das Profil an); ohne USMT muss sich der Benutzer vorher einmal anmelden (INSTALL.md, BIN\LIESMICH.txt, Anleitung)

## v2.0.22 - 2026-09-28
### Neu
- Server-Backup: **Laufwerke dieses Servers** sichern (Volume-Sicherung per wbadmin -include, blockbasiert) - auch auf Servern **ohne Hyper-V**; mit Pruefung, Verlauf, Bericht und Zeitplan
- Server-Backup: Reiter auf jedem Windows Server sichtbar; ohne Hyper-V verstaendlicher Hinweis statt WMI-Fehler ("kein Hyper-V - VMs am Hyper-V-Host sichern")
### Verbessert
- Host-Konfiguration auf Servern ohne Hyper-V: nur Netzwerk/IP, keine Hyper-V-Fehlermeldungen
- Zeitplan speichert die Auswahl exakt (VMs und Laufwerke); aeltere Zeitplaene laufen unveraendert

## v2.0.21 - 2026-09-28
### Verbessert
- Server-Backup: **neuer Bericht** (Bericht.html) - deutsch, Status mit erklaerendem Satz, Hinweise mit "Was tun", alle Dateien des Laufs als Links mit Erklaerung, komplettes Protokoll des Laufs (aufklappbar), Hinweis zur Wiederherstellung
- Server-Backup: Status **OK (Hinweis)** - vollstaendig gesichert, aber mit Hinweis (z.B. VM offline gesichert); **Warnung** nur noch, wenn wirklich etwas nicht einwandfrei ist (Pruefung, Host-Konfiguration, Host-System)

## v2.0.20 - 2026-09-28
### Neu
- Server-Backup: Grund fuer eine **Offline-Sicherung** wird aus dem Hyper-V-Protokoll gelesen und in Konsole, Bericht und Verlauf genannt (z.B. "dynamische Datentraeger im Gast") inkl. Abhilfe
- Server-Backup: Verlauf mit Spalte **Hinweis** (warum Warnung/Fehler); **Doppelklick** auf einen Lauf oeffnet dessen Bericht
- Server-Backup: VMs, die nur offline sicherbar sind, werden in der VM-Liste orange markiert und **vor dem Start** gemeldet (auch im Protokoll geplanter Laeufe)

## v2.0.19 - 2026-09-28
### Neu
- Server-Backup: **Zeitplan** - einmalig, taeglich oder woechentlich als geplante Aufgabe (Aufgabenplanung \HUMig, laeuft als SYSTEM ohne Anmeldung) mit den angehakten VMs; Uebersicht mit naechstem/letztem Lauf, Jetzt starten, Loeschen; Protokoll `Logs\ServerBackup\Aufgabe_*.log`
### Verbessert
- Server-Backup: nach dem Umbenennen einer Platte werden ihre bisherigen Verlaufseintraege automatisch dem neuen Namen zugeordnet (Platte und Tool-Ordner)

## v2.0.18 - 2026-09-28
### Neu
- Server-Backup: **Profil bearbeiten** - Name frei aenderbar (Verlauf im Tool-Ordner und auf angesteckten Platten wird uebernommen, spaeter angesteckte Platten werden automatisch zugeordnet), Platten-Bezeichnung, Anzahl Platten, Warnfrist
- Server-Backup: Profil wird bei jeder Sicherung auch auf der Platte gespeichert (`profiles.json`) und kann an einem anderen/neu installierten Host von der Platte uebernommen werden
### Behoben
- Platte einrichten: Partitionsstil wurde auf manchen Servern als Zahl geliefert (Anzeige "2", eine neue leere Platte waere nicht initialisiert worden)
- Statusleiste zeigt die aktuelle Phase (Schattenkopie) statt "Host-Konfiguration"
### Geaendert
- Hinweis zu VMs mit Pruefpunkten sachlich korrigiert (Einschraenkung laut KB 958662 nur fuer Server 2008 belegt)

## v2.0.17 - 2026-09-28
### Neu
- Reiter **Server-Backup** (Hyper-V-Host, als Administrator): VMs je Profil (Schule/Standort) mit der Windows Server-Sicherung online auf rotierende USB-Platten sichern
  - Profile mit VM-Auswahl, Platten-Bezeichnung und Anzahl Platten; Platte des Profils wird an der Bezeichnung erkannt, fremde Platten werden nachgefragt
  - **Platte einrichten**: nur USB-Platten (nie System-/Startplatten oder Platten mit VM-Dateien), GPT, NTFS 64K, Bestaetigung per Datentraegernummer
  - Pruefung nach der Sicherung (Version, enthaltene VMs), Warnung bei Offline-Sicherung und VMs mit mehreren Pruefpunkten
  - **Host-Konfiguration**: Switches, SET-Teams, Host-vNICs/VLANs, IP, Netzwerkkarten, VM-Einstellungen als HTML/JSON und Skript `Restore-VMSwitches.ps1`
  - Option **Host-System** (Bare-Metal, `-allCritical`)
  - Verlauf auf der Platte und im Tool-Ordner, Rotationsempfehlung, **Statistik / Uebersicht** ueber alle Profile und Platten, Versionen der Platte, Auswerfen, Hilfe zum Wiederherstellen
  - Windows Server-Sicherung direkt aus dem Reiter installierbar

## v2.0.16 - 2026-09-27
### Verbessert
- USMT: Protokoll nennt die USMT-Version; bekannte Startfehler werden erklaert (z.B. Code -1073741511 = USMT-Version passt nicht zum Windows des PCs, DLL fehlt, falsche Architektur)
- Gruppenrichtlinien-Ergebnis: ohne Benutzer-Teil steht die echte gpresult-Meldung im Hinweis statt einer Vermutung

## v2.0.15 - 2026-09-27
### Verbessert
- Gruppenrichtlinien-Bericht (remote): angewendete GPOs zuerst, Anzahl je Teil, nicht lesbare GPOs (nur GUID) mit verstaendlichem Grund; keine '?' mehr im Datum

## v2.0.14 - 2026-09-27
### Behoben
- Gruppenrichtlinien-Ergebnis remote: `gpresult /h` ist in Remote-Sitzungen nicht erlaubt (*Zugriff verweigert*, auch als SYSTEM). Das Tool erstellt jetzt einen eigenen HTML-Bericht aus `gpresult /x` und `/v`: angewendete und nicht angewendete GPOs mit Grund (deaktiviert, WMI-Filter, Sicherheitsfilter), Sicherheitsgruppen und alle Einstellungen als Text. Lokal bleibt der Original-Bericht

## v2.0.13 - 2026-09-27
### Behoben
- Gruppenrichtlinien-Ergebnis: `gpresult /s` scheiterte mit *Zugriff verweigert* - gpresult laeuft jetzt am Ziel-PC als kurzzeitige geplante Aufgabe unter SYSTEM (kein leerer Bericht, keine DCOM-Rechte noetig); der Hinweis nennt den echten Grund, wenn der Benutzer-Teil fehlt

## v2.0.12 - 2026-09-27
### Behoben
- **Gruppenrichtlinien-Ergebnis remote** lieferte einen leeren Bericht (gpresult in einer WinRM-Sitzung): jetzt `gpresult /s <PC>` von diesem PC aus (RSoP ueber WMI). Hat der gewaehlte Benutzer am Ziel-PC keine Richtlinien-Daten (nie angemeldet), kommt automatisch der Computer-Teil mit Hinweis

## v2.0.11 - 2026-09-27
### Neu
- Werkzeug **Laufwerke (C$)**: links C: des gewaehlten PCs im Explorer (remote `\\PC\C$`), rechts Auswahl aller Laufwerke (USB-Sticks hervorgehoben, mit Name und freiem Platz) und Freigaben des PCs

## v2.0.10 - 2026-09-27
### Verbessert
- Benutzerliste: Dienstkonten (NT SERVICE, SQL, IIS ...) werden nicht mehr angezeigt
- *[angemeldet]* nur noch bei echter Desktop-Sitzung; nur geladene Registry (z.B. getrennte Sitzung) erscheint als *[aktiv]*
- *Alte Profile loeschen* zeigt keine Dienstkonten-Profile mehr an (Schutz vor versehentlichem Loeschen)
- Vorauswahl: am eigenen PC/Server der Benutzer, der HUMig startet - nicht mehr der erste mit geladener Registry

## v2.0.9 - 2026-09-27
### Behoben
- **Backup loeschen**: Backups mit sehr langen Pfaden (ueber 260 Zeichen) oder schreibgeschuetzten Dateien liessen sich nicht loeschen (*keine Loeschberechtigung*). Pruefung und Loeschen laufen jetzt ueber Windows-Funktionen mit Langpfad-Unterstuetzung; die Meldung nennt den Grund je Datei (Zugriff verweigert / Datei geoeffnet)

## v2.0.8 - 2026-09-27
### Behoben
- **Desktop-Symbolanordnung** wurde beim Restore nicht uebernommen (Windows schreibt die Positionen erst beim Abmelden in die Registry): die Positionen werden jetzt direkt vom laufenden Desktop gelesen (`positions.tsv`, wie ReIcon in der Vorgaengerversion) und nach dem Explorer-Neustart wieder gesetzt - auch bei der ersten Anmeldung des Benutzers am neuen PC. Backups der Vorgaengerversion (`ICONS\IconLayouts.ini`) werden ebenfalls zurueckgespielt
- Voraussetzung beim Backup: Benutzer ist angemeldet (sonst nur Registry-Anordnung); *Symbole automatisch anordnen* muss aus sein

## v2.0.7 - 2026-09-27
### Verbessert
- Info: Link zur Projektseite und Lizenz-Hinweis sind anklickbar

## v2.0.6 - 2026-09-27
### Behoben
- Anleitung im Benutzer-Modus: *Datei kann nicht erstellt werden* - die Anleitung wird jetzt ueberschrieben statt verschoben und landet, wenn der Tool-Ordner dem Benutzer nicht gehoert, im eigenen LocalAppData

## v2.0.5 - 2026-09-27
### Behoben
- **Backup loeschen ganz oder gar nicht**: vorher wird fuer jede Datei geprueft, ob sie geloescht werden darf (Berechtigung, nicht geoeffnet) - sonst wird nichts geloescht (vorher blieb bei *Zugriff verweigert* ein halb geloeschtes Backup zurueck). Gilt auch fuer *Alte loeschen*
- Benutzer-Modus: Knopf *Loeschen* ausgeblendet (Backups loescht der Administrator)

## v2.0.4 - 2026-09-27
### Behoben
- **Backup/Restore mit genau einem Modul** meldete *Keine Module gewaehlt* (PowerShell 5.1 kennt `.Count` bei einem einzelnen Objekt nicht) - betraf Admin- und Benutzer-Modus
### Geaendert
- Vorlagen allgemein benannt: *Lehrer-Notebook* -> **Notebook**, *Verwaltungs-PC* -> **Buero-PC (mit Druckertreibern)**, *Schueler-Geraet* -> **Minimal** (Inhalt unveraendert, zuletzt gewaehlte Vorlage wird uebernommen)
- Anleitung: Vorlagen als Tabelle erklaert

## v2.0.3 - 2026-09-27
### Behoben
- Benutzer-Modus: *Backup starten* meldete trotz Haekchen *Keine Module gewaehlt* - Modulauswahl robuster (Sperre nur noch im Reiter Restore beruecksichtigt), bei leerer Auswahl Diagnose in der Konsole
- Benutzer-Modus: Computer- und Benutzerfeld bleiben nach einem Backup/Restore gesperrt

## v2.0.2 - 2026-09-27
### Neu
- **Benutzer-Modus** (ohne Administratorrechte): Start ueber **HUMig-Benutzer.exe** / **Start-Benutzer.cmd** oder *Nein* bei der Admin-Abfrage. Fest dieser PC und der angemeldete Benutzer; nur Module des eigenen Profils (+ Zusaetzliche Ordner); Eintraege in Programme/Windows/HKLM werden beim Restore uebersprungen; Drucker/Explorer-Aktionen laufen sofort in der Sitzung; Backup-Liste zeigt nur eigene Backups; Werkzeuge: *Im Backup suchen*, *Wichtige Dateien suchen*, Anmeldedaten, Profilordner. Einstellungen, Update und Systemfunktionen sind ausgeblendet, gemeinsame Vorgaben werden nicht veraendert
- Anleitung: Kapitel *Benutzer-Modus*
### Verbessert
- README mit Uebersicht und Badges

## v2.0.1 - 2026-09-27
### Behoben
- Anleitung: Browser meldete *Zugriff auf die Datei nicht moeglich* - die Anleitung wird jetzt direkt als `Docs\Anleitung.html` im Tool-Ordner aktualisiert (sonst unter *Oeffentliche Dokumente*) und ueber den Explorer im Kontext des angemeldeten Benutzers geoeffnet

## v2.0.0 - 2026-09-27
Erste Veroeffentlichung von HUMig v2 (Neuentwicklung fuer Windows 10/11):
- Backup/Restore von Benutzerprofilen lokal oder ueber das Netzwerk (Robocopy, Registry-Export, optional USMT), inkrementell, mit Vorab-Pruefung, Pruefung danach und Pruefsummen-Katalog
- Cloud-Ordner aller Anbieter werden erkannt, Nur-Cloud-Dateien nie heruntergeladen
- Programm-Katalog mit Einstellungen und Lizenzdateien, Nachinstallation aus der Softwareverteilung
- Restore-Vorschau, Checkliste, Backup-Vergleich, HTML-Uebersicht, Aufbewahrungsregeln
- Werkzeuge: Fernwartung, AD-Mehrfachaktionen, Inventar, Autopilot-Hash, BitLocker, Profil-Reparatur, Diagnose, Softwareverteilung
- Standorte, Anzeige-Skalierung, Update ueber GitHub, Anleitung (F1)
