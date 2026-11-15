# Handbuch

So arbeitet man mit der Praxisakte. Die technische Beschreibung steht in `DOKUMENTATION.md`. Was an Verzeichnissen mitgeliefert wird und was nicht, steht in `README.md`.

Die Akte liegt auf einem Rechner. Es gibt keine Anmeldung. Andere Arbeitsplätze richtet man ein, wie unten unter Weiterer Rechner beschrieben.

## Programm öffnen

Im Menü den Eintrag **Praxis** wählen. Es öffnet sich ein eigenes Fenster ohne Tableiste und ohne Adresszeile.

Dasselbe Fenster aus dem Terminal, im Ordner des Programms:

```bash
./praxis fenster
```

Der Befehl startet auf diesem Rechner zusätzlich `praxis lokal`. Darüber gehen Briefe, Vorlagen und Dateien hier auf. Läuft der Server noch nicht und sucht dieser Rechner ihn bei sich selbst, startet der Befehl ihn mit.

Im normalen Browser lautet die Adresse <http://127.0.0.1:8765>. **F11** blendet Tableiste und Adresszeile aus. Nochmal **F11** holt sie zurück. Im Praxis-Fenster blendet **F11** zusätzlich die Titelleiste aus.

Lädt die Seite nicht, im Terminal:

```bash
./praxis start
```

Die Zeile `Praxis bereit auf http://127.0.0.1:8765` heißt, der Server nimmt Anfragen an. Das Fenster, in dem `start` läuft, offen lassen. Stoppen dort mit `Ctrl+C`, oder aus einem zweiten Terminal mit `./praxis stop`.

Eine Sicherung der Akte:

```bash
./praxis backup
```

Die Kopie liegt unter `sicherungen/`. Der Server darf dabei laufen.

## Der Bildschirm

Oben eine Leiste mit den Bereichen: Patienten, Patientenakte, Abrechnung, Medikamente, Medikation, Rezept, Labor, Dateien, Briefe, Termine, Einstellungen.

Darunter liegen Fenster auf der Arbeitsfläche. Ein Fenster zieht man an der Titelleiste. Die Größe ändert man an den Rändern. Stellung und Größe merkt sich dieser Browser. **Escape** schließt das vorderste Fenster. Das Kreuz in der Titelleiste schließt dieses Fenster.

In der Patientenakte steht unten das Feld für die Kürzel. Kürzel eintippen, dann **Enter**. `?` und Enter öffnet die Liste aller Kürzel.

Ein Klick auf den blauen Rubriknamen in der Kartei öffnet alle Einträge dieser Art. Dieselbe Sammlung öffnet das Kürzel mit Plus: `A+` alle Anamnesen, `B+` alle Befunde, und so weiter.

Text in der Kartei ändert man durch Hineinklicken. Verlässt man das Feld, wird gespeichert.

## Kopf der Akte

In der ersten Zeile stehen Nummer, Name und die persönlichen Angaben. Dahinter stehen die Dauerdiagnosen, durch Kommas getrennt. Ganz rechts steht **CAVE**, in Rot. Ein Klick auf die Dauerdiagnosen oder auf CAVE öffnet die jeweilige Liste.

Darunter stehen die Verwandtschaften, wenn welche eingetragen sind. Ein Klick auf einen Namen öffnet dessen Akte.

Ein Klick auf den Namen des geöffneten Patienten öffnet seine Stammdaten.

## Akte suchen und anlegen

`P` und Enter öffnet die Patientenliste. Ein Feld sucht zugleich nach Nummer, Name, Geburtsdatum, Ort, PLZ, Straße, Ausweis, Versicherung, Krankenkasse, Mutter und Spezies.

`NEU` und Enter nimmt jemanden neu auf. Die nächste Nummer ist um eins höher als die höchste bisher vergebene. Eine frei gewordene Nummer wird nicht wieder vergeben.

Spezies sind Mensch, Hund, Pferd und Tier. Sie benutzen dieselbe Kartei.

## In die Kartei schreiben

Das Kürzel gilt für den geöffneten Patienten und für den heutigen Tag. Die Kartei ist zeitlich geordnet.

| Kürzel | Was entsteht |
| --- | --- |
| `A` | Anamnese |
| `B` | Befund |
| `D` | Diagnose, leer |
| `DD` | Dauerdiagnose, leer |
| `CAVE` | Hinweis, der oben rot steht |
| `PR` | Procedere |
| `I` | Info |
| `L` | Labortext, frei formuliert |

Nach dem Enter den Text in die neue Zeile schreiben und das Feld verlassen.

## Diagnosen

`DK` öffnet den Diagnosenkatalog. Oben suchen, mit Kode oder mit Text. Ein Treffer übernimmt die Zeile in die Akte.

`D J06.9` übernimmt diese Katalogzeile direkt, ohne das Fenster. Statt `J06.9` geht auch die Schreibweise ohne Punkt. `DD J06.9` macht dasselbe und kennzeichnet die Zeile als Dauerdiagnose.

In der Kartei stehen Kode, Diagnose und Langtext in einer Zeile. Die Rubrik links heißt Diagnose oder Dauerdiagnose.

Der Knopf **Dauer** an einer Diagnose macht sie zur Dauerdiagnose. Nochmal drücken hebt das auf.

Eine eigene Zeile, die nicht im Katalog steht, trägt man unten im Diagnosefenster ein: Kürzel, Diagnose, Langtext, dann **Merken**. Gibt es dasselbe Kürzel auch im Katalog, gilt die eigene Zeile.

Der Katalog sind die Klassentitel der ICD-10-GM 2026 vom BfArM, Stand 12.09.2025. Es ist nicht die ganze Systematik mit Einschlüssen, und es ist nicht die ICD-11. Die amtlichen Titel bleiben unverändert. Die Datei kommt vom BfArM, Metadaten TXT (CSV), und liegt unter `import/icd`. Wie man sie holt und einbindet, steht in `README.md`. Fehlt sie, findet `DK` nur die eigenen Zeilen.

`D+` zeigt alle Diagnosen, `DD+` alle Dauerdiagnosen, `CAVE+` alle CAVE-Hinweise.

## Eigene Kürzel

`?` öffnet die Liste. Unten ein eigenes Kürzel aus Buchstaben, höchstens acht Zeichen, und eine Bezeichnung, dann **Merken**.

Das Kürzel legt danach eine Info mit dieser Bezeichnung an. Ein festes Kürzel wie `A`, `D`, `DA` oder `ZI` lässt sich damit nicht überschreiben. **Entfernen** löscht nur das eigene Kürzel, nicht die schon geschriebenen Einträge.

## Textbausteine

Ein Textbaustein gehört zu einer Rubrik und schreibt dort einen fertigen Text. Das ist etwas anderes als ein eigenes Kürzel, das nur eine Info mit einer kurzen Bezeichnung anlegt.

Unter Einstellungen, **Bausteine**, stehen Rubrik, Kürzel und Text. Oben suchen, ein Klick auf eine Zeile holt sie in das Formular. **Aufnehmen** legt eine neue Zeile an, **Speichern** schreibt eine geöffnete zurück. **Leeren** leert das Formular. **Entfernen** löscht den Baustein. Einträge, die schon in der Akte stehen, bleiben. **In die Akte** schreibt den Text aus dem Formular in die geöffnete Akte.

In der Akte tippt man das Kürzel und drückt Enter. `phar` legt den hinterlegten Befund an. `inf` legt die hinterlegte Anamnese an. Beide stehen schon in der Liste und lassen sich ändern oder entfernen. Steht dasselbe Kürzel in zwei Rubriken, schreibt Enter nichts und verlangt die Rubrik davor, zum Beispiel `B phar` oder `A inf`. Das geht für Anamnese, Befund, CAVE, Procedere, Info und Labor.

`D` und ein Kode bleiben der Diagnosenkatalog, ebenso `DD` und ein Kode. Ein Baustein für Diagnose oder Dauerdiagnose kommt über das Kürzel allein, wenn es nur in dieser einen Rubrik steht, über **In die Akte**, oder mit Tab in der Zeile.

In einer Zeile der Akte das Kürzel an den Text schreiben und Tab drücken. Es gilt die Rubrik dieser Zeile. Der Cursor steht danach hinter dem eingesetzten Text. Mitten in einem Wort passiert nichts. Das Feld speichert beim Verlassen, wie bisher.

Ein festes Kürzel und ein Info-Kürzel lassen sich nicht als Textbaustein verwenden. `?` zeigt die Bausteine unter den festen Kürzeln.

## Labor

`LB` öffnet die Labortabelle. Die Parameter stehen untereinander, die Tage nebeneinander. Zum Wert gehört die Einheit. Darunter steht der Referenzbereich. Liegt eine Umrechnung vor, erscheint der Wert zusätzlich in der bevorzugten Einheit, mit einem Ungefähr-Zeichen.

`L` bleibt der freie Labortext. `L+` zeigt alle Labortexte.

Neue Werte von Hand: im Laborfenster eintragen und mit **Eintragen** speichern.

Einen Befund aus einer Datei lesen: **Befund lesen** oder, in den Dateien, **Als Laborbefund lesen**. Die erkannten Zeilen erst prüfen. **Übernehmen** schreibt sie in die Tabelle. **Verwerfen** schreibt nichts. Für diesen Tag erscheint in der Kartei eine Zeile Tabelle, wenn noch keine da ist.

Ein unbekannter Parameter landet unter Ohne Zuordnung. **Zuordnen** verbindet ihn mit einer Zeile des Katalogs. **Zuordnung speichern** merkt sich das für das nächste Mal.

## Dateien

`DA` öffnet die Dateien dieser Akte. Ein Klick öffnet die Datei im zugehörigen Programm auf diesem Rechner. PDF, Bilder, RTF und Word gehen an die Programme hier. Eine gespeicherte Änderung geht zurück an den Server. Öffnet keines, zeigt das Fenster die Datei selbst. Läuft `praxis lokal` auf diesem Rechner nicht, und die Seite wurde hier geladen, öffnet der Server die Datei.

**Auf Deutsch** liest einen ungarischen Brief und speichert die deutsche Fassung direkt unter dem Dateinamen, in der Kartei und im Feld Deutsch. PDF, LibreOffice, Word, RTF, Text und Bilder gehen. Die Übersetzung bleibt auf diesem Rechner. Lies sie gegen, bevor du sie weiterverwendest. **In die Akte** übernimmt das Feld Deutsch zusätzlich als Befund.

## Rezept und Medikation

`RP` öffnet das Rezept. Aus der Medikation und aus der Arzneimittelliste Zeilen übernehmen. An der Zeile stehen die Menge in Packungen, die Dosierung und eine Anweisung. **Blatt** speichert das Rezept in der Akte und zeigt den Druck. Ein Blatt enthält höchstens sechs Arzneimittel. Der Rest kommt auf das nächste Blatt. Ein Klick auf das Rezept in der Akte öffnet denselben Druck wieder.

Der Druck ist ein Privatrezept auf DIN A4. Oben links steht der Rezeptkopf. Solange man ihn nicht ändert, stehen dort der Name, darunter das Fach aus den Einstellungen, die Arztnummer, die Adresse und die Telefone. Rechts stehen das Wort Privatrezept, das Datum und bei mehreren Blättern die Blattzahl. Darunter Name, Anschrift und Geburtsdatum des Patienten. Dann folgen die Arzneimittel. Unten stehen die Unterschrift und der Stempel aus den Praxisdaten. Den Kopf ändert man unter Einstellungen bei **Vorlagen**, Feld **Rezeptkopf**. Fehlt eine Menge oder eine Dosierung, bleibt diese Zeile weg. Im Druckdialog Rand auf keine stellen, die Kopfzeile des Browsers aus und den Maßstab auf 100.

`M` sucht in den Arzneimitteln, die in dieser Praxis angelegt sind. Eine amtliche Liste liegt nicht bei. Nachschlagen kann man im öffentlichen Teil von AMIce über PharmNet.Bund. Einbauen darf man nur lizenzierte Rohdaten, MMI Pharmindex oder den ABDA-Artikelstamm. Das steht in `README.md`. `MP` öffnet den Medikationsplan. Dort eine Zeile hinzufügen, stoppen oder die Einnahmeliste drucken.

## Termine

`TER` oder **Termine** öffnet die Woche, auch ohne geöffnete Akte. Jede Ressource ist eine Spur in jedem Tag. Dieselbe Uhrzeit steht auf einer Linie, damit eine Überschneidung sichtbar ist.

**Einrichten** legt die Ressourcen an, zum Beispiel Sprechzimmer, Blutentnahme oder ein Gerät. Jede hat eigene Zeiten. Ein Tag kann zwei Abschnitte haben, dazwischen ist die Pause. Die Zeiten gelten erst nach **Speichern**. Ohne gespeicherte Zeiten ist die Woche geschlossen und es lässt sich nichts vergeben. Das Raster gilt für die ganze Praxis und ist 10 oder 20 Minuten. Anfang, Ende und die Dauer liegen auf diesem Raster. `8.00` gilt wie `08:00`.

Die Dauer steht oben im Fenster. **Termin** legt den geöffneten Patienten auf eine freie Strecke. Das wechselt die Akte nicht. Ohne Akte ist nur **Blocken** möglich. Ein Klick auf eine belegte Strecke wählt sie aus, **Aufheben** nimmt sie weg. Steht ein Patient auf der Strecke, setzt **Anwesend** ihn ans Ende der Warteliste und markiert den Termin. Die offene Akte bleibt.

**Urlaub** blockt ganze Tage, für eine Ressource oder für alle. In den Wochen, durch die man blättert, ist diese Zeit geschlossen. Zwei Ressourcen zur selben Stunde bleiben möglich. Liegt dieselbe Person zur selben Zeit in zwei Ressourcen, sind beide Einträge rot umrandet.

## Wartezimmer

`WZ` oder der Knopf **Wartezimmer** in der Leiste unter den Bereichen öffnet das Fenster. Ist eine Akte aufgerufen, ist diese Person schon ausgewählt. **Auf die Warteliste** setzt sie ans Ende. **In WZ** tut dasselbe mit einem Klick, ohne das Fenster. Die geöffnete Akte wechselt dabei nicht.

Ins Suchfeld mindestens zwei Buchstaben oder die Patientennummer, wenn eine andere Person dazukommt. Ein Treffer wird ausgewählt. Die geöffnete Akte wechselt dabei nicht. Steht die Person noch nicht im System, heißt es **Zuerst aufnehmen**. Dann zuerst `NEU`, danach wieder `WZ`.

Hat die Person heute einen Termin, setzt **Zuweisen** sie darauf. **Belegen** nimmt einen freien Termin heute, in der Dauer im Fenster. Dafür müssen die Öffnungszeiten der Ressource gespeichert sein. Im Kalender setzt **Anwesend** an einem ausgewählten Termin dieselbe Person auf die Liste und markiert den Termin.

Die Leiste zeigt die Reihenfolge, in der aufgerufen wird. Dieselbe Zeile steht oben in `TER`. **Hoch** und **Runter** schieben eine Person vor oder zurück. Wer neu dazukommt, kommt ans Ende. Wer keinen Termin hat, kann so hinter die Termine geschoben werden. Ein Klick auf den Namen öffnet diese Akte. Das Kreuz nimmt die Person aus dem Wartezimmer. Der Termin im Kalender bleibt. Ohne Termin ist der Eintrag gelb. Mit Termin hat er im Kalender einen grünen Strich.

Ein zweites Fenster auf diesem Rechner sieht dieselbe Liste, kurz darauf.

## Briefe

`BRIEFE` öffnet die Briefe. Oben stehen die Texte der offenen Kartei. Ankreuzen und **In den Brief** setzen, oder **Alle Texte**. Der Text lässt sich danach noch ändern. Zur Wahl stehen alle Briefvorlagen aus dem Ordner `vorlagen`. Mitgeliefert sind Befundbericht und Kurzbrief. **Auch auf Ungarisch** hängt eine ungarische Fassung an. Die Übersetzung bleibt auf diesem Rechner. Lies sie gegen, bevor du den Brief mitgibst.

**Empfänger** steht auf **Patient**, solange nichts anderes gewählt ist. Dann geht der Brief an die Anschrift der Akte. In der Liste daneben stehen die Adressen aus den Einstellungen: Ärzte, Versicherungen und andere Empfänger. **Adressen** öffnet diese Liste. Steht dort ein Empfänger, füllt seine Anschrift das Fenster. Rechts stehen Name und Geburtsdatum des Patienten. Der Brief bleibt in der Akte dieses Patienten.

Die mitgelieferten Vorlagen sind ein DIN-A4-Blatt. Der Briefkopf füllt die oberen 45 mm, das Adressfeld beginnt darunter und passt in einen Fensterumschlag. `{{PATIENT}}` und `{{ANSCHRIFT}}` stehen im Fenster, `{{DATUM}}` und `{{GEBOREN}}` rechts daneben. `{{BETREFF}}` und `{{TEXT}}` sind Betreff und Brieftext. `{{ARZT}}`, `{{TITEL}}`, `{{VORNAME}}`, `{{NAME}}`, `{{FACH}}`, `{{ARZTNUMMER}}`, `{{ADRESSE}}` und `{{TELEFON}}` kommen aus den Praxisdaten. Bei einem anderen Empfänger ist die erste Fensterzeile die Anrede, falls eine eingetragen ist, sonst der Name. Darunter stehen Zusatz, Straße und Ort. Rechts stehen dann Name und Geburtsdatum des Patienten. Der Brief wird als Datei mit Nachname, Vorname und Datum des Patienten gespeichert. In der Kartei steht nur dieser Dateiname. Der Text und die ungarische Fassung stehen nur in der Datei. Ein Klick auf den Namen öffnet sie in LibreOffice auf diesem Rechner. Eine Änderung in LibreOffice geht zurück an den Server.

Eine weitere Briefart legt man selbst an. In LibreOffice ein neues Textdokument schreiben, oder eine vorhandene Vorlage kopieren, und als `.odt` in den Ordner `vorlagen` speichern. Der Name ohne Endung erscheint nach dem Neuladen unter `BRIEFE` und unter Einstellungen bei **Vorlagen**. Erlaubt sind Buchstaben, auch ä, ö, ü und ß, Ziffern, Leerzeichen, Unterstrich, Bindestrich und Klammern. Eine eigene Vorlage behält das Seitenbild, das man in LibreOffice speichert. Die beiden mitgelieferten Dateien werden nicht überschrieben, sobald LibreOffice sie einmal gespeichert hat.

## Besuche unterwegs

Die Datei `erfassen.html` auf das Android-Gerät kopieren und in Chrome öffnen. Sie merkt sich die Besuche auf dem Gerät. Für eine bekannte Akte die Nummer, höchstens fünf Stellen. Für eine neue Person Nachname, Vorname, Geburtsdatum und Wohnort. Straße mit 30 Stellen, Hausnummer mit 10 Stellen und PLZ stehen immer da, auch bei einer bekannten Akte, und dürfen leer bleiben. Die PLZ hat vier oder fünf Stellen. Hat die Akte noch keine Straße oder PLZ, werden sie beim Einlesen übernommen. Dazu die Versicherungsnummer mit zehn Stellen, Ordi oder Besuch, Datum und Uhrzeit, und die Texte. **Datei sichern** gibt eine Datei. In der Praxis `P`, dann **Besuche einlesen**. Die Nummer der Akte entsteht erst hier. Ist dieselbe Person schon da, entsteht keine zweite Akte.

## Abrechnung

`AB` öffnet die Abrechnung des Patienten. **Rechnung drucken** erzeugt die Rechnung. **Mahnung** und **Bezahlt** setzen den Stand. Eine Rechnung bleibt in der Liste, auch wenn sie bezahlt ist. Ein Klick öffnet sie wieder. **Drucken** merkt sich das Datum beim ersten Mal. Ein weiterer Druck behält dieses Datum. Auf dem Papier, DIN A4, stehen oben der Rechnungskopf, dann ein kurzer Text, der Behandlungszeitraum, zu jeder Leistung der Tag und die Bezeichnung, die Summe und die Bankverbindung. Solange man den Kopf nicht ändert, stehen dort Name, Arztnummer, Adresse und Telefon. Den Kopf und den Text darüber ändert man unter Einstellungen bei **Vorlagen**. Das Adressfeld beginnt 45 mm unter der Oberkante, für einen Fensterumschlag. Mehr als etwa fünf Kopfzeilen schneidet der Umschlag ab. Im Druckdialog Rand auf keine stellen, die Kopfzeile des Browsers aus und den Maßstab auf 100. Die Kürzel stehen dort nicht. Unter der Rechnung lassen sich Datum und Faktor ändern und Positionen herausnehmen oder hinzufügen. Das Druckdatum bleibt. Bei den offenen Positionen ändert **Speichern** den Tag der Leistung.

`ZI` öffnet den Gebührenkatalog. Oben stehen das Behandlungsdatum und der Faktor. Ein Klick setzt die Zeile auf dieses Datum. `ZI KÜRZEL` setzt diese Gebühr auf heute mit dem Standardfaktor. `ZI KÜRZEL 2,3` setzt den Faktor. `ZI KÜRZEL 2,3 13.11.2026` setzt Faktor und Tag. Das Komma ist das Dezimalkomma. Ist kein Standardfaktor eingetragen, gilt Faktor 1.

Der Betrag im Katalog ist der einfache Satz. Den Faktor setzt man im Feld oben, bevor man die Zeile an den Patienten gibt. Der berechnete Betrag wird auf der Position festgehalten. Eine spätere Änderung im Katalog schreibt gebuchte Zeilen nicht um.

Eine neue Gebühr legt man unter Einstellungen an, bei **Gebühren**. Es ist kein amtliches Gebührenverzeichnis hinterlegt. Die Zeilen sind die eigenen.

## Einstellungen

**Einstellungen** in der Leiste, oder `PX`, öffnet die Einstellungen. Dafür muss keine Akte offen sein.

**Praxis** trägt Titel, Fach, Name, Arztnummer, Adresse, Telefon, IBAN, BIC und die Unterschrift. Eine leere IBAN lässt die Bankverbindung auf der Rechnung weg.

**Adressen** führt Ärzte, Versicherungen und andere Empfänger für Briefe. Oben suchen, ein Klick auf eine Zeile holt sie in das Formular. Neu: Art, Name, dann **Aufnehmen**. Art ist Arzt, Versicherung oder Sonstige. Die Anrede ist die erste Zeile im Fenster, zum Beispiel Herrn oder Firma. Leer beginnt das Fenster mit dem Namen. Der Zusatz ist eine weitere Zeile, etwa Fach oder Abteilung. Dazu Straße, PLZ und Ort. Die PLZ hat vier oder fünf Stellen und darf leer bleiben. Telefon und Notiz stehen nur in der Liste, nicht auf dem Brief. **Speichern** schreibt eine geöffnete Zeile zurück. **Leeren** leert das Formular. **Entfernen** löscht die Adresse. Briefe, die schon geschrieben sind, bleiben in der Akte.

**Bausteine** führt die Textbausteine. Rubrik, Kürzel und Text, dann **Aufnehmen**. Die Bedienung steht oben bei Textbausteine.

**Gebühren** führt die eigenen Gebührenziffern. Oben steht der Standardfaktor. Leer bedeutet 1. Er gilt, wenn beim Buchen kein anderer Faktor angegeben ist. Kürzel, Einfachsatz und Bezeichnung, dann **In den Katalog**. Eine vorhandene Zeile ändert man dort und drückt **Speichern**. **Entfernen** nimmt sie aus dem Katalog. Bereits gebuchte Positionen bleiben so stehen. `ZI` setzt eine vorhandene Gebühr an den Patienten.

**Vorlagen** zeigt die Briefvorlagen. **Öffnen** öffnet die Datei in LibreOffice. Eine Änderung gilt für den nächsten Brief. Bei **Rechnungen** steht der Text über den Positionen. `{Anrede}` folgt dem Geschlecht: weiblich wird zu „Sehr geehrte Frau …“, männlich zu „Sehr geehrter Herr …“, sonst „Guten Tag“. `{Nachname}` und `{Vorname}` sind die des Rechnungsempfängers. Leer speichern stellt den vorgegebenen Text wieder her. **Rechnungskopf** und **Rezeptkopf** sind die Zeilen oben auf dem Papier. Platzhalter sind `{{ARZT}}`, `{{FACH}}`, `{{ARZTNUMMER}}`, `{{ADRESSE}}`, `{{TELEFON}}`, `{{TITEL}}`, `{{VORNAME}}`, `{{NAME}}` und `{{DATUM}}`. Eine leere Zeile fällt weg. Leer speichern stellt den vorgegebenen Kopf wieder her. Auf der Rechnung haben etwa fünf Zeilen Platz, darüber schneidet der Fensterumschlag sie ab. Positionen, Summe, Gruß, Arzneimittel, Unterschrift und Stempel bleiben. Der Stempel kommt aus den Praxisdaten. Jede Datei mit der Endung odt im Ordner vorlagen ist eine Briefvorlage. Eine Überweisung ist eine solche Datei, zum Beispiel Überweisung.odt. **Öffnen** lädt sie in LibreOffice auf diesem Rechner. Eine gespeicherte Änderung gilt für den nächsten Brief.

## Stammdaten

`ST` öffnet die Stammdaten der geöffneten Person. Das Geburtsdatum tippt man als `tt.mm.jjjj`. Das Geschlecht ist weiblich, männlich, divers oder keine Angabe. Weiblich und männlich bestimmen die Anrede auf der Rechnung.

Eine verwandte Person trägt man bei der Art der Beziehung ein, zum Beispiel Halterin oder Mutter. Legt man dabei eine neue Person an, bleibt die bisherige Akte offen.

Der Rechnungsempfänger kann eine andere Person sein. Leer lassen heißt, der Patient erhält die Rechnung selbst.

Die Angaben der Praxis, einschließlich der Unterschrift auf Briefen und Rezepten, stehen unter Einstellungen bei **Praxis**.

## Weiterer Rechner

Die Akte bleibt auf einem Rechner. Jeder Arbeitsplatz merkt sich, wo er den Server findet:

`./praxis ziel` zeigt die Adresse. Leer heißt dieser Rechner, `http://127.0.0.1:8765`.

`./praxis ziel http://192.168.1.20:8765` merkt sich einen anderen Server. Die Angabe liegt auf diesem Arbeitsplatz, nicht in der Akte.

`./praxis fenster` öffnet die Praxis und startet dazu `praxis lokal`. Briefe, Vorlagen und Dateien gehen auf diesem Rechner auf. Rechnung, Rezept und Einnahmeliste drucken über den Browser, ebenfalls hier.

Andere Rechner erreichen den Server erst, wenn er mit `PRAXIS_BIND=0.0.0.0` und `PRAXIS_ALLOW_REMOTE=1` gestartet wird. Eine Anmeldung gibt es dafür noch nicht. Nur ein Netz, dem die Praxis vertraut.

`./praxis paket` packt das Programm ohne Akte, Praxisdaten, Briefe, Dateien, Sicherungen und die ungarische Übersetzung. Auf dem neuen Rechner richtet `./install.sh` Ruby, LibreOffice, Poppler, Tesseract mit Deutsch und Ungarisch und die übrigen Programme ein. `./install.sh --mit-ungarisch` holt zusätzlich die Übersetzung. Die Schritte stehen in `INSTALL.txt`.

## Nach einer Änderung am Programm

Eine Änderung an der Seite gilt nach dem Neuladen. Eine Änderung am Server gilt erst nach `./praxis stop` und einem neuen `./praxis start`.
