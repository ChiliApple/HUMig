# Changelog

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
