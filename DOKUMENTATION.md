# Praxis

Lokale Praxisakte. Sie läuft im Browser und speichert alles in einer SQLite-Datei. Es gibt keine Anmeldung. Der Server nimmt Verbindungen nur von diesem Rechner an, Adresse `127.0.0.1`, Port `8765`, solange man ihn nicht ausdrücklich für das Praxisnetz öffnet. Das steht unten unter Grenzen.

Adresse im Browser: <http://127.0.0.1:8765>

Die Bedienung für den Alltag steht in `HANDBUCH.md`. Das Aufsetzen auf einem weiteren Rechner steht in `INSTALL.txt`. Diese Datei beschreibt den Aufbau und den Betrieb. Stand: 15. November 2026, Linux Mint. Die vorige Fassung beschrieb den Mac vom 28. Oktober 2026.

## Ein Skript

Start, Stopp, das fensterlose Praxis-Fenster, der lokale Öffner, die Serveradresse, Sicherung, Wiederherstellung, Prüfung, das Programmpaket und die Einrichtung der Programme stehen in einem Skript:

```bash
./praxis start
./praxis fenster
./praxis lokal
./praxis ziel
./praxis ziel ADRESSE
./praxis stop
./praxis backup
./praxis restore DATEI
./praxis check
./praxis paket
./praxis install
```

Die Befehle gelten im Ordner des Programms. `./start` macht dasselbe wie `./praxis start`.

## Starten

`praxis start` startet `server.rb`. Das Skript nimmt `/usr/bin/ruby`, wenn es sqlite3 und webrick laden kann, sonst `ruby` aus dem PATH. Läuft der Server schon, sagt das Skript das und startet keinen zweiten. Die Zeile `Praxis bereit auf http://127.0.0.1:8765` bedeutet, dass er Anfragen annimmt. Den Browser öffnet `start` nicht selbst.

`praxis fenster` öffnet Google Chrome oder Chromium als eigenes Fenster ohne Tableiste und ohne Adresszeile, maximiert, mit einem eigenen Profil unter `~/.config/praxis-fenster`. Es startet `praxis lokal` auf diesem Rechner. Den Server startet es nur, wenn die hinterlegte Adresse dieser Rechner selbst ist. Dieselbe Fensterart liegt im Menü als **Praxis** (`~/.local/share/applications/praxis.desktop`). Im Fenster blendet F11 die Titelleiste aus. Im normalen Browser blendet F11 Tableiste und Adresszeile aus.

## Stoppen

Im Terminal, in dem `start` läuft: `Ctrl+C`.

Aus einem anderen Terminal:

```bash
./praxis stop
```

Das schickt dem Prozess das Signal TERM. Der Server beendet die Annahme neuer Anfragen und schließt die Datenbank. `kill -9` lässt die Schreibdatei von SQLite liegen und ist nur nötig, wenn der Prozess auf TERM nicht mehr reagiert.

Ob er läuft:

```bash
curl -fsS http://127.0.0.1:8765/api/health
```

Die Antwort `{"ok":true}` heißt, der Server antwortet. Das Protokoll steht in `data/server.log`. Es zeichnet Fehler auf, nicht jede Anfrage.

## Sicherung und Prüfung

`praxis backup` schreibt eine konsistente Kopie nach `sicherungen/`, auch während der Server läuft. Der Name enthält Datum und Uhrzeit. Danach prüft das Skript die Kopie. Ist sie beschädigt, wird sie verworfen.

`praxis check` prüft die laufende Akte: Integrität der Datei und die Fremdschlüssel. Der Server darf dabei laufen.

`praxis restore DATEI` ersetzt die Akte durch eine Sicherung. Zuerst wird die Datei geprüft. Eine beschädigte Sicherung wird abgewiesen. Dann fragt das Skript. Erst die Eingabe `ja` geht weiter. Der Server wird gestoppt, der jetzige Stand kommt nach `sicherungen/praxis-vor-wiederherstellung-….db`, und danach wird die gewählte Datei eingesetzt. Den Server startet die Wiederherstellung nicht wieder. Alte Sicherungen löscht das Skript nicht.

## Bedienung

Oben die Bereiche, in der Patientenakte unten ein Feld für Kürzel und Enter. `?` zeigt die Liste. Escape schließt das vorderste Fenster. Bleibt die Akte offen, liegt der Cursor danach wieder im Kürzefeld.

| Kürzel | Wirkung |
| --- | --- |
| P | Patientenliste |
| NEU | Neue Akte |
| A, B, D, DD, CAVE, PR, I, L | Anamnese, Befund, Diagnose, Dauerdiagnose, CAVE, Procedere, Info, Labortext |
| A+, B+, D+, DD+, CAVE+, PR+, I+, L+ | Alle Einträge dieser Art |
| D Kode, DD Kode | Katalogzeile als Diagnose oder Dauerdiagnose |
| DK | Diagnosenkatalog |
| LB | Labortabelle |
| RP | Rezept, Druck als Privatrezept auf DIN A4 |
| M | Medikamente |
| MP | Medikationsplan |
| DA | Dateien |
| BRIEFE | Briefe |
| AB | Abrechnung |
| ZI | Katalog, Position auf heute |
| ZI KÜRZEL | Diese Position mit dem Standardfaktor |
| ZI KÜRZEL 2,3 | Dieselbe Position mit Faktor |
| ZI KÜRZEL 13.11.2026 | Dieselbe Position an diesem Tag |
| ST | Stammdaten der geöffneten Person |
| PX | Einstellungen: Praxis, Adressen, Bausteine, Gebühren, Vorlagen |
| Kürzel eines Textbausteins | Diese Rubrik mit dem hinterlegten Text |
| B phar, A inf | Dieselbe Zeile, die Rubrik steht davor |
| TER | Terminkalender der Woche |
| WZ | Wartezimmer |

Der blaue Rubrikname in der Kartei öffnet dieselbe Sammlung wie das Plus-Kürzel. Text speichert beim Verlassen des Feldes. Ein eigenes Kürzel, Buchstaben, höchstens acht Zeichen, legt eine Info an und kann ein festes Kürzel nicht ersetzen. Die eigenen Kürzel stehen in `kuerzel/eigene.json`. Ein Textbaustein gehört zu einer Rubrik und schreibt einen Textblock. Das ist eine andere Liste. `D` und `DD` mit einem Kode bleiben der Diagnosenkatalog und werden nicht als Baustein gelesen. Tab in einer Zeile ersetzt das Kürzel unmittelbar vor dem Cursor durch den Baustein dieser Rubrik. Mitten im Wort bleibt der Text stehen.

`TER` öffnet die Woche aller Ressourcen. Eine Ressource hat eigene Öffnungszeiten, ein Raster von 10 oder 20 Minuten gilt für die Praxis. Ein Termin belegt eine Ressource und beginnt auf dem Raster. Eine Blockierung hat keinen Patienten. Urlaub deckt ganze Tage ab, für eine Ressource oder für alle. Dieselbe Person zur selben Zeit in zwei Ressourcen wird nur markiert. `TER` ändert nicht, welche Akte offen ist.

`WZ` setzt eine vorhandene Akte ins Wartezimmer und ändert dabei nicht, welche Akte offen ist. Ist eine Akte aufgerufen, setzt **In WZ** sie ans Ende der Liste. Das Fenster öffnet sich dann schon mit dieser Person. Ein heutiger Termin kann zugewiesen werden. Ein freier Termin heute kann belegt werden. Sonst bleibt die Person auf der Warteliste, ohne Termin. Im Kalender setzt **Anwesend** den Patienten des ausgewählten Termins auf die Liste und verknüpft den Termin. Die Reihenfolge steht in `wartezimmer.reihe`. **Hoch** und **Runter** tauschen mit dem Nachbarn, `PATCH /api/wartezimmer/:id` mit `richtung` `hoch` oder `runter`. Neue kommen ans Ende. Die Leiste unter den Bereichen zeigt diese Reihenfolge. Ein Klick auf den Namen dort öffnet die Akte. Gegangen nimmt nur die Anwesenheit weg. Die Liste ist `GET /api/wartezimmer` und wird etwa alle 20 Sekunden neu gelesen. `POST /api/wartezimmer` setzt jemanden. `nur_hinzufuegen` legt nur an und lässt eine vorhandene Zeile stehen. `DELETE /api/wartezimmer/:id` nimmt ihn heraus. Ein Angebot für eine vorhandene Akte ist `GET /api/wartezimmer/angebot`.

Dauerdiagnosen stehen in der Kopfzeile hinter den persönlichen Daten, durch Kommas getrennt. CAVE steht in derselben Zeile rechts, in Rot. Der Knopf **Dauer** an einer Diagnose schaltet die Kennzeichnung um. Eine neu angelegte verwandte Person wechselt die geöffnete Akte nicht.

Fenster lassen sich an der Titelleiste ziehen und an den Rändern in der Größe ändern. Stellung und Größe merkt sich der Browser unter dem Schlüssel `praxis.fenster`. Das ist eine Einstellung dieses Browsers, kein Inhalt der Akte.

Änderungen an `public/index.html` und `public/app.js` gelten nach einem Neuladen der Seite. Der Server sendet sie mit `Cache-Control: no-store`. Änderungen an `server.rb` gelten erst nach Stopp und neuem Start.

## Ordner

| Pfad | Inhalt |
| --- | --- |
| `praxis` | Start, Fenster, lokal, ziel, Stopp, Sicherung, Wiederherstellung, Prüfung, Paket |
| `start` | Ruft `praxis start` auf |
| `sicherungen/` | Konsistente Kopien der Akte |
| `server.rb` | Server, Datenbank, Import |
| `labor_katalog.rb` | Parameter, Einheiten, Umrechnung, Lesen von Befunden |
| `public/index.html` | Die eine Seite, Fenster und Gestaltung |
| `public/app.js` | Die Bedienung im Browser |
| `data/praxis.db` | Die Akte. Daneben `praxis.db-wal` und `praxis.db-shm`, solange der Server läuft |
| `data/server.log` | Protokoll des Servers |
| `data/unterschrift.*` | Unterschrift, falls eine gespeichert ist |
| `dateien/` | Dateien der Akten |
| `briefe/` | Erzeugte Briefe |
| `vorlagen/` | Briefvorlagen. Jede Datei `*.odt` ist eine. Mitgeliefert sind `Befundbericht.odt` und `Kurzbrief.odt` |
| `lokal.rb` | Öffnet eine geholte Datei auf dem Rechner, an dem gearbeitet wird |
| `kuerzel/eigene.json` | Eigene Kürzel |
| `parameter/` | Laborkatalog. `standard.json` ist der mitgelieferte Stand, `eigene.json` gewinnt beim selben Parameter |
| `ocr/` | Wahlweise ein lokales Tesseract für Linux. Ein installiertes Tesseract gilt zuerst. Im Programmpaket liegt der Ordner nicht |
| `install.sh` | Richtet die Programme auf Linux oder einem Mac ein. Die Akte bleibt |
| `import/` | Die ICD-10-GM, wenn sie dort abgelegt ist. Im Programmpaket liegt der Ordner nicht |

Manche RTF-Dateien enden mit einer angehängten Altlast. Beim Öffnen und beim Auslesen wird sie abgeschnitten und die Arbeitskopie unter `dateien/` gespeichert, damit LibreOffice die Datei lädt.

## Aufbau

Ruby, das Modul `sqlite3` und das mitgelieferte WEBrick. Für Befunde kommen Poppler (`pdftotext`, `pdftoppm`) und Tesseract dazu. Ein installiertes Tesseract gilt zuerst. Eine zu bearbeitende Datei öffnet `lokal.rb` auf dem Arbeitsplatz, unter Linux mit `/usr/bin/xdg-open`, auf einem Mac mit `open`. Fehlt `praxis lokal` und kommt die Seite von demselben Rechner, öffnet der Server die Datei selbst. Ein entfernter Aufruf startet auf dem Server kein Programm.

`server.rb` ist eine Klasse `Praxis`. Beim Start legt sie die Ordner an, öffnet `data/praxis.db`, schaltet Fremdschlüssel und das WAL-Tagebuch ein, legt fehlende Tabellen an und führt kleine Nachträge aus. Jede Anfrage läuft durch `handle`. Seiten und Skripte kommen aus `public/`. Alles unter `/api/` ist JSON. Beträge stehen in Cent. Der Faktor einer Position steht in Tausendsteln, 2300 ist 2,3. Tage stehen in der Datenbank als `jjjj-mm-tt` und in der Oberfläche als `tt.mm.jjjj`. Die nächste Patientennummer ist eins höher als die bisher höchste.

Tabellen: `person`, `relation`, `entry`, `catalog`, `medicine`, `position`, `invoice`, `plan`, `prescription`, `prescription_line`, `file`, `letter`, `practice`, `meta`, `diagnose`, `ressource`, `ressource_zeit`, `termin`, `wartezimmer`, `adresse`, `baustein`. Die Akte eines Tages sind Zeilen in `entry`. `entry.dauer` kennzeichnet eine Dauerdiagnose. Ein Rezept, eine Position, eine Datei oder ein Brief hat zusätzlich die eigene Tabelle und verweist mit `ref_id` bzw. `entry_id` auf die Zeile in der Akte. `position.betrag` hält den berechneten Betrag fest. `position.faktor` hält den Faktor fest. Ältere Positionen haben dort keinen Wert und behalten ihren Betrag.

`baustein` hält die Textbausteine. Eine Zeile hat `kind` aus den Textarten, `kuerzel` und `text`. Dasselbe Kürzel darf in zwei Rubriken stehen, in derselben Rubrik nur einmal, ohne Rücksicht auf Großschreibung. Ein festes Kürzel und ein Info-Kürzel aus `kuerzel/eigene.json` werden abgewiesen. `GET /api/bausteine` listet die Zeilen, optional gefiltert mit `q`. `POST /api/bausteine` legt eine Zeile an, `PATCH /api/bausteine/:id` ändert sie, `DELETE /api/bausteine/:id` löscht sie. Geschriebene Karteizeilen bleiben. Beim ersten Start liegen zwei Beispiele darin: `phar` als Befund und `inf` als Anamnese. Der Merker dafür steht in `meta` unter `baustein_saat`. Danach kommt nichts mehr dazu, auch wenn man die Beispiele entfernt. Die Oberfläche liegt unter Einstellungen bei **Bausteine**.

`adresse` ist das Adressbuch der Praxis. Eine Zeile ist keine Person und bekommt keine Patientennummer. `art` ist `arzt`, `versicherung` oder `sonst`. Dazu kommen Anrede, Name, Zusatz, Straße, PLZ, Ort, Telefon und Notiz. Die PLZ ist leer oder hat vier oder fünf Stellen. `GET /api/adressen` listet die Zeilen, optional gefiltert mit `q`. `POST /api/adressen` legt eine Zeile an, `PATCH /api/adressen/:id` ändert sie, `DELETE /api/adressen/:id` löscht sie. Telefon und Notiz stehen nur in dieser Liste.

`letter.adresse_id` verweist auf so eine Zeile. Leer heißt, der Brief geht an die Anschrift der Akte. Ist der Verweis gesetzt, stehen Anrede, Name, Zusatz, Straße und Ort in `{{PATIENT}}` und `{{ANSCHRIFT}}`. Die erste Zeile füllt `{{PATIENT}}`, der Rest `{{ANSCHRIFT}}`. `{{GEBOREN}}` enthält dann Name und Geburtsdatum des Patienten. Die Karteizeile bleibt der Dateiname, die Datei liegt unter `briefe/` und heißt nach dem Patienten. Löschen der Adresse leert den Verweis. Die geschriebene Datei bleibt. `POST /api/patients/:id/letters` nimmt dafür `adresse_id`. Ohne dieses Feld bleibt der Empfänger der Patient.

`practice` hält eine Zeile. `rechnungstext` ist der Gruß über den Positionen. `rechnungskopf` und `rezeptkopf` sind die Kopfzeilen von Rechnung und Privatrezept. Leer speichert nichts, und der Druck nimmt den vorgegebenen Text. `PUT /api/practice/rechnung`, `PUT /api/practice/rechnungskopf` und `PUT /api/practice/rezeptkopf` schreiben sie. Platzhalter im Kopf sind `{{ARZT}}`, `{{FACH}}`, `{{ARZTNUMMER}}`, `{{ADRESSE}}`, `{{TELEFON}}`, `{{TITEL}}`, `{{VORNAME}}`, `{{NAME}}` und `{{DATUM}}`. Der Rechnungskopf ist im Druck höchstens 32 mm hoch, damit das Adressfenster frei bleibt. Positionen, Arzneimittel, Unterschrift und Stempel erzeugt das Programm.

`GET /api/templates` nennt jede Datei `*.odt` in `vorlagen/`. Ein Brief füllt `{{PATIENT}}`, `{{ANSCHRIFT}}`, `{{GEBOREN}}`, `{{DATUM}}`, `{{BETREFF}}`, `{{TEXT}}` und dieselben Praxisplatzhalter. `GET` und `PUT` auf `/api/templates/:name/datei` lesen und ersetzen diese Datei. Ein neuer Name entsteht, indem die Datei in den Ordner gelegt wird. `PUT` legt keine neue Vorlage an. Der Name darf Buchstaben, auch Umlaute, Ziffern, Leerzeichen, Unterstrich, Bindestrich und Klammern enthalten, höchstens 80 Zeichen.

`diagnose` enthält die Klassentitel der ICD-10-GM 2026, BfArM, Stand 12.09.2025, Quelle in `meta` unter `icd10gm`. Eigene Zeilen haben die Quelle `eigen` und gelten vor demselben Kode. Die amtlichen Titel werden nicht verändert und nicht als ganzes Verzeichnis weitergegeben. Eine deutsche ICD-11 zum Herunterladen gibt es dafür nicht. Die Importdatei ist `import/icd/meta/Klassifikationsdateien/icd10gm2026syst_kodes.txt` aus dem BfArM-Zip `icd10gm2026syst-meta.zip`, Fassung Metadaten TXT (CSV), Stand 12.09.2025. `ensure_diagnosen` liest sie beim Start, wenn `icd10gm` nicht `2026` ist oder weniger als 1001 Katalogzeilen da sind. Zeilen mit `quelle` `eigen` bleiben, die Katalogzeilen werden ersetzt. Fehlt die Datei, warnt der Server und läuft weiter. Herunterladen und der genaue Pfad stehen in `README.md`. Der Ordner `import` fehlt im Programmpaket.

`medicine` enthält die Arzneimittel dieser Praxis. Eine amtliche Arzneimitteldatenbank liegt nicht in der Akte. Der öffentliche Teil von AMIce ist eine kostenlose Recherche über PharmNet.Bund, keine Datei. MMI Pharmindex Rohdaten und der ABDA-Artikelstamm lassen sich nur mit Lizenz einbinden. Die Quellen stehen in `README.md`.

`public/index.html` enthält alle Fenster und die Gestaltung. `public/app.js` spricht mit `/api/`, zeichnet die Akte und merkt sich die Fenster. Es gibt keinen Übersetzungs- oder Bauschritt. Patiententext wird als Text eingesetzt, nicht als HTML.

## Kommentare im Code

`server.rb`, `labor_katalog.rb`, `public/app.js`, `public/index.html` und das Skript `praxis` sind auf Englisch kommentiert. Die Kommentare nennen die Regeln, die man der einzelnen Zeile nicht ansieht: nur dieser Rechner, Beträge in Cent, der Faktor in Tausendsteln, die Patientennummer, Dauerdiagnose und CAVE, eigene Kürzel, das Labor und die Sicherung. Die tägliche Bedienung steht im Handbuch. Diese Datei beschreibt den Aufbau.

## Änderungen seit der Mac-Fassung vom 28. Oktober 2026

Das Programm läuft unter Linux und auf einem Mac. Ruby kommt von der Installation.

Escape schließt das vorderste Fenster. Vorher legte Escape nur den Cursor ins Kürzefeld.

Hinzugekommen sind die Textarten Diagnose, Dauerdiagnose und CAVE, die Sammlungen mit Plus, der Diagnosenkatalog, eigene Kürzel und die Kopfzeile mit Dauerdiagnosen und CAVE. Die Labortabelle, das Lesen von Befunden mit Kontrolle vor dem Speichern, das Öffnen der Dateien im zugehörigen Programm und der Faktor bei Gebühren sind ebenfalls neu. Ein amtliches Gebührenverzeichnis wird nicht mitgeliefert. `praxis fenster` und der Menüeintrag Praxis öffnen die Akte ohne Browserleiste. Der Quelltext trägt englische Kommentare zu diesen Regeln. Der Terminkalender unter `TER` und das Wartezimmer unter `WZ` kamen am 12. November 2026 dazu. Briefe übernehmen angekreuzte Karteizeilen, heißen nach Patient und Datum und können eine ungarische Fassung enthalten, die auf diesem Rechner entsteht. In der Kartei steht nur der Dateiname. Der Brieftext bleibt in der Datei. Ein eingelesener ungarischer Brief kann mit Auf Deutsch eine deutsche Fassung direkt unter dem Dateinamen bekommen, ebenfalls auf diesem Rechner. Rechnungen und die Briefvorlagen sind DIN A4, Form B. Das Adressfeld beginnt 45 mm unter der Oberkante. Eine schon in LibreOffice gespeicherte Briefvorlage wird dabei nicht überschrieben. Das Geschlecht liegt in den Stammdaten als weiblich, männlich, divers oder leer. `{Anrede}` wird daraus gebildet: weiblich zu „Sehr geehrte Frau …“, männlich zu „Sehr geehrter Herr …“, sonst „Guten Tag“. Im Rechnungstext ersetzen `{Anrede}`, `{Nachname}` und `{Vorname}` die Angaben des Rechnungsempfängers. Jede Abrechnungsposition hat einen Tag. Der lässt sich vor dem Buchen und danach ändern, auch auf einer schon gedruckten Rechnung. Das Druckdatum bleibt. Die Rechnung nennt den Behandlungszeitraum und den Tag jeder Leistung. Ausschlüsse zwischen Ziffern sind nicht hinterlegt. Die gedruckte Rechnung zeigt einen Text, die Leistungsbezeichnungen, die Summe und, wenn eingetragen, IBAN und BIC. Die Kürzel stehen nicht auf dem Papier. IBAN und BIC liegen in den Praxisdaten. Der Rechnungstext liegt unter Vorlagen. Ist er leer, gilt der vorgegebene Gruß. Der Standardfaktor steht bei den Gebühren in den Einstellungen. Leer bedeutet 1. `POST /api/invoices/:id/druck` setzt das Druckdatum nur beim ersten Mal. Eine Rechnung lässt sich danach im Faktor ändern, eine Position herausnehmen oder hinzufügen. `PX` und der Knopf **Einstellungen** öffnen Praxisdaten, Adressen, Gebührenkatalog und Vorlagen, ohne eine Akte zu verlangen. Eine Gebühr ändert man dort. `DELETE /api/catalog` nimmt nur die Katalogzeile. Gebuchte Positionen bleiben. `POST /api/templates/open` öffnet eine Briefvorlage in LibreOffice. `erfassen.html` sammelt Besuche auf einem Android-Gerät. Straße (30), Hausnummer (10) und PLZ stehen auf der Erfassungsseite immer, auch bei einer bekannten Akte, und dürfen leer bleiben. Die PLZ hat vier oder fünf Stellen. Die Hausnummer steht in der Akte am Ende der Straße. Die Patientennummer hat höchstens fünf Stellen. `POST /api/besuche` legt sie in die Akte, ohne die offene Akte zu wechseln. Textbausteine liegen in der Tabelle `baustein`. `phar` schreibt einen Befund, `inf` eine Anamnese. Beides lässt sich unter Einstellungen bei **Bausteine** ändern. In der Zeile setzt Tab das Kürzel der jeweiligen Rubrik ein. Unter Einstellungen führt **Adressen** Ärzte, Versicherungen und andere Empfänger. Das sind keine Akten. Ein Brief kann an so eine Adresse gehen. Im Fenster steht dann diese Anschrift, rechts Name und Geburtsdatum des Patienten. Die Akte bleibt die des Patienten. In der Kartei steht weiter nur der Dateiname. `RP` druckt ein Privatrezept auf DIN A4. Darauf stehen Praxis, Datum, Patient mit Anschrift und Geburtsdatum, die Arzneimittel, die Unterschrift und der Stempel. Ein Blatt trägt höchstens sechs Arzneimittel. Ein Klick auf die Karteizeile öffnet denselben Druck. Rechnungskopf und Rezeptkopf liegen unter Vorlagen. Leer heißt der vorgegebene Kopf. `PUT /api/practice/rechnungskopf` und `PUT /api/practice/rezeptkopf` speichern ihn. Der Körper der Rechnung und des Rezepts bleibt erzeugt.

## Arbeitsplatz

`~/.config/praxis/ziel` nennt die Serveradresse dieses Rechners. Fehlt die Datei, gilt `http://127.0.0.1:8765`. `./praxis ziel` zeigt sie, `./praxis ziel ADRESSE` schreibt sie. Sie liegt nicht in der Datenbank.

`lokal.rb` hört nur auf `127.0.0.1:8764`. Die Seite bittet ihn, eine Datei zu holen, hier zu speichern und mit dem lokalen Programm zu öffnen. Eine spätere Änderung schickt er an denselben Pfad zurück. Erlaubt sind nur `/api/files/:id/raw`, `/api/letters/:id/datei` und `/api/templates/:name/datei`. `PRAXIS_NO_OPEN=1` überspringt das Öffnen. `./praxis fenster` startet ihn. Fehlt er, und die Seite kommt von demselben Rechner, öffnet der Server die Datei wie bisher. Von einem anderen Rechner aus bleibt sie zu, bis `praxis lokal` läuft.

`PUT` auf diese drei Pfade ersetzt die gespeicherte Datei. Der Pfad muss in `dateien/`, `briefe/` oder `vorlagen/` bleiben. Eine neue Vorlage entsteht dadurch nicht.

## Paket

`./praxis paket` schreibt `praxis-DATUM.tar.gz`. Darin fehlen `data/`, `dateien/`, `briefe/`, `sicherungen/`, `kuerzel/eigene.json`, `parameter/eigene.json`, `import/`, `uebersetzung/`, `ocr/` und `WEITER.txt`. Die Briefvorlagen bleiben. Rechnungskopf, Rezeptkopf und der Rechnungstext stehen in der Datenbank und kommen mit `praxis backup` und `praxis restore` mit. `./praxis install` richtet die Programme ein. `--mit-ungarisch` baut `uebersetzung/` neu und lädt die Modelle. `INSTALL.txt` beschreibt Linux und Mac.

## Grenzen

Der Server hört weiter nur auf diesem Rechner, solange `PRAXIS_BIND` auf `127.0.0.1` steht. Ein anderer Rechner erreicht ihn erst mit `PRAXIS_BIND` und `PRAXIS_ALLOW_REMOTE=1`. Dafür gibt es keine Anmeldung. Nur ein vertrautes Praxisnetz, nicht das offene Internet.

`PRAXIS_PORT` ändert den Port. `PRAXIS_DB` nennt eine andere Datenbankdatei. `PRAXIS_ROOT` legt Daten, Dateien und Briefe woanders ab. Diese Schalter sind für eine Probe gedacht. Der normale Start braucht keinen davon.
