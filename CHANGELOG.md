# Changelog

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
