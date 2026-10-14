# Changelog

## v2.1.3 - 2026-10-14
### Handy-Fernbedienung
- **Zeitplaene vom Handy sofort starten** (Reiter *Vorgang* > *Zeitplan jetzt starten*): Profil-Backups (eigene, ohne Adminrechte angelegt), Server-Backups und App-Updates dieses PCs. **Standard aus**, je Art einzeln einschaltbar unter Einstellungen > Handy; Server-Backup und App-Updates nur als Administrator
- Schutz: Handy sieht nur eine zufaellige Kennung; vor jedem Start prueft HUMig die Aufgabe erneut (Ordner, Konto, genau ein Befehl mit HUMigs eigenem Skript) - eine veraenderte oder gleichnamige fremde Aufgabe wird nicht gestartet; SYSTEM-Aufgaben nur, wenn normale Benutzer den Programmordner nicht aendern koennen; Einmal-Bestaetigung (30 s, je Handy); nicht wenn schon laufend bzw. Server-Sicherung laeuft; hoechstens 1 Start je Aufgabe und Minute, 5 in 10 Minuten; Zugriffsprotokoll mit Geraet und Aufgabe; Push-Meldung am Ende des Laufs
- Liste und Pruefung der Zeitplaene im Hintergrund (Oberflaeche wartet nicht auf die Aufgabenplanung)
### Berichte
- Backup-, Restore- und Server-Backup-Bericht am Handy gut lesbar (einheitliche Schriftgroesse, lange Pfade umbrochen); am PC unveraendert

## v2.1.2 - 2026-10-14
### Handy-Fernbedienung
- **Push-Meldung in Kurzform** mit Menge und Dauer, z. B. "Backup - erfolgreich · 8,01 GB · 5 min 12 s"; mehrere Meldungen kurz hintereinander erscheinen gemeinsam (bis 3 Zeilen)
- *Bericht*: oeffnet sich zuverlaessig im eigenen Fenster; in der iPhone-App (Home-Bildschirm) erscheint ein Link *Bericht oeffnen* zum Antippen
- Berichte auf einer Freigabe/einem Netzlaufwerk werden bei laufender Fernbedienung im Hintergrund nach `%LOCALAPPDATA%\HUMig\remote-reports` kopiert (hoechstens 10, aufgeraeumt mit dem Verlauf) - eine spaeter getrennte Freigabe haelt die Handy-Seite nicht mehr an; ohne Fernbedienung bzw. aus aelteren Verlaeufen bleibt so ein Bericht am Handy ohne Knopf
- Datentraeger fuer die Server-Backup-Kachel werden im Hintergrund gelesen (schlafende Platte friert die Oberflaeche nicht mehr ein); scheitert die Abfrage, bleiben die zuletzt bekannten Platten stehen
- Alter der Push-Meldung rechnet der PC (Handy-Uhr darf abweichen); ein defekter Eintrag in `remote-history.json` leert nicht mehr den ganzen Verlauf; Ausschalten der Fernbedienung wartet nicht mehr auf einen haengenden Versand
### Sicherheit
- Lokale Berichtskopien: kein Kopieren/Loeschen, wenn der Ordner eine Verknuepfung (Junction/Symlink) ist; geloescht werden nur eigene Dateinamen
- App-Updates: Paket-ID und Quellname duerfen keinen Zeilenumbruch am Ende haben (Pruefung mit `\z`)
### Doku und Tests
- Anleitung und README: Bilder der Handy-Seite (Status, Vorgang, Letzte Vorgaenge, Push, Koppeln) mit Beispieldaten
- Logo-Dateien ohne eingebettete Herkunfts-Metadaten (Bild unveraendert)
- Test der Listen-Rueckgaben prueft jetzt alle Skripte ueber den Syntaxbaum; neue Tests fuer Verlauf, Meldungsalter, Netzpfade, Hintergrund-Arbeiten und Kurzform

## v2.1.1 - 2026-10-13
### Handy-Fernbedienung
- Reiter *Vorgang*: **geschaetzte Restzeit** ("noch ca. 3 min") und beim Backup die **Menge** ("1,18 GB von 2,47 GB")
- **Letzte Vorgaenge:** die letzten 10 laengeren Vorgaenge mit Ergebnis, Dauer und Menge; *Bericht* oeffnet den Bericht am Handy (Einmal-Adresse fuer 60 s, strenge Richtlinie ohne Skripte)
- Startseite: **Server-Backup-Kachel** je Profil (angesteckte Platte mit freiem Platz, naechste Platte laut Rotation, Archiv faellig, Zustand der Platten) und **App-Updates je PC** (letzte Suche, Zeitplan, letzte 7 Tage mit fehlgeschlagenen Programmen und Grund)
- **Push bei Fehlern im App-Updates-Zeitplan** dieses PCs (solange HUMig offen ist); der Text der Meldung kommt weiterhin direkt vom PC
- Fenster *Handy*: das Feld *Adresse fuer den QR-Code* war bei zweizeiligem Text abgeschnitten
### Doku
- Funktionsseite: Handy-Fernbedienung in den Top 10 und als eigene Gruppe; Anleitung: was das Handy zeigt, Hinweis "pro PC nur eine HUMig-Kopie mit Fernbedienung"

## v2.1.0 - 2026-10-13
### Stabile Version (Kanal Stabil) - Zusammenfassung seit v2.0.127
Gleicher Programmstand wie v2.0.141 (gepruefter Stand). Die Einzelheiten stehen in den Abschnitten v2.0.128 bis v2.0.141.
- **Neu: Handy-Fernbedienung** (App auf dem Startbildschirm, HTTPS mit eigener CA je PC, QR-Kopplung): Startseite, laufender Vorgang mit Live-Anzeige (Durchsatz, CPU, RAM), Konsole, Abbrechen, **Push-Meldung bei Vorgangsende** (ohne Inhalt)
- **App-Updates:** WinGet-Modul immer im eigenen Prozess (kein Absturz von HUMig mehr, z. B. Server 2019), Windows Server 2022 unterstuetzt, Suche als SYSTEM als Ersatzweg, *Mehrfachaktion App-Updates suchen*, strengere Pruefung von Paket-ID und Quelle
- **Server-Backup:** Teams-Meldung auch fuer in HUMig gestartete Laeufe (auch bei Abbruch), Fehler beim Ereignistext behoben (Abbruch nach erfolgreicher Sicherung, Platte nicht ausgeworfen), VM-Export loescht aeltere Exporte nie mehr vor dem neuen
- **Backup:** Fortschritt nach Datenmenge (laeuft auch bei grossen Ordnern mit)
- **Softwareverteilung/Testinstallation:** /ALLUSERS bei Inno Setup, bessere Vorschlaege, Erkennung von Installationen ins Benutzerprofil
- **Update-Check:** GitHub-Abfragegrenze wird klar gemeldet, Ergebnis 30 Minuten zwischengespeichert
- **HUPilot:** Start als Administrator nur nach Bestaetigung mit Pfad und Warnung bei USB-Stick, Freigabe oder beschreibbarem Ordner

## v2.0.141 - 2026-10-13
### Behoben (Pruefung v2.0.140)
- **Profil-Backup brach mit Platzpruefung ab, wenn ein Eintrag (z. B. Dokumente) mehr als 2 GB zu kopieren hatte** (neu in 2.0.140, Fortschritt nach Datenmenge) - Zahl lief ueber den Bereich einer 32-Bit-Zahl. Neuer Test mit 3 GB / 900 GB
- Push-Meldungen erreichten ab zwei Handys keines, ohne Handy kam nach jedem Vorgang eine Fehlwarnung; die HUPilot-Warnung zeigte "System.Object[]" statt der Gruende. Ein neuer Test prueft jetzt alle Funktionen, die Listen als ein Objekt zurueckgeben, im ganzen Code
- Push: Ablehnung der Anmeldung (401/403, z. B. falsche PC-Uhr) traegt ein Handy erst nach 3 Ablehnungen in Folge aus und weist auf die Uhrzeit hin; Anmeldung je Push-Dienst hoechstens stuendlich neu (Apple); Zeitlimit nach Anzahl der Handys, nicht zugestellte werden gemeldet, Aufraeumen ohne die Oberflaeche zu blockieren; am Handy wartet das Zeitlimit auch das Lesen der Antwort ab
- Fortschritt: auch *Zusaetzliche Ordner* laufen waehrend des Kopierens mit
- HUPilot-Warnung: Konten, die selbst Administrator sind, gelten nicht mehr als Risiko (wie bei der Pruefung des Programmordners); zusaetzlich geprueft: hoehere Ordner, die andere Konten ersetzen duerfen
- App-Updates: Namen eigener WinGet-Quellen duerfen wieder Leerzeichen enthalten (z. B. "Firma Intern") - weiterhin keine Anfuehrungszeichen, kein \ und kein - am Anfang

## v2.0.140 - 2026-10-13
### Neu
- **Push-Meldungen aufs Handy** (Handy-Fernbedienung, *Mehr* > *Benachrichtigungen*): Meldung, wenn ein laengerer Vorgang am PC endet - auch bei geschlossener App. Ohne Inhalt ueber den Push-Dienst des Browsers (Google/Apple/Mozilla/Microsoft); den Text holt das Handy im selben Netz direkt vom PC. Eigener VAPID-Schluessel je Konto (DPAPI), nur Adressen der Push-Dienste werden angenommen
- **Teams-Meldung auch fuer in HUMig gestartete Server-Backups** (bisher nur Zeitplan) - mit denselben Zielen und Kategorien, auch bei einem Abbruch durch einen Fehler (nicht bei *Abbrechen*)
### Verbessert
- Fortschritt beim Backup nach **Datenmenge** statt nach Anzahl der Eintraege - grosse Teile wie das Chrome-Profil laufen nicht mehr lange bei 0 %, der Ring am Handy und der Balken am PC bewegen sich waehrend des Kopierens
- Verlaufslinien (Kopieren, CPU, Arbeitsspeicher) am PC und am Handy beginnen rechts und wandern nach links (wie im Task-Manager)
### Sicherheit (Pruefung v2.0.137)
- VM-Export nach der Sicherung (auch Zeitplan) loescht aeltere Exporte **nie mehr vorher** - reicht der Platz nicht fuer alten und neuen Export, wird die VM ausgelassen und gemeldet, der vorhandene Export bleibt
- Handy koppeln: der Code gilt nur **fuer ein Handy** - danach zeigt das Fenster sofort einen neuen
- HUPilot: vor dem Start als Administrator zeigt HUMig die genaue Datei und warnt bei USB-Stick, Freigabe oder einem Ordner, den normale Benutzer aendern duerfen

## v2.0.139 - 2026-10-13
### Handy-Fernbedienung
- Reiter **Vorgang**: Live-Anzeige wie am PC - Kopieren (Lesen/Schreiben in MB/s, Durchschnitt, Spitze), CPU und Arbeitsspeicher, jeweils mit Verlauf der letzten 60 Sekunden. Nach dem Ende bleibt der Durchschnitt stehen

## v2.0.138 - 2026-10-13
### Behoben (Pruefung v2.0.137)
- **Server-Backup endete seit v2.0.123 immer als Abbruch** (Fehler beim Formatieren der Ereignismeldung) - geplante Sicherungen meldeten "Abbruch"/FEHLGESCHLAGEN, obwohl die Sicherung gelungen war, und die Platte wurde danach **nicht ausgeworfen bzw. offline geschaltet**. Ein neuer automatischer Test prueft alle Formatierungen im Code
- App-Updates: Paket-ID und Quelle aus der gelesenen Liste werden vor dem Aufruf von winget.exe als SYSTEM streng geprueft (keine Leerzeichen/Anfuehrungszeichen) - ein Benutzer kann so keine zusaetzlichen winget-Parameter einschleusen. Neue Quellen nur mit einfachem Namen
- App-Updates: eine Ausnahme mit ungueltigem Platzhalter (z. B. `Tool [Beta`) bricht den Lauf nicht mehr ab
- *WinGet einrichten* am Ziel-PC: Ausgaben des Unterprozesses auf stderr zaehlen nicht mehr als Fehler (entscheidend ist der Exitcode)
- Handy-Fernbedienung: **SHA-256-Fingerabdruck** der CA im Fenster *Handy* (und Hinweis auf der Seite) zum Vergleichen am Handy; Firewall-Regel nur fuer http.sys (Programm *System*); Port-Freigabe fuer den Benutzer-Modus gilt auch fuer Administratoren, eine fremde Reservierung wird nie geloescht; eine zweite HUMig-Instanz (z. B. andere RDP-Sitzung) raeumt die laufende Fernbedienung nicht mehr als "Rest" weg; gebundene Zertifikate werden nicht geloescht; Zugriffsprotokoll wird nicht in eine Verknuepfung geschrieben
- Testinstallation: `C:\Users\Public` gilt nicht mehr als Benutzerprofil
- Update-Check: die Sperre wegen der GitHub-Abfragegrenze dauert hoechstens gut eine Stunde (auch bei falsch gehender PC-Uhr)

## v2.0.137 - 2026-10-13
### Update
- **GitHub-Abfragegrenze** (ohne Anmeldung 60 Abfragen je Stunde fuer alle Geraete hinter derselben Internet-Adresse): HUMig meldet jetzt klar, ab wann es wieder geht (statt "privat?"), und fragt bis dahin nicht mehr. Ein erfolgreicher Update-Check gilt 30 Minuten; nach Einstellungen, Token oder Signieren wird sofort neu gefragt. Abhilfe: Nur-Lese-Token (Rechtsklick auf *Update* > *GitHub-Token*)
- *Andere Version / Vorversion*: dieselbe klare Meldung bei der Abfragegrenze

## v2.0.136 - 2026-10-13
### Neu: Handy-Fernbedienung
- Status und laufende Vorgaenge am Handy ansehen und abbrechen - im selben Netz, als App auf dem Startbildschirm (PWA). Knopf **Handy** unten rechts: Ein/Aus, QR-Code und 6-stelliger Kopplungscode, gekoppelte Handys
- Handy-Seite: Startseite (Hinweise, Zeitplaene, letzte Sicherungen, Server-Backup, App-Updates), laufender Vorgang mit Fortschritt und Konsole live, *Abbrechen* mit Bestaetigung am Handy
- Sicherheit: HTTPS mit eigener CA je PC (nur fuer diesen PC und private IP-Bereiche, Schluessel nicht exportierbar), Geraete-Token mit 256 Bit (gespeichert nur der Hash), Sperre nach Fehlversuchen, Firewall-Regel nur in Domaenen-/privaten Netzen und nur solange aktiv, strenge Sicherheitsrichtlinie der Webseite, Zugriffsprotokoll `Logs\Remote`
- Einstellungen > **Handy**: automatisch einschalten, Port (Pruefung auf belegte Ports), Laufzeit, weitere erlaubte Netze, einmalige Einrichtung fuer den Benutzer-Modus durch einen Administrator

## v2.0.135 - 2026-10-13
### Werkzeuge
- *Geraete (AD) / Mehrfach*: neue Aktion **App-Updates suchen** - uebernimmt die angehakten PCs als Ziel in den Reiter App-Updates und sucht dort (danach wie gewohnt aktualisieren oder Zeitplan anlegen)

## v2.0.134 - 2026-10-13
### Behoben
- App-Updates suchen: brach das Lesen im Konto des angemeldeten Benutzers ohne Ergebnis ab (z. B. Windows lehnt den Start der Aufgabe ab, 0x800710E0), meldete HUMig "0 Updates". Jetzt liest HUMig dann als SYSTEM (PowerShell 7, nur Programme fuer alle Benutzer); gibt es gar kein Ergebnis, steht der PC als *nicht gelesen* da. Der Rueckgabewert der Aufgabe steht zusaetzlich als Hex-Code im Hinweis

## v2.0.133 - 2026-10-13
### Behoben
- *WinGet einrichten*: war das Modul Microsoft.WinGet.Client schon fuer alle Benutzer installiert, brach die Einrichtung mit "not catalog signed" ab (erneutes Installieren derselben Version). Jetzt wird nur aktualisiert, wenn es eine neuere Version gibt; klappt das nicht, geht es mit dem vorhandenen Modul weiter (WinGet reparieren)
- *WinGet einrichten*: fehlt der App Installer ganz (z. B. Windows Server 2022), steht das als Info statt als Warnung da - er wird danach von GitHub geladen
- Testinstallation: entspricht der Vorschlag schon den Paket-Einstellungen, steht das jetzt in der Konsole (bisher kam einfach keine Frage)

## v2.0.132 - 2026-10-13
### Behoben
- Testinstallation: falscher Hinweis *Setup installiert nur ins Benutzerprofil* bei Programmen fuer alle Benutzer (z. B. Greenshot mit `/ALLUSERS`). Der gemeinsame Ordner `AppData\Local\Programs\Common` zaehlt nicht mehr; neue Ordner im Profil zaehlen nur, wenn das Setup keinen Eintrag in *Apps & Features* anlegt - sonst entscheidet der Eintrag

## v2.0.131 - 2026-10-13
### Behoben
- App-Updates: stuerzt das WinGet-Modul ab, bietet HUMig *WinGet einrichten* wieder an (ausser auf Windows Server 2019) - auf Windows Server 2022 ist meist der App Installer nicht vollstaendig eingerichtet, das behebt die Einrichtung (`Repair-WinGetPackageManager -AllUsers`). Der Hinweis nennt das jetzt

## v2.0.130 - 2026-10-13
### Behoben
- **Softwareverteilung, Testinstallation:** Inno-Setups (z. B. Greenshot) wurden ohne `/ALLUSERS` getestet und landeten im Benutzerprofil - die Erkennung fand das Programm danach nicht. HUMig ergaenzt `/ALLUSERS` jetzt vor dem Test, ausser `/ALLUSERS` oder `/CURRENTUSER` ist schon eingetragen. Danach den Vorschlag fuer die Erkennung uebernehmen
- Ein Deinstallationsbefehl, der ins Sandbox-Benutzerprofil zeigt (frueherer Test), wird vor dem Test geleert und neu ermittelt

## v2.0.129 - 2026-10-13
### Behoben
- **App-Updates: HUMig stuerzte auf Windows Server 2019 ab** ("Windows PowerShell funktioniert nicht mehr" bei *WinGet wird geprueft*). Das WinGet-Modul laeuft jetzt immer in einem eigenen Prozess (Pruefen, *WinGet einrichten*, Einrichtung am Ziel-PC): stuerzt es ab, bleibt HUMig offen und meldet *WinGet-Modul ist abgestuerzt* mit Fehlercode; *WinGet einrichten* wird dann nicht mehr angeboten
- Softwareverteilung: auf Windows Server 2019 sucht HUMig Pakete nur noch ueber winget.exe (eigener Prozess), nicht ueber das WinGet-Modul

## v2.0.128 - 2026-10-12
### App-Updates
- **Windows Server 2019 experimentell:** HUMig richtet WinGet dort wie auf Server 2022 ein (`Repair-WinGetPackageManager -AllUsers`) - von Microsoft nicht unterstuetzt, Hinweis in der Konsole; klappt es nicht, wird der PC als *nicht gelesen* gemeldet

## v2.0.127 - 2026-10-12
### App-Updates
- **Windows Server 2022:** WinGet wird jetzt unterstuetzt - fehlt es am Ziel-PC, richtet HUMig es beim Suchen fuer alle Benutzer ein (`Repair-WinGetPackageManager -AllUsers`, von Microsoft nur eingeschraenkt unterstuetzt); *WinGet einrichten* an diesem PC ebenso
- Ist WinGet am Ziel-PC nicht nutzbar (keine Quelle lesbar, z. B. "Klasse nicht registriert"), meldet HUMig den PC als *nicht gelesen* mit Hinweis - bisher "0 Updates"
- Updates fuer alle Benutzer (als SYSTEM) und Zeitplan: winget.exe findet jetzt die Visual-C++-Laufzeit des App-Pakets (bisher Fehler 0xC0000135 z. B. auf Windows Server 2022); der Fehlercode wird mit Abhilfe erklaert
- Programme mit Dienst (z. B. Windows Admin Center): Unterprozesse des Dienstes gelten nicht mehr als Fenster; nach dem Stoppen wartet HUMig bis zu 20 s, bis Dienst und Unterprozesse beendet sind (bisher wurde das Update teils uebersprungen - "Programm liess sich nicht schliessen")

## v2.0.126 - 2026-10-12
### Werkzeuge
- Neuer Knopf *HUPilot ...* (Werkzeuge, Computer): oeffnet HUPilot-Setup an diesem PC (eigenes Werkzeug fuer Windows Autopilot per USB-Stick); beim ersten Mal HUPilot-Setup.cmd waehlen oder Anleitung oeffnen, Rechtsklick waehlt den Ordner neu (`Config\hupilot.json`)
- *Autopilot-Hash* (einzeln und *Geraete (AD) / Mehrfach*): ist HUPilot eingetragen, koennen die Hashes direkt an HUPilot uebergeben werden (`HUPilot\logs\hashes.csv`, hochladen mit *Hashes importieren*)
- System (dieser PC): alle Direktaufrufe (Taskmanager, Dienste, Registry, Verwaltungskonsolen, Systemsteuerung ...) starten wieder immer mit Administratorrechten - auch wenn HUMig ohne Adminrechte laeuft (Windows fragt dann nach). Ausnahme: *Autostart-Apps* (Einstellungen-App)

## v2.0.125 - 2026-10-12
### Behoben
- *Zeit synchronisieren*: nach dem Start des Windows-Zeitdienstes wartet HUMig jetzt, bis er bereit ist, und laedt die Zeit-Einstellungen neu (bisher "nicht synchronisiert, da der Zeitdienst inaktiv war"). "Nicht synchronisiert" wird als FEHLER gemeldet, auch wenn w32tm Exitcode 0 liefert; dann Neustart des Dienstes und zweiter Versuch, sonst Anzeige von Zeitquelle, Einstellungen und moeglichen Ursachen

## v2.0.124 - 2026-10-12
### Behoben
- Werkzeug *Domaene / Zeit / Kerberos* › *Zeit synchronisieren*: Fehler 0x80070426 ("Dienst wurde nicht gestartet") - der Windows-Zeitdienst (W32Time) wird jetzt vorher gestartet; ein deaktivierter Dienst wird gemeldet, danach ein zweiter Versuch und Anzeige der Zeitquelle
- Server-Backup › *VMs exportieren ...*: Fenster laesst sich vergroessern, die VM-Liste waechst mit

## v2.0.123 - 2026-10-12
### Server-Backup: VM-Export
- Neuer Knopf *VMs exportieren ...*: ausgewaehlte VMs mit Hyper-V exportieren (vollstaendige Kopie je VM, an jedem Hyper-V-Host mit *Virtuellen Computer importieren* wiederherstellbar) - auf die Platte (Ordner `HUMig-Export`) oder in einen beliebigen Ordner bzw. eine Freigabe
- Im Profil: *Nach jeder Sicherung automatisch exportieren* - laeuft nach jedem Server-Backup des Profils, auch im Zeitplan; Ergebnis in Bericht, Verlauf, Ereignis und Teams-Karte. Ein Export-Fehler macht die Sicherung zur Warnung, die Sicherung selbst bleibt unberuehrt
- Laufende VMs anwendungskonsistent (Produktionspruefpunkt), sonst absturzkonsistent mit Warnung; Platzpruefung vorab, Pruefung auf Konfiguration und alle virtuellen Festplatten, einstellbare Anzahl Exporte je VM (aeltere werden erst nach einem erfolgreichen neuen Export geloescht), `Export-Info.txt` mit Anleitung zum Importieren
- Export per Knopf: Ereignisse 1010/1011/1012, Protokoll `Logs\ServerBackup\Export_*.log`
### Teams-Benachrichtigung
- Je Ziel waehlbar, fuer welche Server-Backup-Profile es Meldungen bekommt (alle oder Auswahl) - z. B. je Standort ein eigener Kanal bei mehreren Profilen am selben Hyper-V-Host. Umbenannte Profile werden mitgenommen
- Neue Kategorie *VM-Export fehlgeschlagen / mit Warnungen* (Standard an)
### Dokumentation
- Anleitung: neue Abschnitte *VM-Export* und *HUMig-Sicherung oder VM-Export?* (Gegenueberstellung, Empfehlung), Wiederherstellen aus einem Export, Teams-Ziele je Profil

## v2.0.122 - 2026-10-11
### Softwareverteilung: Testinstallation in der Windows Sandbox
- Neuer Knopf *Testinstallation in der Sandbox*: installiert das Paket in der Windows Sandbox mit genau demselben Code wie bei der Verteilung, optional mit Deinstallationstest - Ergebnis OK / mit Hinweisen / fehlgeschlagen mit Exitcode, Dauer, sichtbaren Fenstern, Desktop-Verknuepfungen, Installation ins Benutzerprofil, neuen Eintraegen und Protokollen
- Vorschlag fuer Erkennung und stille Deinstallation zum Uebernehmen; Testergebnis wird beim Paket gespeichert (gilt fuer alle Admins), Kennzeichen in der Liste (getestet / Hinweise / fehlgeschlagen / ungetestet / veraltet), Hinweis in der Bestaetigung vor dem Verteilen
- Sandbox fehlt: HUMig bietet das Aktivieren an (Windows Pro/Education/Enterprise); Fenstergroesse und -lage der Sandbox werden gemerkt; grosse Pakete und Pakete auf Freigaben werden im Hintergrund lokal gespiegelt
### Softwareverteilung: weitere Funktionen
- Neue Paketfelder: Deinstallation, Erkennung per Registry-Schluessel oder Datei/Ordner, *Keine Desktop-Verknuepfung*, Abhaengigkeiten, WinGet-ID
- Abhaengigkeiten werden beim Verteilen vorher installiert (vorhandene uebersprungen, Kreislaeufe abgelehnt)
- *Deinstallieren ...* (gewaehlter PC oder mehrere PCs), *Status auf PCs ...* (installiert/Version je PC, letztes Ergebnis in `Softwareverteilung\_status`)
- *Neue Version (WinGet) ...* laedt den neuesten Installer ins Paket und passt Silent-Schalter und Erkennung an
- Setup-Dateien und Ordner koennen auf die Paketliste gezogen werden (nur aus einem Explorer mit Administratorrechten)
- Selbsttest (Test-HUMig.ps1) prueft das Sandbox-Skript und ob die Windows Sandbox aktiviert ist
### Dokumentation
- Neue Seite **Funktionen im Ueberblick** (`Docs/Funktionen.html`, auch als Webseite ueber GitHub Pages): die zehn wichtigsten Funktionen und alle Funktionen nach Bereichen, verlinkt im README

## v2.0.121 - 2026-10-11
### Sicherheit
- **Ordnerrechte beim Start:** die Pruefung (HUMig-Ordner, Config, Functions, XAML, BIN, Tools) laeuft jetzt **bevor** HUMig etwas aus dem Ordner laedt - gleiche Rueckfrage wie bisher (Absichern / Trotzdem / Nie mehr fragen). *Nie mehr fragen* gilt nur, wenn `settings.json` einem Administrator gehoert und fuer Benutzer nicht beschreibbar ist. Absichern setzt zusaetzlich den Besitzer Administratoren
- **Backup-Ordner im HUMig-Ordner:** jeder Benutzer sieht nur die Ordnernamen und oeffnet nur eigene Backups (bisher konnten alle Benutzer alle Backups lesen); ein Admin-Backup eines Benutzers bleibt fuer diesen lesbar. `Pull.ps1` stellt das bei Installation/Update als Administrator ein
- **Restore als Administrator:** Registry-Dateien aus dem Backup werden nur in den Zweig des Zielbenutzers bzw. den Schluessel des Moduls importiert; *Zusaetzliche Ordner* mit Ziel unter Windows, Programme, ProgramData oder im HUMig-Ordner kommen ins Profil (`Zusaetzliche Ordner`); Aufgaben, Schriftarten, Treiber, Drucker und Freigaben aus einem Backup, das nicht von einem Administrator stammt, nur nach Rueckfrage. Aufgaben-Import, *An Originalort zurueck* und Freigaben aus Backup kennzeichnen Systemziele und erhoehte Rechte mit ACHTUNG
- Besitzer-Setzen nach dem Restore und *Profil zuweisen* folgen keinen Verknuepfungen nach ausserhalb des Profils mehr (*Profil zuweisen* bricht dann mit Liste ab)
- *Speicher aufraeumen* folgt keinen Verknuepfungen (Junction) in Temp-Ordnern der Benutzer
- `%ProgramData%\HUMig`: ein von einem Benutzer vorab angelegter Ordner bzw. Inhalt wird beiseitegelegt und neu angelegt statt uebernommen
- Berichte/Links bei HUMig unter fremdem Admin-Konto: Programm nur noch aus der Registrierung des PCs (Browser bzw. registrierte Zuordnung), keine Skript-/Installer-Programme
- Cloud-Ordner-Sicherung folgt keinen Verknuepfungen (Junction/Symlink)
- Update: signierte Pruefsummen-Datei enthaelt die Version (`# HUMig-Release <tag>`) und wird beim Update und beim Signieren gegen das Release geprueft (Pflicht ab 2.0.121)
- Automatische Tests: Schreibrecht nur im Release-Schritt
### Behoben
- Geplantes Profil-Backup: nach einer Massenloeschung loescht die Aufbewahrung 14 Tage lang keine alten Backups; USB-Laufwerk wird auch nach Abbruch, Platzmangel oder ohne sicherbare Module ausgeworfen
- Startseite: mehrere Backup-Zeitplaene wurden zu einer Zeile zusammengefasst
- Aufbewahrung/Uebersicht brach ab, wenn ein Backup-Ordner waehrend der Auswertung verschwand
- Anmeldeskript nach Restore: Profilordner mit Apostroph (z. B. O'Brien) zerstoerte das Skript
- Browser-Sperre: nur gesperrte/verschwundene Dateien sind ein Hinweis, andere Kopierfehler (Zugriff verweigert, Ziel voll) wieder ein Fehler
- Teams: Massenloeschung aus geplanten Profil-Backups wird auch gemeldet, wenn nur diese Kategorie an ist; fehlgeschlagene Meldungen werden je Ziel bis zu 3-mal wiederholt; je Benutzer hoechstens 10 Meldungen pro Stunde (darueber Sammelkarte); Einstellungen: nach *Entfernen* ging eine eingetippte Adresse an das naechste Ziel; Server-Backup: reine Hinweise (VM offline gesichert) zaehlen nicht als Warnung
- App-Updates: Ausnahmen werden am Ziel-PC vor dem Aktualisieren erneut geprueft; Hinweis, dass bestehende Zeitplaene alte Ausnahmen behalten
- Profil erneuern/zuweisen: bricht ab, wenn die Registry-Sicherung fehlschlaegt; Profil erneuern baut bei Fehler zurueck
- Software-/Treiberverteilung: hinterlegte Anmeldedaten fuer den PC werden genutzt, wenn die Verbindung ohne scheitert; Windows-Installer-Sperre wird nach der Pruefung freigegeben
- Beschaedigte `settings.json`/`modules.json` werden nicht mehr stillschweigend ueberschrieben (Einstellungen: Rueckfrage mit Sicherung); Einstellungen werden ueber eine Zwischendatei geschrieben
- Rueckmeldung: bei vielen Programmen war die GitHub-Adresse zu lang (Fehlerseite) - der Text kommt dann ueber die Zwischenablage
- Ereignisquelle HUMig wird beim Start als Administrator angelegt
- Automatische Tests: nicht ladbare Testdatei gilt als Fehler; abgebrochener Release-Lauf reicht die Pruefsummen-Datei nach

## v2.0.120 - 2026-10-11
### Dokumentation
- Anleitung: eigenes Kapitel **Teams-Benachrichtigung** (im Inhaltsverzeichnis) - Einrichten in Teams Schritt fuer Schritt, Eintragen in HUMig, alle Kategorien als Tabelle, geplante Profil-Backups, Sicherheit/Entfernen, Probleme (App fehlt, private Kanaele, Kollegen ohne Benachrichtigung, Bot-Nachrichten loeschen, relay.log)
- README und INSTALL: Abschnitt Teams-Benachrichtigung; INSTALL: Hinweis, dass Test-HUMig.result.txt Daten des PCs enthaelt

## v2.0.119 - 2026-10-11
### Dokumentation
- Anleitung, Zeitplan > Meldung: Ereignisse 1100-1103, Weitergabe nach Teams, Browser-Sperren nur als Hinweis
- README: Zeitplan meldet auch in Ereignisanzeige und Teams

## v2.0.118 - 2026-10-11
### Geaendert
- Browser-Profile (Edge, Chrome, Firefox), die trotz laufendem Browser kopiert werden (geplantes Backup oder *Trotzdem kopieren*): vom Browser gesperrte Dateien (Cookies, Sitzung) sind nur noch ein **Hinweis** statt Fehler - Backup, Windows-Meldung und Teams-Meldung bleiben "erfolgreich". Bei anderen Programmen bleiben nicht gesicherte Dateien ein Fehler
- Knopf *Umzug ...* steht jetzt im Reiter Backup neben *Rueckmeldung*
### Behoben
- Geplantes Backup im Benutzer-Modus: unnoetige Warnung "ProgramData\HUMig nicht absicherbar ()" entfaellt (die Pruefung braucht Administratorrechte)

## v2.0.117 - 2026-10-11
### Teams-Meldung fuer geplante Profil-Backups
- Neue Kategorien je Ziel: *Geplantes Profil-Backup fehlgeschlagen*, *uebersprungen* (Ziel nicht erreichbar), *mit Warnungen* (alle an) und *erfolgreich* (aus); Massenloeschung aus geplanten Profil-Backups wird ebenfalls gemeldet
- Das geplante Backup laeuft weiter im Benutzerkonto und kennt die Webhook-Adressen nicht: es schreibt ein Ereignis ins Anwendungsprotokoll (Quelle HUMig, 1100 OK, 1101 Warnung, 1102 Fehler, 1103 uebersprungen)
- Eine Aufgabe unter SYSTEM (`\HUMig\Teams-Meldung Profil-Backups`) reagiert darauf (und prueft stuendlich), liest den Stand aus den Zeitplan-Dateien und meldet neue Laeufe an die Ziele - je Zeitplan hoechstens alle 10 Minuten, Texte aus Benutzer-Dateien werden entschaerft
- Wird beim Speichern der Einstellungen eingerichtet bzw. entfernt; Skript geschuetzt in `%ProgramData%\HUMig\Notify\relay.ps1`, beim Start von HUMig als Administrator aktualisiert, Protokoll `relay.log`
### Automatische Tests
- Meldung je Status und Kategorie, Massenloeschung, Entschaerfen von Texten, Faelligkeit (neu, jung, hoechstens alle 10 Minuten), zusammengesetztes SYSTEM-Skript

## v2.0.116 - 2026-10-11
### Teams-Benachrichtigung: mehrere Ziele
- Bis zu 10 Ziele (Chat oder Kanal) je PC, jedes mit Name, eigener Webhook-Adresse und eigenen Kategorien - nicht jeder bekommt alles (z.B. Fehler an den Kanal, Erfolg mit Details nur an den eigenen Chat)
- Einstellungen > Allgemein: Auswahlliste der Ziele, *Neues Ziel*, *Test senden* an das gewaehlte Ziel, *Entfernen* loescht nur das gewaehlte Ziel (sofort)
- Geplante Server-Backups schicken je Ziel eine Nachricht mit den dort eingeschalteten Punkten; im Aufgaben-Protokoll steht das Ergebnis je Ziel
- Die bisherige Adresse wird als Ziel "Standard" mit ihren Kategorien uebernommen; alle Ziele liegen verschluesselt in einem Wert (nur Administratoren/SYSTEM)
### Automatische Tests
- Verteilung an mehrere Ziele nach Kategorie, Pruefung der Ziele (Name, doppelt, Adresse, Hoechstzahl), Aenderungserkennung im Einstellungsfenster

## v2.0.115 - 2026-10-11
### Teams-Benachrichtigung: Kategorien
- Einstellungen > Allgemein > Teams-Benachrichtigung: jede Kategorie einzeln ein-/ausschaltbar - Server-Backup fehlgeschlagen, mit Warnungen, erfolgreich, Plattenzustand (SMART), Erinnerungen Plattenwechsel/Archiv, Speicherplatz knapp, Massenloeschung, Details
- Geplante Server-Backups: eine Nachricht je Lauf mit allen eingeschalteten Punkten; Details zeigen, was gesichert wurde, Dauer, Datenmenge, freien Platz der Backup-Platte und die Versionen auf der Platte (Anzahl, aelteste, neueste)
- Neu: Warnung "Speicherplatz knapp", wenn weniger frei ist als die naechste Sicherung braucht oder unter 10 % (die Windows Server-Sicherung loescht dann bald die aeltesten Versionen)
- Der bisherige Haken "auch erfolgreiche melden" wird als Kategorie *Server-Backup erfolgreich* uebernommen
- Anleitung: Einrichtung mit den aktuellen Workflow-Vorlagen (Chat/Kanal), private Kanaele gehen nicht, App im Teams Admin Center freigeben
### Automatische Tests
- Kategorien, Meldung je Lauf (Erfolg/Fehler/Plattenzustand/Erinnerung/Speicherplatz, Details ein/aus)

## v2.0.114 - 2026-10-11
### Neu: Umzugs-Assistent
- Knopf *Umzug ...* oben rechts: Schritt fuer Schritt alter PC und Benutzer, Vorab-Pruefung, Backup, neuer PC und Zielbenutzer, Restore (Backup wird automatisch markiert, fehlende Programme zuerst), Checkliste und Abschluss
- Nach Backup und Restore geht es automatisch zum naechsten Schritt; warnt, wenn im Hauptfenster gerade der falsche PC/Benutzer gewaehlt ist
- Fortsetzbar: der Stand liegt in `%APPDATA%\HUMig\umzug.json` - nach Schliessen oder Neustart von HUMig geht es dort weiter
### Automatische Tests
- Assistent: Stand speichern/fortsetzen, Ende von Backup/Restore

## v2.0.113 - 2026-10-11
### Behoben
- *Rueckmeldung* (GitHub-Issue) und andere Links (Quelle, Lizenz, eigene Links im Reiter Werkzeuge, Quellen im Katalog-Editor, ADK) oeffnen direkt im Standard-Browser - ueber den Explorer kam die Adresse teils verfaelscht an und GitHub meldete "Seite nicht gefunden"

## v2.0.112 - 2026-10-11
### Einstellungen
- Allgemein: Beschriftung "Backups aufbewahren (Tage)" steht jetzt bei der richtigen Zeile (Tage + Anzahl je PC/Benutzer)
- USMT-Ordner: eingetragener Ordner wird auch mit `amd64` bzw. `USMT\amd64` darunter gefunden; existiert er nicht oder liegt dort keine scanstate.exe, steht das als ACHTUNG unter dem Feld (bisher nur "gefunden:" mit einem anderen Ordner)

## v2.0.111 - 2026-10-11
### Start
- HUMig kommt beim Start immer in den Vordergrund (auch nach UAC-Abfrage, ueber den Starter oder nach einem Update-Neustart) - bisher blieb das Fenster oft hinter anderen Fenstern

## v2.0.110 - 2026-10-11
### Behoben
- *Zusaetzliche Ordner* und *Pfade ausschliessen*: die Ordnerauswahl zeigte die Ordner (Desktop, Downloads ...) des Kontos, unter dem HUMig laeuft - bei eigenem Admin-Konto also die falschen. Sie startet jetzt im Profil des gewaehlten Benutzers mit dem Baum ab *Dieser PC*; bei einem anderen PC ueber die Admin-Freigabe, uebernommen wird der Pfad am Quell-PC (C:\...)

## v2.0.109 - 2026-10-11
### Behoben
- Protokolle, Berichte und Anleitung: Windows 11 fragte trotz 2.0.107 weiter "Waehlen Sie eine App aus". HTML-Dateien werden jetzt direkt mit dem Standard-Browser gestartet (Browser-Zuordnung https, auch neuere Windows-11-Speicherung), nicht mehr ueber die .html-Zuordnung; Rueckfall Edge
### Automatische Tests
- Befehlszeile zum Oeffnen im Browser

## v2.0.108 - 2026-10-11
### Kleinigkeiten
- Reiter Restore: *Ordner oeffnen* oeffnet ohne markiertes Backup den Backup-Ordner (bisher passierte nichts)
- Ausgabe/HUMig.log: Zusaetzliche Ordner stehen nur noch einmal (eingerueckt unter dem Eintrag) statt doppelt

## v2.0.107 - 2026-10-11
### Browser vor Backup/Restore schliessen
- Edge, Chrome und Firefox stehen jetzt in der Abfrage *Programme geoeffnet* (schliessen, notfalls beenden, ueberspringen, trotzdem kopieren). Bisher wurden sie nicht gefragt, gesperrte Dateien (Cookies, Sitzungen) fehlten und das Modul stand auf Fehler
- Ohne Abfrage (geplantes Backup, Mehrfachaktion) werden Browser-Profile trotzdem kopiert (neues Modul-Feld `CloseDefault`), damit sie nicht ausgelassen werden, wenn der Browser im Hintergrund laeuft
### Protokolle oeffnen
- Laeuft HUMig unter einem eigenen Admin-Konto, oeffnen Berichte (Backup, Restore, Server-Backup, Host-Konfiguration, Uebersicht, Zeitplan) und die Anleitung mit dem Standard-Browser des am PC angemeldeten Benutzers - bisher fragte Windows jedes Mal, womit
### Automatische Tests
- Browser-Abfrage und Standard ohne Abfrage

## v2.0.106 - 2026-10-11
### Fortlaufendes Backup: Auswahl geaendert
- Aus *Zusaetzliche Ordner* herausgenommene Ordner werden nach `_GELOESCHT` beiseitegelegt (Grund "nicht mehr ausgewaehlt") und nicht mehr zurueckgespielt. Jeder Ordner behaelt seinen festen Platz im Backup (`FOLDER<n>`) - bisher wurde neu durchnummeriert, ein herausgenommener Ordner aus der Mitte vermischte den Inhalt mit dem naechsten
- Seit dem letzten Lauf neu ausgeschlossene Pfade (*Pfade ausschliessen*, *Grosse Dateien*): der alte Stand wird beiseitegelegt, bisher spielte der Restore ihn wieder ein
- Diesmal nicht angehakte Module: Hinweis im Protokoll (alter Stand bleibt im Backup-Ordner, wird nicht zurueckgespielt)
- *Im Backup suchen*: Originalort auch fuer beiseitegelegte Dateien herausgenommener Ordner
### Behoben
- Startseite: Server-Backup zeigte "noch keine erfolgreiche Sicherung" und "Archiv faellig", obwohl es erfolgreiche Laeufe gab (Verlaufsliste wurde als ein Eintrag gelesen). Sie liest jetzt auch den Verlauf auf allen lokalen Laufwerken und wird nach *Aktualisieren* im Reiter Server-Backup neu berechnet
- Gleicher Fehler bei den Erinnerungen in der Teams-Benachrichtigung des geplanten Server-Backups und bei der geschaetzten Dauer in der Zeitplan-Pruefung
### Automatische Tests
- Feste Nummern der Zusaetzlichen Ordner, neu ausgeschlossene Pfade, Listen-Rueckgaben (Regression)

## v2.0.105 - 2026-10-11
### Protokoll: Zusaetzliche Ordner
- Backup- und Restore-Protokoll nennen je zusaetzlichem Ordner den Pfad mit Dateien und Groesse (bisher nur "1 Ordner, 954,5 MB"); mehrzeilige Details werden im Protokoll als eigene Zeilen dargestellt

## v2.0.104 - 2026-10-11
### Restore: zuerst Programme, dann Einstellungen
- *Restore starten* prueft zuerst die Programme am Ziel. Fehlen installierbare Programme aus dem Backup (Softwareverteilung oder WinGet), fragt HUMig: zuerst installieren und danach automatisch zurueckspielen, nur Restore oder abbrechen. Microsoft empfiehlt, Programme vor dem Zurueckspielen der Einstellungen zu installieren
- Programm-Module, deren Programm am Ziel (noch) fehlt, werden ausgelassen (Konsole, Protokoll, Checkliste). Danach sind nur diese Programm-Module angehakt - Programm installieren, *Restore starten*: der 2. Lauf spielt nur noch die Programm-Einstellungen zurueck
- Kontrolle nach dem Restore: je Ordner Backup und Ziel vergleichen (nur auflisten), fehlende Dateien beim Ordner im Protokoll, als Liste `Restore_<PC>_<Zeit>_Fehlende.txt` und in der Checkliste
- Beides abschaltbar: Einstellungen > Restore
### Live-Anzeige
- Waehrend Backup, Restore und Server-Backup: Lesen/Schreiben des Kopiervorgangs (MB/s, auch bei Netzwerkzielen), CPU und Arbeitsspeicher mit Verlauf der letzten 60 Sekunden; am Ende Durchschnitt, Spitze und Menge
### Server-Backup: Plattenzustand (SMART)
- Gesundheitsstatus der USB-Platten (Windows) und, wenn das Gehaeuse sie durchreicht, Temperatur, Betriebsstunden, nicht behebbare Fehler, Abnutzung - automatisch beim Oeffnen/Aktualisieren und nach jeder Sicherung, Knopf *Plattenzustand pruefen*
- Letzte 30 Messungen je Platte (`Config\ServerBackup\disk-health.json`), nicht angesteckte Platten zeigen den letzten Stand. Warnung/Defekt: Hinweis im Reiter, auf der Startseite, im Bericht, Lauf mit Status Warnung
### Teams-Benachrichtigung
- Ueber einen Teams-Workflow (Webhook): geplante Server-Backups mit Fehler/Warnung, Plattenzustand, Erinnerungen (Platte wechseln, Archiv faellig), auf Wunsch auch erfolgreiche; Massenloeschung bei Backups als Administrator. Einstellungen > Allgemein, mit *Test senden*
- Die Adresse wird nur auf dem jeweiligen PC gespeichert: verschluesselt (DPAPI) in `HKLM\SOFTWARE\HUMig\Notify`, nur fuer Administratoren/SYSTEM lesbar, nie im Tool-Ordner oder in Logs
### Behoben
- Startseite: die Knoepfe *Oeffnen* gingen ueber die ganze Breite
### Automatische Tests
- Fehlende Programme/Programm-Module, Kontrolle nach dem Restore, Plattenzustand, Teams-Nachricht

## v2.0.103 - 2026-10-11
### Neu: Reiter Status (Startseite)
- Alles auf einen Blick: offene Hinweise, Backup-Zeitplaene (letzter Lauf, letzter Erfolg, naechster Lauf), letzte Backups je PC und Benutzer, Server-Backup (letzte Sicherung, Alter je Platte, Archiv faellig), App-Updates der letzten 7 Tage. Abschaltbar unter Einstellungen > Allgemein
- Hinweise beim Start (auch bei ausgeblendetem Reiter in der Ausgabe): Backup-Zeitplan seit 8 Tagen ohne Erfolg, fehlgeschlagen oder Aufgabe fehlt; Server-Backup-Platte laenger nicht gesichert als die Warnfrist des Profils (Plattenwechsel-Erinnerung); Archiv faellig; Massenloeschung erkannt
- Zeitplaene merken sich den letzten erfolgreichen Lauf (`LastSuccess`)
### Benutzer-Auswahl
- Ungefaehre Profilgroesse hinter dem Benutzer (aus dem letzten Backup oder der letzten Messung) und Ampel daneben: gross, knapp, passt nicht aufs Backup-Ziel
### Behoben
- Nach *Markierte ausschliessen* (Grosse Dateien) oder geaenderten Ausnahmen zeigten Vorab-Pruefung und Summe noch die alte Groesse. Jetzt gilt die Messung als veraltet und wird bei der Vorab-Pruefung neu ermittelt
- Text der Summe beim Messen: Registry, Windows-Einstellungen (USMT), Treiber und Schriftarten werden mitgesichert, nur ihre Groesse ist vorab nicht messbar (bisher stand "ohne USMT")
### Automatische Tests
- Startseite/Hinweise: Zeitplaene, Server-Platten, Archiv, Massenloeschung, App-Updates

## v2.0.102 - 2026-10-11
### Schutz vor Massenloeschung (Verschluesselungstrojaner)
- Fehlen in einem gesicherten Ordner auf einmal ungewoehnlich viele Dateien (Standard: mehr als 20 % und mindestens 50), legt das fortlaufende Backup dort nichts beiseite und warnt deutlich - das ist ein typisches Zeichen fuer einen Verschluesselungstrojaner (oder einen verschobenen Ordner). Warnung im Protokoll, als Benachrichtigung des Zeitplans, in der Backup-Liste und beim Restore. Schwelle: Einstellungen > Allgemein (0 = aus)
### Geloeschte Dateien - Bedienung
- Backup-Liste: neue Spalte *Geloescht* (Anzahl und Groesse der beiseitegelegten Dateien, *ALARM Massenloeschung*)
- Restore: Hinweis in der Info-Zeile, im Protokoll und in der *Vorschau*, wie viele beiseitegelegte Dateien nicht zurueckgespielt werden
- *Im Backup suchen*: Knopf *An Originalort zurueck* - markierte Treffer (auch geloeschte) an ihren urspruenglichen Ort auf den gewaehlten Computer, bei gewaehltem Benutzer in dessen Profil; vorhandene Dateien werden nie ueberschrieben
- *Geloeschte leeren* aktualisiert die Anzeige in der Backup-Liste

## v2.0.101 - 2026-10-11
### Fortlaufendes Backup: geloeschte Dateien
- Am Quell-PC geloeschte Dateien werden im weitergefuehrten Backup nach `_GELOESCHT\<Datum_Zeit>` verschoben (beiseitegelegt). Der Restore bringt damit nur noch den aktuellen Stand zurueck, verloren geht nichts. Bisher blieben sie im Backup und kamen beim Restore wieder
- Erkennung per Robocopy-Vergleich (nur auflisten) mit denselben Ausschluessen wie beim Backup - ausgeschlossene Dateien, Nur-Cloud-Dateien und Cloud-Ordner werden nie angefasst. Nur nach fehlerfreiem Kopieren; jede Datei wird an der Quelle einzeln nachgeprueft, bei jedem Zweifel (kein Zugriff, Netzwerkfehler) bleibt sie
- Beiseitegelegte Dateien werden nach 90 Tagen entfernt (Einstellungen > Allgemein, 0 = nie)
- Reiter Restore: neuer Knopf *Geloeschte leeren* (mit Rueckfrage, zeigt Anzahl, Groesse und Zeitraum)
- *Im Backup suchen*: Haekchen *Mit geloeschten*, Spalte *Geloescht (erkannt)*
- Pruefsummen-Katalog, *Backup pruefen* und *Vergleichen* zaehlen `_GELOESCHT` nicht zum Backup
### Behoben (Windows PowerShell 5.1)
- Restore *Zusaetzliche Ordner* mit zwei oder mehr gesicherten Ordnern: die Ordner wurden nicht gefunden (`ConvertFrom-Json` gibt ein JSON-Array unter PS 5.1 als ein Objekt aus - gleicher Fehler wie in v2.0.100 beim Update-Journal). Ebenso korrigiert: Restore und Anzeige gesicherter Aufgaben (Aufgabenplanung) mit mehreren Aufgaben
- Automatischer Test sucht kuenftig im ganzen Code nach diesem Muster
### Oberflaeche
- Der zuletzt gewaehlte Reiter wird gemerkt und beim naechsten Start wieder geoeffnet (pro Windows-Benutzer)
### Automatische Tests
- Neue Tests: Erkennen und Beiseitelegen geloeschter Dateien (inkl. Ausschluesse und Cloud-Ordner), nicht erreichbare Quelle, Aufbewahrung, Robocopy-Zusammenfassung deutsch/englisch

## v2.0.100 - 2026-10-10
### Update (Pull.ps1)
- Wiederherstellung nach einem abgebrochenen Update funktionierte unter Windows PowerShell 5.1 nicht, sobald mehr als eine Datei im Journal stand (`ConvertFrom-Json` gibt ein Array als ein einziges Objekt aus - die Schleife lief einmal mit allen Pfaden zusammen und stellte nichts zurueck, das Journal wurde trotzdem geloescht). Jetzt wird jede Datei einzeln zurueckgestellt; das Journal wird nur geloescht, wenn das gelungen ist.
- Wiederholungen beim Ersetzen sichern die bisherige Datei nicht mehr doppelt; scheitert eine Datei endgueltig, wird ihre Sicherung sofort zurueckgestellt.
- Automatischer Test des Update-Wegs jetzt mit zwei Dateien im Journal.
- **Wirkt verzoegert:** Ein Update laeuft immer mit dem bisher installierten Pull.ps1 - die Korrektur greift ab dem naechsten Update nach 2.0.100.

## v2.0.99 - 2026-10-10
### Sicherheit und Datenverlust (aus der externen Code-Pruefung)
- Server-Backup *Platte einrichten*: unmittelbar vor dem Loeschen wird geprueft, dass unter der Nummer noch dieselbe Platte steckt (ID, Seriennummer, Groesse, Modell) und keine VM-Dateien auf ihr liegen - sonst Abbruch ohne Loeschen. VM-Dateien werden jetzt auch ueber Bereitstellungspunkte und Volumes ohne Laufwerksbuchstaben erkannt (inkl. Snapshot- und Smart-Paging-Ordner); ist die VM-Liste nicht lesbar, bricht HUMig ab statt die Platte anzubieten
- *Alte Backups* / Aufbewahrung im Zeitplan: gezaehlt werden nur brauchbare Backups (OK/Warnung). Das neueste brauchbare je PC und Benutzer wird nie vorgeschlagen, abgebrochene/fehlerhafte nur, wenn es ein neueres brauchbares gibt, unvollstaendige nie. Liste und Rueckfrage zeigen den Status, die Rueckfrage warnt extra vor dem neuesten brauchbaren Backup
- Restore *Zusaetzliche Ordner*: Pfade im Profil des Quell-Benutzers werden ins Profil des Zielbenutzers umgeschrieben; Ziele im Profil eines anderen Benutzers gehen nach `Profil\Zusaetzliche Ordner`; Ziele im OneDrive-/SharePoint-Ordner des Zielbenutzers nach `Profil\OneDrive-Wiederherstellung` (neuere Cloud-Versionen werden nicht mehr ueberschrieben). Cloud-Unterordner, die beim Backup erkannt wurden, werden jetzt auch hier ausgelassen
- Backup-Ordner, die selbst eine Verknuepfung (Junction/Symlink) sind, erscheinen nicht mehr in der Backup-Liste; Loeschen entfernt nur den Link
### Automatische Tests
- Neue Tests fuer Aufbewahrung, Verknuepfung als Backup-Ordner und die Pruefung vor dem Loeschen einer Platte

## v2.0.98 - 2026-10-10
### Update und Releases
- Versionsnummer steht nur noch in `Config\version.json` (HUMig, Backup- und Server-Backup-Zeitplan lesen sie dort)
- Neue Versionen legen die automatischen Tests selbst als Vorab-Release (Kanal Test) an - Text aus diesem CHANGELOG, Pruefsummen-Datei angehaengt, Update-Weg getestet, nur die letzten 10 Releases bleiben
- Herausgeber: Rechtsklick auf *Update* > *Release freigeben* - neuestes signiertes Vorab-Release wird nach erneuter Signaturpruefung in den Kanal Stabil gestellt
### Start
- HUMig laeuft je Programmordner nur einmal (Admin- und Benutzer-Modus zusammen); ein zweiter Start meldet das
- Liegt ein Update-Journal (Update laeuft oder wurde abgebrochen), startet HUMig nicht, sondern bietet an, das Update neu auszufuehren
### Automatische Tests
- Pruefung: `Config\version.json` gueltig und im CHANGELOG ein Abschnitt dazu

## v2.0.97 - 2026-10-10
### Update (Pull.ps1)
- Ersetzen mit Ruecksicherung: jede bisherige Datei wird erst zu `*.pullold` umbenannt, die Liste steht in `Config\pull-journal.json`. Ist eine Datei gesperrt, wird alles zurueckgestellt (bisher konnte ein Teil schon ersetzt sein). Bricht ein Update hart ab, stellt der naechste Start von Pull.ps1 die bisherigen Dateien wieder her
- Dateien, die es in der neuen Version nicht mehr gibt, werden entfernt - nur solche, die frueher per Update installiert wurden (neue Liste `FileList` in `installed.json`). Config, Logs, BACKUPS, BIN, Software-/Treiberverteilung und eigene Dateien bleiben immer unberuehrt
- Gespeicherter Token wird abgelehnt (HTTP 401): einmal ohne Token versuchen, bevor nach einem neuen gefragt wird
- Hinweis: ein Update laeuft immer mit dem Pull.ps1 der bereits installierten Version - die Ruecksicherung gilt ab dem Update nach v2.0.97, das Entfernen alter Dateien ab dem Update danach (erst dann gibt es die Liste)
### Automatische Tests
- Update-Weg: zweiter Lauf als Update ueber die bestehende Installation (abgebrochenes Update wird zurueckgestellt, veraltete Datei entfernt, Config/eigene Dateien/Pfade ausserhalb unberuehrt, keine Reste)
- (enthaelt v2.0.96: Absicherung von `%ProgramData%\HUMig`, Pruefung der Profil-Sicherungen)

## v2.0.96 - 2026-10-10
### Sicherheit (aus einer externen Code-Pruefung)
- `%ProgramData%\HUMig` wird am jeweiligen PC vor jeder Nutzung abgesichert: Besitzer Administratoren, schreiben nur SYSTEM und Administratoren, Benutzer nur lesen; Verknuepfungen (Junction/Symlink) darin werden entfernt, ohne ihr Ziel anzuruehren. Bisher erbte der Ordner die ProgramData-Rechte - Standardbenutzer konnten dort Dateien anlegen und z. B. das Skript des App-Update-Zeitplans austauschen, das als SYSTEM laeuft
- App-Updates: das Zeitplan-Skript `auto.ps1` wird bei jedem Zugriff auf den Stand der HUMig-Version gebracht (ersetzt auch ein veraendertes Skript)
- Anmelde-Aktionen nach dem Restore: eigener Ordner je Lauf (`ProgramData\HUMig\FirstLogon`), nur fuer den Zielbenutzer lesbar; das bisher vergebene Loeschrecht auf den ganzen Ordner entfaellt
- *Profil zurueckholen* bietet nur noch Sicherungen an, die *Profil erneuern* selbst so anlegt (SID, Profilordner direkt im Profilverzeichnis, .reg nur mit dem ProfileList-Eintrag dieser SID); die Rueckfrage zeigt die SID
- Vermerke geladener Benutzer-Registry (`HiveMounts`) werden nur im abgesicherten Ordner geschrieben und ausgewertet
- Neue automatische Tests fuer die Absicherung und die Pruefung der Profil-Sicherungen

## v2.0.95 - 2026-10-05
### Lizenz
- LICENSE: englische Fassung ergaenzt (Uebersetzung, im Zweifel gilt die deutsche Fassung) - Inhalt unveraendert

## v2.0.94 - 2026-10-05
### Geaendert
- Erkannte Programme (Gruppe *Programme*) werden nur noch angehakt, wenn die gewaehlte Vorlage sie enthaelt: *Standard* = keine (von Hand anhaken), *Komplett* = alle, eigene Vorlage = die gespeicherten. Vorher waren beim Start alle erkannten Programme angehakt, nach einem Vorlagenwechsel nicht mehr

## v2.0.93 - 2026-10-05
### Behoben
- Gerade signiertes Release wurde bis zu einer Minute als *nicht signiert* angezeigt (Update / *Andere Version* verweigerte die Installation, erst nach erneutem Signieren ging es): GitHub liefert die Release-Liste mit 60 Sekunden Zwischenspeicher - HUMig und Pull.ps1 fragen die Liste jetzt immer frisch ab
- (enthaelt v2.0.92: Update im Benutzer-Modus, README neu gegliedert, Anleitung USMT-Hinweis)

## v2.0.92 - 2026-10-05
### Benutzer-Modus
- Der Knopf *Update* ist jetzt auch im Benutzer-Modus sichtbar und wird bei einer neuen Version gelb. Installieren fragt nach der Anmeldung eines Administrators (UAC); danach startet HUMig wieder im Benutzer-Modus (auch wenn die Abfrage abgelehnt wird)
### Dokumentation
- Anleitung: Hinweis bei *Vorlagen* - ist USMT nicht eingerichtet, Haken entfernen und als eigene Vorlage speichern; ohne Adminrechte (Benutzer-Modus) ist das nicht noetig
- Anleitung: Feld-Referenz fuer eigene Katalog-Eintraege (aus dem README hierher verschoben)
- README neu gegliedert und deutlich gekuerzt (Schnellstart, Inhalt, kurze Kapitel; Details in der Anleitung)

## v2.0.91 - 2026-10-05
### Vorlagen
- Eingebaut sind nur noch **Standard** und **Komplett**. Standard hakt jetzt an: Profil, Daten auf C:\, Edge, Chrome, Firefox, Office, Office-Registry, Taskleiste, Desktop-Symbole, Startmenue-Pins, Schnellzugriff, WLAN, Ordnerfreigaben, Netzlaufwerke, Netzwerkdrucker, USMT, Aufgabenplanung, Info (ODBC nicht mehr)
- Ohne gemerkte Vorlage (erster Start, oder die gemerkte gibt es nicht mehr) wird Standard gewaehlt
- Neu: Knopf **Als Vorlage speichern ...** neben *Alle*/*Keine* - angehakte Module unter eigenem Namen speichern. Rechtsklick auf die Vorlagen-Liste: *Umbenennen*, *Mit aktueller Auswahl ueberschreiben*, *Loeschen* (nur eigene Vorlagen). Gespeichert in Config\modules.json, bleibt bei Updates erhalten
- Die Vorlagen Nur Browser + Office, Neuer PC, Notebook, Buero-PC und Minimal sind entfallen - bei Bedarf als eigene Vorlage anlegen
### Oberflaeche
- Reiter *Werkzeuge*: Abschnitts-Ueberschriften groesser

## v2.0.90 - 2026-10-03
### Neu: Katalog-Statistik
- Nach jedem Backup vermerkt HUMig je Katalog-Programm und PC/Benutzer, ob die Pfade des Eintrags Daten hatten (gefunden / teilweise / nicht vorhanden) - `Katalog-Statistik.json` im Backup-Ordner, nur lokal, nichts wird gesendet
- Fenster *Programme*: Spalte *Praxis (Backups)*; Knopf *Katalog-Statistik ...* mit allen Programmen (verdaechtige oben), *Aus vorhandenen Backups einlesen* und - als Administrator - *Markierte als geprueft ...* (speichert in Config\apps.json)
- Rueckmeldung (GitHub-Issue/E-Mail) enthaelt die Zahlen je Programm

## v2.0.89 - 2026-10-03
### Dokumentation
- Anleitung: neuer Abschnitt *Ein Programm auf Mitnahme pruefen* (Schritt fuer Schritt: erkennen, nur dieses Modul sichern, Protokoll lesen, am Test-Benutzer/in der Windows-Sandbox zurueckspielen, Rueckmeldung, als Administrator *Geprueft am* setzen)
- (enthaelt v2.0.88: Rueckmeldung-Knoepfe, E-Mail-Rueckmeldung)

## v2.0.88 - 2026-10-03
### Neu
- Gelber Knopf **Rueckmeldung** im Reiter *Backup* (ungepruefte Eintraege der erkannten Programme) und **Rueckmeldung zu Programmen** im Reiter *Restore* (ungepruefte Eintraege des markierten Backups): vorausgefuellte Liste je Programm (passt / fehlte / falscher Pfad)
- Rueckmeldung wahlweise per **E-Mail** ueber das Mailprogramm, ohne GitHub-Konto: Adresse unter *Einstellungen > Allgemein > Rueckmeldung per E-Mail an* (leer = nur GitHub-Issue). Es wird nie etwas automatisch gesendet
- Hinweis in der Konsole nennt jetzt den Weg zum Knopf

## v2.0.87 - 2026-10-03
### Programm-Katalog
- Ungepruefte Eintraege (Dateien/Registry, noch an keinem PC bestaetigt) sind klar als **testweise** gekennzeichnet: `*` bei *Programme erkannt* mit Erklaerung, Zusatz *(ungeprueft)* in der Backup-Liste und im Bericht, eigener Punkt in der Checkliste, Spalte *Geprueft* im Fenster *Programme* (*nein - testweise*)
- Neuer Knopf **Rueckmeldung geben ...** im Fenster *Programme*: oeffnet ein vorausgefuelltes GitHub-Issue zu den markierten Eintraegen (nichts wird automatisch gesendet)
- Advanced IP Scanner, Angry IP Scanner und WinSCP als geprueft markiert (Backup an einem Windows-11-PC)
- RustDesk: Hinweis, dass RustDesk2.toml aus dem Dienst-Profil auch unlock_pin und trusted_devices enthaelt (keine Geraete-ID)

## v2.0.86 - 2026-10-03
### Programm-Katalog (jetzt rund 480 Programme)
- 193 weitere Programme aus einer zweiten, unabhaengig nachgeprueften Recherche: Schulsoftware (Next-Exam, LanSchool, NetSupport School, TI-Nspire, Mathematica, Maple, Moodle Desktop, Barrierefreiheit wie JAWS, Read&Write, SuperNova), HTL/HAK-Fachsoftware (SOLIDWORKS, CATIA, Creo, Archicad, Rhino, Altium, SAP GUI, Dynamics NAV, B&R), Buero und Medien (Adobe-Programme, CorelDRAW, ABBYY, Visio, OneNote, DaVinci Resolve) sowie Helfer; als *ungeprueft* markiert
- reine Hinweis-Eintraege (ohne Dateien, Nacharbeit in der Checkliste) fuer VPN-Clients (WireGuard, Tailscale, Proton VPN, Surfshark, AmneziaVPN, OpenVPN Connect, Cisco Secure Client, GlobalProtect, Sophos Connect), Virenschutz, Kartenleser- und Signatursoftware (A-Trust, ID Austria-Umfeld)
- OpenVPN GUI: Verbindungsprofile des Benutzers (*.ovpn) werden mitgenommen - mit Hinweis, dass sie private Schluessel enthalten
- 23 Korrekturen am Bestand, u. a.: Telegram (tdata ist die angemeldete Sitzung - Backup vertraulich), DBeaver (Kennwoerter mit festem Schluessel, gehen mit), pgAdmin (ab 7.2 im Windows-Passwortspeicher, nicht uebertragbar), FileZilla/WinSCP/mRemoteNG/MobaXterm (Kennwort-Speicherung genau beschrieben), AnyDesk (service.conf mit der ID wird nicht kopiert), Arduino IDE 2 (.arduinoIDE ergaenzt), Claude (MSIX-Pfad, API-Schluessel im Klartext), JetBrains und GitHub Desktop (Erkennung erweitert), Total Commander/XYplorer/Charles/MakeMKV (Lizenz wird uebertragen)
- nicht uebernommen: Eintraege mit geringer Belegsicherheit

## v2.0.85 - 2026-10-03
### Programm-Katalog
- 135 weitere Programme (externe Recherche, Pfade gegen Hersteller-Doku/Quellcode/Forensik-Pfadlisten belegt, WinGet-IDs gegen winget-pkgs geprueft; als *ungeprueft* markiert, Herkunft in den Feldern Confidence/Sources/Note), u. a. Slack, Discord, Telegram, Signal, Opera, Docker Desktop, SSMS, pgAdmin, MySQL Workbench, WinMerge, TortoiseGit/SVN, Veyon, NVDA, calibre, Anki, OrcaSlicer, Kodi
- nicht uebernommen: Eintraege mit geringer Belegsicherheit und VPN-Clients (Konfiguration/Schluessel geraetegebunden)

## v2.0.84 - 2026-10-03
### Geaendert
- Programme: Katalog alphabetisch sortiert (Fenster *Programme*, erkannte Programme in der Konsole, Gruppe PROGRAMME)
- Backup-Protokoll: bei einzelnen Dateien aus dem Benutzerordner (z.B. Advanced IP Scanner) keine Liste ausgelassener Cloud-Ordner mehr

## v2.0.83 - 2026-10-03
### Behoben
- Update/Pull: liefert der Download-Link von GitHub einen Fehler (z.B. *503 Server nicht verfuegbar*), werden Pruefsummen- und Signaturdatei ueber die GitHub-API geladen (gleiche Datei, Echtheit weiter ueber Signatur geprueft)

## v2.0.82 - 2026-10-03
### Programm-Katalog
- WinSCP: WinSCP.ini ist eine Datei in AppData (war als Ordner eingetragen und ging nicht mit)
- mRemoteNG: user.config (LocalAppData) ergaenzt
- RustDesk: Server-Einstellungen (RustDesk2.toml) aus dem Dienst-Profil der installierten Version; eigene ID weiterhin nicht
- Advanced IP Scanner: Favoriten/Aliase/Kommentare (.bin-Dateien im Benutzerordner - vom Profil-Backup sonst ausgenommen)
- Angry IP Scanner: zusaetzlich .java\.userPrefs (Registry bleibt der eigentliche Speicherort unter Windows)
- GeoGebra: Classic 6 (AppData\GeoGebra) und Classic 5 (AppData\GeoGebra 5.0)

## Dokumentation (nach v2.0.81)
- README/Anleitung: Programm-Katalog (rund 140 Programme, *nicht uebertragbar*, Geraete-Identitaeten), App-Updates (Zweitversuch im Benutzerkonto, Fehlercodes als Klartext, Programme mit eigenem Updater als Ausnahme), Backup loeschen (schreibgeschuetzte Ordner, OneDrive)

## v2.0.81 - 2026-10-03
### Behoben
- Backup loeschen in einem OneDrive-Ordner: der Backup-Ordner selbst blieb leer stehen (*Zugriff verweigert*) - OneDrive setzt auf Ordnern das Attribut *Schreibgeschuetzt*, das wird jetzt vor dem Entfernen auch beim obersten Ordner aufgehoben

## v2.0.80 - 2026-10-03
### Behoben
- Backup loeschen in einem OneDrive-Ordner: der zuletzt geleerte Backup-Ordner meldete *Zugriff verweigert* (OneDrive haelt ihn kurz offen) - HUMig wiederholt das Entfernen bis ca. 5 Sekunden und wertet ein bereits vorgemerktes Loeschen als erfolgreich

## v2.0.79 - 2026-10-03
### Programm-Katalog
- rund 100 neue Eintraege (Pfade aus Hersteller-Doku bzw. Quellcode recherchiert, als *ungeprueft* markiert), u. a. Brave, Vivaldi, LibreWolf, Git, GitHub Desktop/CLI, Windows Terminal, PowerToys, Everything, VeraCrypt, KiCad, QGIS, Blender, FreeCAD, PrusaSlicer, Cura, Bambu Studio, Krita, MuseScore, OpenBoard, Wireshark, VirtualBox, JetBrains-IDEs, DBeaver, HeidiSQL, MobaXterm, RustDesk, Citrix Workspace
- Chrome/Edge: gespeicherte Kennwoerter und Cookies stehen jetzt unter *nicht uebertragbar* (an Windows-Konto und PC gebunden)
- Citavi (Einstellungen 6/7), GeoGebra Classic 5, Untis (Lizenz in der .gpn), SMART (Produktschluessel zurueckgeben) ergaenzt
- Geraete-Identitaeten werden absichtlich nicht kopiert (RustDesk-ID, Syncthing-Schluessel, Chrome-Remotedesktop-Host)
### Behoben
- Backup loeschen: Backups in einem OneDrive-Ordner liessen sich nicht vollstaendig loeschen (*Zugriff verweigert* bei Unterordnern) - OneDrive-Ordner wurden wie Verknuepfungen behandelt

## v2.0.78 - 2026-10-03
### Geaendert
- App-Updates: neue Standard-Ausnahmen *Autodesk.Fusion* (aktualisiert sich selbst; WinGet meldet OK, die Version bleibt aber gleich) und *Microsoft.WSL* (ueber WinGet nicht aktualisierbar - als Administrator `wsl --update`). Bestehende Standorte bekommen neue Standard-Ausnahmen einmalig dazu; selbst geloeschte kommen nicht wieder

## v2.0.77 - 2026-10-03
### Behoben
- App-Updates: beim zweiten Versuch im Benutzerkonto (v2.0.76) fehlte die Ergebniszeile in der Konsole - das Ergebnis des ersten Versuchs (als SYSTEM) blockierte die Anzeige

## v2.0.76 - 2026-10-03
### Behoben
- App-Updates: meldet WinGet als SYSTEM *kein installiertes Paket gefunden* (0x8A150014, z. B. WSL - Paket ist nur im Benutzerkonto sichtbar), versucht HUMig dasselbe Programm automatisch noch einmal im Konto des angemeldeten Benutzers
- App-Updates: WinGet-Fehlercodes bei Programmen nur fuer einen Benutzer werden lesbar angezeigt (z. B. 2316632067 -> *Befehl fehlgeschlagen ... (0x8A150003)*), neu u. a. 0x8A150103 *Datei in Benutzung*

## v2.0.75 - 2026-10-03
### Behoben
- App-Updates: Programme nur fuer einen Benutzer - haengt ein Update laenger als 15 Minuten (meist wartet der Installer auf eine Administrator-Bestaetigung, die der Benutzer nicht geben kann), wird es abgebrochen und mit Hinweis gemeldet; die uebrigen Programme laufen weiter (vorher bis zu 3 Stunden Wartezeit)

## v2.0.74 - 2026-10-03
### Behoben
- App-Updates: bei laengeren Installationen (z. B. VirtualBox) erschienen alle bisherigen Zeilen ein zweites Mal in der Konsole - das Protokoll der Hilfsaufgabe wurde nach einem kurz gesperrten Lesezugriff von vorne gelesen

## v2.0.73 - 2026-10-03
### Behoben
- App-Updates, laufende Programme *Schliessen*: Programme ohne Fenster blieben offen (z. B. Dienste wie Surfshark.Service, Hintergrundprogramme im Infobereich wie PowerToys) und wurden uebersprungen. HUMig erkennt jetzt je Prozess *Fenster*, *Hintergrund* oder *Dienst*: Fenster werden wie bisher hoeflich geschlossen, Hintergrundprogramme beendet und nach dem Update im Konto des Benutzers wieder gestartet, Dienste gestoppt und danach wieder gestartet (falls der Installer das nicht schon getan hat)

## v2.0.72 - 2026-10-03 (enthaelt v2.0.71, nicht freigegeben)
### Dokumentation
- INSTALL: Ordnerrechte, App-Updates (Voraussetzungen, PowerShell 7), Platte uebernehmen
- Anleitung: Dateien von HUMig ausserhalb des Tool-Ordners, Einstellung `AclCheckOff`, Katalog-Feld `WingetId`, Hinweis zu HUMig im persoenlichen Ordner
### Behoben
- Werkzeug *Netzwerk / IP-Adresse*: brach auf manchen PCs mit *Exception setting NetAdapter* ab (Windows-Fehler in Get-NetIPConfiguration, z. B. bei Hyper-V-Adaptern) - Werte werden jetzt einzeln gelesen

## v2.0.70 - 2026-10-03
### Restore / Zuverlaessigkeit
- Nach dem Restore wird der **Besitzer** der wiederhergestellten Profil-Ordner auf den Zielbenutzer gesetzt (vorher: Administratoren; stoerte z. B. SSH, manche Browser-Profile, Lizenzpruefungen). Rechte bleiben unveraendert (kein pauschales Grant). Danach Schreibprobe ueber die Rechte auf Desktop, AppData\Roaming und einem Programm-Ordner - Ergebnis im Protokoll
- Benutzer-Registry: HUMig vermerkt am Ziel-PC, wenn es NTUSER.DAT geladen hat. Bleibt sie nach einem harten Abbruch (Task-Manager, Absturz) geladen, wird sie beim naechsten Start bzw. vor dem naechsten Laden entladen - nur wenn der Benutzer nicht angemeldet ist und das ladende HUMig nicht mehr laeuft (Fernzugriff: nach 24 h). Der Vermerk wird beim erfolgreichen Entladen geloescht

## v2.0.69 - 2026-10-03
### Geaendert
- Ordnerrechte absichern: Logs- und Backup-Ordner im HUMig-Ordner werden beim Zuruecksetzen ausgelassen (enthalten keinen Code; grosse Backup-Ordner haetten sonst lange gedauert)

## v2.0.68 - 2026-10-03
### Sicherheit / Zuverlaessigkeit
- **Ordnerrechte**: HUMig prueft beim Start als Administrator, ob Nicht-Administratoren im HUMig-Ordner schreiben oder Dateien anlegen duerfen (z. B. unter C:\Tools Standard), und bietet an abzusichern (Vererbung aus, Administratoren + SYSTEM Vollzugriff, Benutzer Lesen; Logs und Backup-Ordner im HUMig-Ordner bleiben fuer den Benutzer-Modus beschreibbar, nur eigene Dateien). *Abbrechen* = nie mehr fragen
- **Nach-Skript** (Restore) laeuft nur, wenn die Skriptdatei nicht fuer Nicht-Administratoren beschreibbar ist
- Backup: nicht gesicherte Dateien machen Modul und Backup immer **rot** (Fehler), nie nur gelb
- Restore aus einem Backup mit Fehlern oder einem abgebrochenen Backup: eigene Rueckfrage mit den betroffenen Modulen
- Weitergefuehrtes Backup: Bericht nennt je Modul die Dateien, die nur noch im Backup liegen (an der Quelle geloescht/verschoben)
- Schliessen waehrend Server-Backup: *wbadmin stop job* nur noch, wenn HUMigs eigene Sicherung laeuft (nicht beim Warten auf eine fremde)
- Schliessen waehrend eines Vorgangs: HUMig wartet bis 30 s auf das Aufraeumen (Benutzer-Registry entladen, Dienste starten)
- Robocopy: klare Fehlermeldung, falls die Befehlszeile durch sehr viele Ausschluesse zu lang wuerde (statt still abgeschnitten)

## v2.0.67 - 2026-10-02
### Neu
- Server-Backup, *Platte einrichten*: **Uebernehmen (ohne Formatieren)** fuer Platten, die schon anders genutzt werden - nur die Bezeichnung wird geaendert (z. B. *My Book* -> *HUMIG-BHAK-1*), nichts geloescht. Rueckfrage mit Belegung, freiem Platz und vorhandenen Ordnern; zweite Warnung, wenn auf der Platte schon eine Windows-Sicherung dieses Hosts liegt (gleicher Ordner *WindowsImageBackup\<Host>*); Hinweis, wenn die Platte frueher von HUMig anders benannt war; schon vergebene Bezeichnung wird abgelehnt

## v2.0.66 - 2026-10-02
### Neu
- App-Updates, *Zeitplaene ansehen*: Spalte *Fortschritt* waehrend eines Laufs (z. B. *12/26: GIMP (11 ok, 1 Fehler)*), Knoepfe *Neu laden* und *Markierte: Protokoll* (Protokoll am Ziel-PC je Programm)
### Geaendert
- Zeitplan: Verlauf wird nach jedem Programm gespeichert (nicht erst am Ende); bei Fehlern steht die Meldung des Installers dabei
- Fehler 0x8A150006 (Installer meldet Fehler) im Klartext

## v2.0.65 - 2026-10-02
### Behoben
- App-Updates: PowerShell 7 liess sich an PCs ohne angemeldeten Benutzer nicht einrichten - WinGet installiert seit PowerShell 7.6 die Store-Variante (MSIX), die als SYSTEM nicht verlaesslich laeuft. HUMig nimmt jetzt ein vorhandenes MSI-PowerShell oder legt eine eigene Kopie aus dem offiziellen ZIP-Paket ab (`Programme\HUMig\PowerShell7`, SHA256 geprueft)
- App-Updates: ein nicht gelesener PC wurde als *0 Update(s)* gemeldet - jetzt *NICHT gelesen* mit Grund

## v2.0.64 - 2026-10-02
### Neu
- **App-Updates an mehreren PCs**: Ziel *Mehrere PCs / EDV-Saal* (AD-Auswahl) - Suchen und Aktualisieren laufen parallel auf allen PCs (WinRM), Liste mit Spalte *PC*, Ergebnis je PC; ist am Ziel-PC niemand angemeldet, wird als SYSTEM mit PowerShell 7 gelesen (PowerShell 7 und WinGet-Modul werden bei Bedarf installiert)
- **App-Updates nach Zeitplan**: geplante Aufgabe *HUMig App-Updates* an den Ziel-PCs (taeglich oder Wochentage, Uhrzeit, PC wecken) - aktualisiert als SYSTEM alle Programme fuer alle Benutzer, Ausnahmen des Standorts gelten; *Zeitplaene ansehen* (naechster/letzter Lauf, Ergebnis, Verlauf uebernehmen, entfernen)
- **Fehlende Programme installieren** ueber WinGet, wenn kein Paket in der Softwareverteilung liegt (Katalog-Feld `WingetId`, fuer 33 Programme vorbelegt)
### Geaendert
- Reiter *App-Updates* steht jetzt neben *Werkzeuge*, *Server-Backup* ganz rechts
- App-Updates: Ergebnis je Programm erscheint sofort (nicht erst am Ende); erfolgreich aktualisierte verschwinden aus der Liste ohne neue Suche
- App-Updates: Fehler *Pruefsumme des Installers passt nicht* (0x8A150011) im Klartext - WinGet installiert dann aus Sicherheitsgruenden nicht

## v2.0.63 - 2026-10-02
### Behoben
- App-Updates: beim Suchen/Aktualisieren im Benutzerkonto ging ein leeres Konsolenfenster auf (Windows 11 / Windows Terminal) - startet jetzt ohne Fenster
- App-Updates: Verlauf zeigte mehrere Laeufe in einer Zeile (und faelschlich FEHLER)
- App-Updates: Bereich bei kurzen Namen (z.B. PuTTY / *PuTTY release ...*) richtig erkannt

## v2.0.62 - 2026-10-02
### Behoben
- App-Updates: Bereich falsch (*nur Benutzer*), wenn der WinGet-Name vom Deinstallations-Eintrag abweicht (z.B. *Adobe Acrobat Reader (64-bit)* / *Adobe Acrobat (64-bit)*, *Mozilla Thunderbird (de)* / *(x64 de)*) - Vergleich ohne Klammerzusaetze, Architektur und Versionsnummern, Teilnamen ab 8 Zeichen

## v2.0.61 - 2026-10-02
### Geaendert
- App-Updates: das WinGet-Modul laeuft als SYSTEM nur unter PowerShell 7 (*This cmdlet is not supported in Windows PowerShell*) - die Liste wird deshalb nur noch im Konto des angemeldeten Benutzers gelesen (sieht alle Programme), der *Bereich* kommt aus dem Deinstallations-Eintrag (Computer/Benutzer); Programme fuer alle Benutzer werden als SYSTEM ueber winget.exe aktualisiert (Ergebnis-Codes im Klartext)

## v2.0.60 - 2026-10-02
### Behoben
- App-Updates: Lesen als SYSTEM schlug fehl, wenn das Modul Microsoft.WinGet.Client nur fuer einzelne Benutzer installiert war - HUMig prueft das jetzt und bietet *WinGet einrichten* an (installiert es fuer alle Benutzer)
- App-Updates: Quellen werden mit der Suche im Benutzerkonto gelesen (vorher leer, wenn HUMig unter einem anderen Administratorkonto lief); hinzufuegen/entfernen als SYSTEM

## v2.0.59 - 2026-10-02
### Behoben
- App-Updates: Suche brach mit *Failed to create instance: -2147023174* ab, wenn HUMig unter einem anderen Administratorkonto lief als der angemeldete Benutzer (WinGet ist pro Benutzer registriert)
### Geaendert
- App-Updates lesen und aktualisieren jetzt ueber einmalige geplante Aufgaben: als **SYSTEM** (Programme fuer alle Benutzer, ohne UAC) und im Konto des **oben gewaehlten, angemeldeten Benutzers** (auch nur fuer ihn installierte Programme) - neue Spalte *Bereich*

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
