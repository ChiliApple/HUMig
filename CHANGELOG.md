# Changelog

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
