# Praxis

Praxisverwaltungssystem für einen einzelnen Rechner, prinzipiell netzwerkfähig, Client/Server, HTML-basierte Maskenverwaltung. Im Browser führt man Kartei, Briefe, Privatrezepte, Rechnungen, Labor, Termine und das Wartezimmer. Alles liegt in einer SQLite-Datei auf dem zentralen Rechner. Für Menschen, Hunde, Pferde und andere Tiere. Beziehungen werden abgebildet. Für Linux und Mac. Amtliche Gebühren- und Arzneimittelverzeichnisse liegen nicht bei.

Wer das Programm zum ersten Mal startet, bekommt eine leere Akte. Praxisangaben, Gebühren und Arzneimittel trägt man selbst ein. Die Klassentitel der ICD-10-GM kann man vom BfArM herunterladen und einbinden, wie unten beschrieben.

Die tägliche Bedienung steht in `HANDBUCH.md`, der Aufbau in `DOKUMENTATION.md`, das Aufsetzen auf einem weiteren Rechner in `INSTALL.txt`. Die Nutzung steht in `LICENSE`. Es ist die MIT-Lizenz.

## Arzneimittel

Eine amtliche Arzneimittelliste wird nicht mitgeliefert. `M` sucht in den Arzneimitteln, die in dieser Praxis angelegt sind.

Zum Nachschlagen gibt es den öffentlichen Teil von AMIce, die Arzneimitteldatenbank des Bundes. BfArM, Paul-Ehrlich-Institut und BVL pflegen sie. Seit dem 13. Februar 2025 ist dieser öffentliche Teil kostenlos. Erreichbar ist er über PharmNet.Bund, das Arzneimittel-Informationssystem. Darin stehen die in Deutschland verkehrsfähigen Fertigarzneimittel und auch solche, deren Zulassung erloschen ist: Handelsname, Zulassungsnummer, Verkehrsfähigkeit, Darreichungsform, Packungsgrößen, Zusammensetzung, Anwendungsgebiete, ATC-Code, Fach- und Gebrauchsinformation. Die Pflege läuft werktäglich. Es ist eine Recherche. Eine Datei zum Herunterladen und Einlegen gibt es dort nicht.

Einbauen in dieses Programm darf man nur lizenzierte Rohdaten. Üblich sind:

- MMI Pharmindex Rohdaten von Vidal MMI, für die eigene Praxissoftware, mit Aktualisierung am 1. und am 15. des Monats. Pharmindex Plus ist ein eigenes Programm und kein Datenbestand für diese Akte.
- ABDA-Artikelstamm von ABDATA. Je Pharmazentralnummer stehen dort Preis, Abgabestatus und Erstattungsregeln. Die Pharmazentralnummer vergibt die IFA. Auch dieser Bestand kommt alle 14 Tage. Wechselwirkungen und Wirkstoffdossiers sind ein eigenes Modul der ABDA-Datenbank.

Beides setzt einen Lizenzvertrag voraus. Die Daten werden hier nicht kopiert und nicht aus der Recherche übernommen. Eine Einbindung lohnt sich erst, wenn der Anbieter die Rohdaten in einem festen Format liefert.

## Diagnosen

Der Katalog sind die Klassentitel der ICD-10-GM 2026, herausgegeben vom BfArM, Stand 12.09.2025. Es ist nicht die ganze Systematik mit Einschlüssen und Ausschlüssen, und es ist nicht das alphabetische Verzeichnis. Eine deutsche ICD-11 zum Herunterladen gibt es dafür nicht. Die amtlichen Titel bleiben unverändert. Eine eigene Zeile mit demselben Kode gilt vor der Katalogzeile.

Die Datei ist nicht im Programmpaket. Mit dem Herunterladen kommt ein Nutzungsvertrag mit dem BfArM zustande. Die Bedingungen stehen vor dem Download auf der Seite und danach in der Datei `downloadbedingungen-2025.pdf` im Zip. Das ganze Verzeichnis wird nicht weitergegeben.

Holen:

1. Seite des BfArM: Kodiersysteme, Services, Downloads. Direkt: <https://www.bfarm.de/DE/Kodiersysteme/Services/Downloads/_node.html>
2. Unter ICD-10-GM Version 2026 die Zeile **ICD-10-GM 2026 Metadaten TXT (CSV)**, Stand 12.09.2025. Die Datei heißt `icd10gm2026syst-meta.zip`. Die PDF-Referenzfassung, die ClaML-Fassung und das Alphabet liest das Programm nicht.

Einbinden, im Ordner `praxis`:

```bash
mkdir -p import/icd/meta
unzip icd10gm2026syst-meta.zip -d import/icd/meta
./praxis stop
./praxis start
```

Das Programm liest nur diese eine Datei:

`import/icd/meta/Klassifikationsdateien/icd10gm2026syst_kodes.txt`

Beim Start übernimmt es die endständigen Klassentitel, wenn der Katalog noch fehlt oder nicht zur Version 2026 gehört. Eigene Diagnosen bleiben. Die Katalogzeilen werden dabei ersetzt. Fehlt die Datei, läuft die Praxis weiter, und `DK` findet nur die eigenen Zeilen. Eine spätere Jahresversion liegt unter einem anderen Dateinamen. Die liest dieses Programm erst, wenn der Pfad dafür eingetragen ist.

## Gebühren

Die Gebühren sind die eigenen Zeilen. Ein amtliches Gebührenverzeichnis liegt nicht bei.
