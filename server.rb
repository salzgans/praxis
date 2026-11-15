# coding: utf-8
# Local practice chart for one machine. Ruby, WEBrick and SQLite. There is no login.
# The server binds to 127.0.0.1 unless PRAXIS_BIND is set, and a non-loopback
# address is refused unless PRAXIS_ALLOW_REMOTE=1.
# Money is cents. A fee factor is thousandths, so 2300 is 2.3. Dates are ISO
# in the database and dd.mm.yyyy on screen.
# SPECIES is the closed list mensch, hund, pferd, tier. They share one chart.
# TEXT_KINDS is the closed list of text rows. RESERVED_KUERZEL cannot be replaced by an own shortcut.
# A text block (baustein) belongs to one rubric. It is not an Info shortcut in kuerzel/eigene.json.
# LIMITS caps the length of person fields.
$stdout.sync = true
require "webrick"
require "sqlite3"
require "json"
require "csv"
require "fileutils"
require "date"
require "time"
require "open3"
require "tmpdir"
require "timeout"
require "securerandom"
require_relative "labor_katalog"

APP = File.expand_path(__dir__)
ROOT = File.expand_path(ENV["PRAXIS_ROOT"] || APP)
PUBLIC = File.join(APP, "public")
DATA = File.join(ROOT, "data")
DATEIEN = File.join(ROOT, "dateien")
KUERZEL = File.join(ROOT, "kuerzel")
BRIEFE = File.join(ROOT, "briefe")
VORLAGEN = File.join(APP, "vorlagen")
DB_PATH = File.expand_path(ENV["PRAXIS_DB"] || File.join(DATA, "praxis.db"))
PORT = Integer(ENV["PRAXIS_PORT"] || 8765)
BIND = (ENV["PRAXIS_BIND"] || "127.0.0.1").freeze
SPECIES = %w[mensch hund pferd tier].freeze
TEXT_KINDS = {
  "A" => "Anamnese",
  "B" => "Befund",
  "D" => "Diagnose",
  "DD" => "Dauerdiagnose",
  "CAVE" => "CAVE",
  "PR" => "Procedere",
  "I" => "Info",
  "L" => "Labor"
}.freeze
RESERVED_KUERZEL = %w[A B D DD DK CAVE PR I L LB DA AB M MP RP ST PX P NEU ZI BRIEFE TER WZ].freeze
LIMITS = {
  "nachname" => 30, "vorname" => 30, "ausweis" => 20, "plz" => 12,
  "land" => 60, "geburtsort" => 80, "wohnort" => 80, "strasse" => 120,
  "mutter" => 80, "krankenkasse" => 80, "versicherung" => 40
}.freeze
# Address-book kinds. These rows are not person charts and never receive a chart number.
ADRESS_ART = {
  "arzt" => "Arzt",
  "versicherung" => "Versicherung",
  "sonst" => "Sonstige"
}.freeze

# Request handler. One instance owns the database connection.
class Praxis

  # Opens praxis.db, enables foreign keys and the WAL journal, then migrates.
  def initialize
    FileUtils.mkdir_p([DATA, DATEIEN, BRIEFE, VORLAGEN, KUERZEL, File.join(ROOT, "import"), File.join(ROOT, "parameter")])
    @mutex = Mutex.new
    @db = SQLite3::Database.new(DB_PATH)
    @db.results_as_hash = true
    @db.busy_timeout = 5000
    @db.execute("PRAGMA foreign_keys = ON")
    @db.execute("PRAGMA journal_mode = WAL")
    schema
    migrate
    ensure_bausteine
    ensure_diagnosen
    ensure_templates
    refresh_stock_templates
  end

  # Fixed routes, then dispatch. Pages and scripts are read from public/ on every request.
  # JSON errors stay generic. The exception text is logged, not sent to the browser.
  def handle(req, res)
    path = req.path
    verb = req.request_method
    unless path.start_with?("/api")
      return if serve_static(path, res)
    end
    @req = req
    case [verb, path]
    when ["GET", "/api/health"] then send_json(res, { "ok" => true })
    when ["GET", "/api/state"] then send_json(res, state)
    when ["GET", "/api/patients"] then send_json(res, search_patients(req.query["q"]))
    when ["POST", "/api/patients"]
      data = body_json(req)
      remember = !(data.key?("remember") && (data["remember"] == false || data["remember"] == 0))
      send_json(res, create_patient(data, remember))
    when ["GET", "/api/practice"] then send_json(res, practice_hash)
    when ["PUT", "/api/practice/faktor"] then send_json(res, save_standard_faktor(body_json(req)))
    when ["PUT", "/api/practice/rechnung"] then send_json(res, save_invoice_text(body_json(req)))
    when ["PUT", "/api/practice/rechnungskopf"] then send_json(res, save_head_text("rechnungskopf", body_json(req)))
    when ["PUT", "/api/practice/rezeptkopf"] then send_json(res, save_head_text("rezeptkopf", body_json(req)))
    when ["PUT", "/api/practice"] then send_json(res, save_practice(body_json(req)))
    when ["POST", "/api/practice/signature"] then send_json(res, save_signature(req))
    when ["GET", "/api/practice/signature"] then send_signature(res)
    when ["GET", "/api/catalog"] then send_json(res, search_catalog(req.query["q"]))
    when ["GET", "/api/medicines"] then send_json(res, search_medicines(req.query["q"]))
    when ["GET", "/api/templates"] then send_json(res, templates)
    when ["GET", "/api/adressen"] then send_json(res, list_adressen(req.query["q"]))
    when ["GET", "/api/bausteine"] then send_json(res, list_bausteine(req.query["q"]))
    else
      dispatch(verb, path, req, res)
    end
  rescue JSON::ParserError
    send_json(res, { "error" => "Ungültige Eingabe" }, 400)
  rescue ArgumentError => e
    send_json(res, { "error" => e.message }, 400)
  rescue StandardError => e
    warn "fehler #{e.class}: #{e.message}"
    send_json(res, { "error" => "Nicht gespeichert" }, 500)
  end

  private

  # Routes that carry an id. WEBrick fills req.query for GET and HEAD only.
  # A DELETE query stays in query_string and is parsed here, then forced to UTF-8 before SQLite.
  def dispatch(verb, path, req, res)
    id = proc { |n| Integer(n) }
    case verb
    when "GET"
      case path
      when %r{\A/api/patients/(\d+)\z} then send_json(res, person_full(id[$1]))
      when %r{\A/api/patients/(\d+)/billing\z} then send_json(res, billing(id[$1]))
      when %r{\A/api/patients/(\d+)/plan\z} then send_json(res, plan_for(id[$1]))
      when %r{\A/api/patients/(\d+)/files\z} then send_json(res, files_for(id[$1]))
      when %r{\A/api/patients/(\d+)/labor\z} then send_json(res, labor_sheet(id[$1]))
      when "/api/labor/parameter" then send_json(res, katalog.public_data)
      when "/api/kuerzel" then send_json(res, { "kuerzel" => read_kuerzel })
      when "/api/diagnosen" then send_json(res, search_diagnosen(req.query["q"]))
      when "/api/termine" then send_json(res, termine_between(req.query["von"], req.query["bis"]))
      when "/api/wartezimmer" then send_json(res, warte_list)
      when "/api/wartezimmer/angebot" then send_json(res, warte_angebot(req.query["patient_id"], req.query["dauer"]))
      when %r{\A/api/invoices/(\d+)\z} then send_json(res, invoice_full(id[$1]))
      when %r{\A/api/prescriptions/(\d+)\z} then send_json(res, prescription_full(id[$1]))
      when %r{\A/api/files/(\d+)\z} then send_json(res, file_meta(id[$1]))
      when %r{\A/api/files/(\d+)/raw\z} then send_file_raw(res, id[$1])
      when %r{\A/api/letters/(\d+)/datei\z} then send_letter_file(res, id[$1])
      when %r{\A/api/templates/([^/]+)/datei\z} then send_template_file(res, $1)
      else send_json(res, { "error" => "Nicht gefunden" }, 404)
      end
    when "POST"
      data = nil
      case path
      when %r{\A/api/patients/(\d+)/open\z} then send_json(res, open_patient(id[$1]))
      when %r{\A/api/patients/(\d+)/relations\z}
        send_json(res, add_relation(id[$1], body_json(req)))
      when %r{\A/api/patients/(\d+)/recipient\z}
        send_json(res, set_recipient(id[$1], body_json(req)))
      when %r{\A/api/patients/(\d+)/entries\z}
        send_json(res, add_text(id[$1], body_json(req)))
      when %r{\A/api/patients/(\d+)/positions\z}
        send_json(res, add_position(id[$1], body_json(req)))
      when %r{\A/api/patients/(\d+)/invoices\z}
        send_json(res, create_invoice(id[$1]))
      when %r{\A/api/invoices/(\d+)/positions/(\d+)/loesen\z}
        send_json(res, detach_invoice_position(id[$1], id[$2]))
      when %r{\A/api/invoices/(\d+)/positionen\z}
        send_json(res, add_invoice_position(id[$1], body_json(req)))
      when %r{\A/api/invoices/(\d+)/druck\z}
        send_json(res, print_invoice(id[$1]))
      when %r{\A/api/invoices/(\d+)/mahnung\z}
        send_json(res, mark_invoice(id[$1], "mahnung"))
      when %r{\A/api/invoices/(\d+)/bezahlt\z}
        send_json(res, mark_invoice(id[$1], "bezahlt"))
      when %r{\A/api/patients/(\d+)/plan\z}
        send_json(res, add_plan(id[$1], body_json(req)))
      when %r{\A/api/plan/(\d+)/stop\z}
        send_json(res, stop_plan(id[$1], body_json(req)))
      when %r{\A/api/patients/(\d+)/prescriptions\z}
        send_json(res, add_prescription(id[$1], body_json(req)))
      when %r{\A/api/patients/(\d+)/files\z}
        send_json(res, add_upload(id[$1], req))
      when %r{\A/api/patients/(\d+)/labor/lesen\z}
        send_json(res, read_labor_file(id[$1], body_json(req)))
      when %r{\A/api/patients/(\d+)/labor\z}
        send_json(res, add_labor_values(id[$1], body_json(req)))
      when %r{\A/api/files/(\d+)/open\z}
        send_json(res, open_stored_file(id[$1]))
      when %r{\A/api/files/(\d+)/deutsch\z}
        send_json(res, translate_file_de(id[$1]))
      when "/api/labor/parameter"
        send_json(res, save_labor_parameter(body_json(req)))
      when "/api/catalog"
        send_json(res, add_catalog(body_json(req)))
      when "/api/adressen"
        send_json(res, add_adresse(body_json(req)))
      when "/api/bausteine"
        send_json(res, add_baustein(body_json(req)))
      when "/api/templates/open"
        send_json(res, open_template(body_json(req)))
      when "/api/kuerzel"
        send_json(res, save_kuerzel(body_json(req)))
      when "/api/diagnosen"
        send_json(res, save_diagnose(body_json(req)))
      when "/api/ressourcen"
        send_json(res, add_ressource(body_json(req)))
      when "/api/termine/raster"
        send_json(res, set_termin_raster(body_json(req)))
      when "/api/termine"
        send_json(res, add_termin(body_json(req)))
      when "/api/wartezimmer"
        send_json(res, arrive(body_json(req)))
      when %r{\A/api/patients/(\d+)/diagnosen\z}
        send_json(res, add_diagnose(id[$1], body_json(req)))
      when %r{\A/api/patients/(\d+)/letters\z}
        send_json(res, add_letter(id[$1], body_json(req)))
      when %r{\A/api/letters/(\d+)/open\z}
        send_json(res, open_letter(id[$1]))
      when "/api/besuche"
        send_json(res, import_besuche(body_json(req)))
      else send_json(res, { "error" => "Nicht gefunden" }, 404)
      end
    when "PATCH"
      case path
      when %r{\A/api/patients/(\d+)\z} then send_json(res, patch_person(id[$1], body_json(req)))
      when %r{\A/api/entries/(\d+)\z} then send_json(res, patch_entry(id[$1], body_json(req)))
      when %r{\A/api/plan/(\d+)\z} then send_json(res, patch_plan(id[$1], body_json(req)))
      when %r{\A/api/files/(\d+)\z} then send_json(res, patch_file(id[$1], body_json(req)))
      when %r{\A/api/ressourcen/(\d+)\z} then send_json(res, patch_ressource(id[$1], body_json(req)))
      when %r{\A/api/wartezimmer/(\d+)\z} then send_json(res, move_warte(id[$1], body_json(req)))
      when "/api/catalog" then send_json(res, patch_catalog(body_json(req)))
      when %r{\A/api/adressen/(\d+)\z} then send_json(res, patch_adresse(id[$1], body_json(req)))
      when %r{\A/api/bausteine/(\d+)\z} then send_json(res, patch_baustein(id[$1], body_json(req)))
      when %r{\A/api/patients/(\d+)/positions/(\d+)\z}
        send_json(res, patch_open_position(id[$1], id[$2], body_json(req)))
      when %r{\A/api/invoices/(\d+)/positions/(\d+)\z}
        send_json(res, patch_invoice_position(id[$1], id[$2], body_json(req)))
      else send_json(res, { "error" => "Nicht gefunden" }, 404)
      end
    when "DELETE"
      case path
      when %r{\A/api/patients/(\d+)\z} then send_json(res, delete_patient(id[$1]))
      when %r{\A/api/relations/(\d+)\z} then send_json(res, delete_relation(id[$1]))
      when %r{\A/api/kuerzel/([A-Za-z]{1,8})\z} then send_json(res, delete_kuerzel($1))
      when "/api/diagnosen"
        code = WEBrick::HTTPUtils.parse_query(req.query_string.to_s)["code"]
        send_json(res, delete_diagnose(code))
      when "/api/catalog"
        code = WEBrick::HTTPUtils.parse_query(req.query_string.to_s)["code"]
        send_json(res, delete_catalog(code))
      when %r{\A/api/termine/(\d+)\z} then send_json(res, delete_termin(id[$1]))
      when %r{\A/api/wartezimmer/(\d+)\z} then send_json(res, leave_warte(id[$1]))
      when %r{\A/api/ressourcen/(\d+)\z} then send_json(res, delete_ressource(id[$1]))
      when %r{\A/api/adressen/(\d+)\z} then send_json(res, delete_adresse(id[$1]))
      when %r{\A/api/bausteine/(\d+)\z} then send_json(res, delete_baustein(id[$1]))
      else send_json(res, { "error" => "Nicht gefunden" }, 404)
      end
    when "PUT"
      case path
      when %r{\A/api/files/(\d+)/raw\z} then send_json(res, replace_stored_file(id[$1], req))
      when %r{\A/api/letters/(\d+)/datei\z} then send_json(res, replace_letter_file(id[$1], req))
      when %r{\A/api/templates/([^/]+)/datei\z} then send_json(res, replace_template_file($1, req))
      else send_json(res, { "error" => "Nicht gefunden" }, 404)
      end
    else
      send_json(res, { "error" => "Nicht gefunden" }, 404)
    end
  end

  # Creates any missing table. Amounts are cents. Dates in the database are ISO, yyyy-mm-dd.
  # entry.ref_id points at the row in the matching table. practice has exactly one row.
  def schema
    @db.execute_batch <<~SQL
      CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY,
        value TEXT
      );
      CREATE TABLE IF NOT EXISTS person (
        id INTEGER PRIMARY KEY,
        nummer INTEGER,
        species TEXT NOT NULL DEFAULT 'mensch',
        nachname TEXT NOT NULL DEFAULT '',
        vorname TEXT NOT NULL DEFAULT '',
        geburtsdatum TEXT,
        geburtsort TEXT,
        wohnort TEXT,
        land TEXT,
        plz TEXT,
        strasse TEXT,
        ausweis TEXT,
        mutter TEXT,
        krankenkasse TEXT,
        versicherung TEXT,
        empfaenger_id INTEGER REFERENCES person(id),
        ist_patient INTEGER NOT NULL DEFAULT 1
      );
      CREATE TABLE IF NOT EXISTS relation (
        id INTEGER PRIMARY KEY,
        from_id INTEGER NOT NULL REFERENCES person(id),
        to_id INTEGER NOT NULL REFERENCES person(id),
        art TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS entry (
        id INTEGER PRIMARY KEY,
        person_id INTEGER NOT NULL REFERENCES person(id),
        tag TEXT NOT NULL,
        kind TEXT NOT NULL,
        label TEXT NOT NULL,
        text TEXT,
        ref_id INTEGER,
        created TEXT,
        quelle TEXT,
        dauer INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS catalog (
        id INTEGER PRIMARY KEY,
        code TEXT NOT NULL UNIQUE,
        text TEXT NOT NULL,
        betrag INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS medicine (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        zulassung TEXT,
        atc TEXT
      );
      CREATE TABLE IF NOT EXISTS position (
        id INTEGER PRIMARY KEY,
        person_id INTEGER NOT NULL REFERENCES person(id),
        tag TEXT NOT NULL,
        code TEXT NOT NULL,
        text TEXT NOT NULL,
        betrag INTEGER NOT NULL,
        invoice_id INTEGER,
        entry_id INTEGER
      );
      CREATE TABLE IF NOT EXISTS invoice (
        id INTEGER PRIMARY KEY,
        person_id INTEGER NOT NULL REFERENCES person(id),
        empfaenger_id INTEGER,
        nummer TEXT NOT NULL,
        datum TEXT NOT NULL,
        mahnung TEXT,
        bezahlt TEXT,
        betrag INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS plan (
        id INTEGER PRIMARY KEY,
        person_id INTEGER NOT NULL REFERENCES person(id),
        typ TEXT NOT NULL,
        medicine_id INTEGER,
        artikel TEXT NOT NULL,
        dosis TEXT,
        start TEXT,
        instruktion TEXT,
        grund TEXT,
        stop TEXT,
        stop_grund TEXT
      );
      CREATE TABLE IF NOT EXISTS prescription (
        id INTEGER PRIMARY KEY,
        person_id INTEGER NOT NULL REFERENCES person(id),
        datum TEXT NOT NULL,
        entry_id INTEGER
      );
      CREATE TABLE IF NOT EXISTS prescription_line (
        id INTEGER PRIMARY KEY,
        prescription_id INTEGER NOT NULL REFERENCES prescription(id),
        artikel TEXT NOT NULL,
        menge TEXT,
        dosis TEXT,
        anweisung TEXT,
        sort INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS file (
        id INTEGER PRIMARY KEY,
        person_id INTEGER NOT NULL REFERENCES person(id),
        name TEXT NOT NULL,
        path TEXT,
        mime TEXT,
        translation TEXT,
        created TEXT,
        entry_id INTEGER,
        quelle TEXT
      );
      CREATE TABLE IF NOT EXISTS letter (
        id INTEGER PRIMARY KEY,
        person_id INTEGER NOT NULL REFERENCES person(id),
        vorlage TEXT,
        betreff TEXT,
        body TEXT,
        path TEXT,
        datum TEXT,
        entry_id INTEGER
      );
      CREATE TABLE IF NOT EXISTS practice (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        titel TEXT,
        fach TEXT,
        name TEXT,
        vorname TEXT,
        arztnummer TEXT,
        adresse TEXT,
        telefone TEXT
      );
      CREATE TABLE IF NOT EXISTS labor (
        id INTEGER PRIMARY KEY,
        person_id INTEGER NOT NULL REFERENCES person(id),
        tag TEXT NOT NULL,
        name TEXT NOT NULL DEFAULT '',
        wert TEXT,
        einheit TEXT,
        norm TEXT,
        kuerzel TEXT,
        flag TEXT,
        quelle TEXT NOT NULL UNIQUE
      );
      CREATE INDEX IF NOT EXISTS medicine_name ON medicine(name);
      CREATE INDEX IF NOT EXISTS entry_person ON entry(person_id, tag, id);
      CREATE INDEX IF NOT EXISTS position_person ON position(person_id, invoice_id);
      CREATE INDEX IF NOT EXISTS labor_person ON labor(person_id, tag);
      CREATE TABLE IF NOT EXISTS ressource (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        aktiv INTEGER NOT NULL DEFAULT 1
      );
      CREATE TABLE IF NOT EXISTS ressource_zeit (
        id INTEGER PRIMARY KEY,
        ressource_id INTEGER NOT NULL REFERENCES ressource(id) ON DELETE CASCADE,
        wochentag INTEGER NOT NULL,
        von TEXT NOT NULL,
        bis TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS termin (
        id INTEGER PRIMARY KEY,
        ressource_id INTEGER REFERENCES ressource(id),
        patient_id INTEGER REFERENCES person(id),
        tag TEXT NOT NULL,
        bis_tag TEXT NOT NULL,
        von TEXT,
        bis TEXT,
        ganztaegig INTEGER NOT NULL DEFAULT 0,
        alle INTEGER NOT NULL DEFAULT 0,
        notiz TEXT NOT NULL DEFAULT ''
      );
      CREATE INDEX IF NOT EXISTS termin_span ON termin(tag, bis_tag);
      CREATE TABLE IF NOT EXISTS adresse (
        id INTEGER PRIMARY KEY,
        art TEXT NOT NULL DEFAULT 'sonst',
        anrede TEXT NOT NULL DEFAULT '',
        name TEXT NOT NULL,
        zusatz TEXT NOT NULL DEFAULT '',
        strasse TEXT NOT NULL DEFAULT '',
        plz TEXT NOT NULL DEFAULT '',
        ort TEXT NOT NULL DEFAULT '',
        telefon TEXT NOT NULL DEFAULT '',
        notiz TEXT NOT NULL DEFAULT ''
      );
      CREATE INDEX IF NOT EXISTS adresse_name ON adresse(name);
      CREATE TABLE IF NOT EXISTS baustein (
        id INTEGER PRIMARY KEY,
        kind TEXT NOT NULL,
        kuerzel TEXT NOT NULL,
        text TEXT NOT NULL
      );
      CREATE UNIQUE INDEX IF NOT EXISTS baustein_kind_code ON baustein(kind, kuerzel COLLATE NOCASE);
      CREATE TABLE IF NOT EXISTS wartezimmer (
        id INTEGER PRIMARY KEY,
        patient_id INTEGER NOT NULL UNIQUE REFERENCES person(id),
        termin_id INTEGER REFERENCES termin(id) ON DELETE SET NULL,
        gekommen TEXT NOT NULL,
        reihe INTEGER
      );
    SQL
    @db.execute("INSERT OR IGNORE INTO practice (id) VALUES (1)")
  end

  # Bestehende Datenbanken bekommen die Patientennummer nachträglich.
  # Empfänger ohne eigene Akte behalten NULL. Die Nummer wird nie wiederverwendet.

  # Adds columns to a database created before them.
  # A chart labelled Dauerdiagnose becomes kind DD with dauer 1, so the header can see it.
  # Patient numbers that were still empty are filled once. A freed number is not reused.
  # A person who is only an invoice recipient keeps a null number.
  def migrate
    names = @db.execute("PRAGMA table_info(person)").map { |row| row["name"] }
    @db.execute("ALTER TABLE person ADD COLUMN nummer INTEGER") unless names.include?("nummer")
    @db.execute("ALTER TABLE person ADD COLUMN anrede TEXT") unless names.include?("anrede")
    @db.execute("ALTER TABLE person ADD COLUMN geschlecht TEXT") unless names.include?("geschlecht")
    @db.execute("UPDATE person SET geschlecht = 'w' WHERE anrede = 'Frau' AND (geschlecht IS NULL OR trim(geschlecht) = '')")
    @db.execute("UPDATE person SET geschlecht = 'm' WHERE anrede = 'Herr' AND (geschlecht IS NULL OR trim(geschlecht) = '')")
    missing = @db.execute("SELECT id FROM person WHERE ist_patient = 1 AND nummer IS NULL ORDER BY id")
    unless missing.empty?
      @db.transaction do
        next_n = @db.get_first_value("SELECT COALESCE(MAX(nummer), 0) FROM person").to_i
        missing.each do |row|
          next_n += 1
          @db.execute("UPDATE person SET nummer = ? WHERE id = ? AND nummer IS NULL", [next_n, row["id"]])
        end
      end
    end
    @db.execute("CREATE UNIQUE INDEX IF NOT EXISTS person_nummer ON person(nummer)")
    entry_cols = @db.execute("PRAGMA table_info(entry)").map { |row| row["name"] }
    @db.execute("ALTER TABLE entry ADD COLUMN quelle TEXT") unless entry_cols.include?("quelle")
    @db.execute("ALTER TABLE entry ADD COLUMN dauer INTEGER NOT NULL DEFAULT 0") unless entry_cols.include?("dauer")
    @db.execute("UPDATE entry SET dauer = 1 WHERE kind = 'DD' AND ifnull(dauer, 0) = 0")
    @db.execute("UPDATE entry SET dauer = 1, kind = 'DD' WHERE label = 'Dauerdiagnose' COLLATE NOCASE AND kind != 'DD'")
    @db.execute("CREATE UNIQUE INDEX IF NOT EXISTS entry_quelle ON entry(quelle) WHERE quelle IS NOT NULL")
    file_cols = @db.execute("PRAGMA table_info(file)").map { |row| row["name"] }
    @db.execute("ALTER TABLE file ADD COLUMN quelle TEXT") unless file_cols.include?("quelle")
    @db.execute("CREATE UNIQUE INDEX IF NOT EXISTS file_quelle ON file(quelle) WHERE quelle IS NOT NULL")
    pos_cols = @db.execute("PRAGMA table_info(position)").map { |row| row["name"] }
    @db.execute("ALTER TABLE position ADD COLUMN faktor INTEGER") unless pos_cols.include?("faktor")
    unless pos_cols.include?("basis")
      @db.execute("ALTER TABLE position ADD COLUMN basis INTEGER")
      @db.execute("UPDATE position SET basis = betrag WHERE faktor IS NULL OR faktor = 1000")
      @db.execute(<<~SQL)
        UPDATE position SET basis = (
          SELECT catalog.betrag FROM catalog
          WHERE catalog.code = position.code COLLATE NOCASE
        ) WHERE basis IS NULL
      SQL
      @db.execute("UPDATE position SET basis = betrag WHERE basis IS NULL")
    end
    prac_cols = @db.execute("PRAGMA table_info(practice)").map { |row| row["name"] }
    @db.execute("ALTER TABLE practice ADD COLUMN standardfaktor INTEGER") unless prac_cols.include?("standardfaktor")
    @db.execute("ALTER TABLE practice ADD COLUMN iban TEXT") unless prac_cols.include?("iban")
    @db.execute("ALTER TABLE practice ADD COLUMN bic TEXT") unless prac_cols.include?("bic")
    @db.execute("ALTER TABLE practice ADD COLUMN rechnungstext TEXT") unless prac_cols.include?("rechnungstext")
    @db.execute("ALTER TABLE practice ADD COLUMN rechnungskopf TEXT") unless prac_cols.include?("rechnungskopf")
    @db.execute("ALTER TABLE practice ADD COLUMN rezeptkopf TEXT") unless prac_cols.include?("rezeptkopf")
    inv_cols = @db.execute("PRAGMA table_info(invoice)").map { |row| row["name"] }
    unless inv_cols.include?("gedruckt")
      @db.execute("ALTER TABLE invoice ADD COLUMN gedruckt TEXT")
      @db.execute("UPDATE invoice SET gedruckt = datum WHERE gedruckt IS NULL OR trim(gedruckt) = ''")
    end
    ensure_identity_index
    ensure_warte_reihe
    # letter.adresse_id points at the address book. Null means the letter went to the patient.
    # Deleting an address keeps the letter file and clears the pointer.
    letter_cols = @db.execute("PRAGMA table_info(letter)").map { |row| row["name"] }
    unless letter_cols.include?("adresse_id")
      @db.execute("ALTER TABLE letter ADD COLUMN adresse_id INTEGER REFERENCES adresse(id) ON DELETE SET NULL")
    end
  end

  # reihe is the call order. A database from before the column gets it here.
  # Empty places are filled from the old arrival order, once.
  def ensure_warte_reihe
    cols = @db.execute("PRAGMA table_info(wartezimmer)").map { |row| row["name"] }
    return unless cols.include?("id")
    @db.execute("ALTER TABLE wartezimmer ADD COLUMN reihe INTEGER") unless cols.include?("reihe")
    missing = @db.get_first_value("SELECT COUNT(*) FROM wartezimmer WHERE reihe IS NULL").to_i
    return if missing.zero?
    @db.execute("SELECT id FROM wartezimmer ORDER BY COALESCE(reihe, 1000000), gekommen, id").each_with_index do |row, index|
      @db.execute("UPDATE wartezimmer SET reihe = ? WHERE id = ?", [index + 1, row["id"]])
    end
  end

  # Name, Vorname, Wohnort und Geburtsdatum zusammen nur einmal.
  # Solange zwei vorhandene Akten denselben Schlüssel haben, bleibt der Index aus.

  # One chart per family name, given name, town and birth date.
  # If two charts already share that key, the index is left off instead of failing startup.
  def ensure_identity_index(db = @db)
    db.execute(<<~SQL)
      CREATE UNIQUE INDEX IF NOT EXISTS person_identity ON person (
        nachname COLLATE NOCASE,
        ifnull(vorname, '') COLLATE NOCASE,
        ifnull(wohnort, '') COLLATE NOCASE,
        ifnull(geburtsdatum, '')
      ) WHERE ist_patient = 1
    SQL
  rescue SQLite3::ConstraintException
    nil
  end

  # One SQLite connection. Callers take this mutex before using it.
  def lock
    @mutex.synchronize { yield @db }
  end

  # Small key/value table. last_patient_id and the one-time marks live here.
  def meta_get(key)
    lock { |db| db.get_first_value("SELECT value FROM meta WHERE key = ?", [key]) }
  end

  # Insert or replace one meta value.
  def meta_set(key, value)
    lock do |db|
      db.execute("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [key, value.to_s])
    end
  end

  # ISO date stored on new chart rows. The screen shows dd.mm.yyyy.
  def today
    Date.today.strftime("%Y-%m-%d")
  end

  # Local time stored in created. It is not the chart day.
  def now_stamp
    Time.now.strftime("%Y-%m-%dT%H:%M:%S")
  end

  # ISO in, dd.mm.yyyy out. A value that is not ISO is returned unchanged.
  def show_date(iso)
    return "" if iso.nil? || iso.to_s.empty?
    m = iso.to_s.match(/\A(\d{4})-(\d{2})-(\d{2})/)
    return iso.to_s unless m
    format("%02d.%02d.%04d", m[3].to_i, m[2].to_i, m[1].to_i)
  end

  # Accepts dd.mm.yyyy, yyyy-mm-dd and yyyymmdd. An impossible day is rejected.
  # Returns ISO, or nil when the field was left empty.
  def parse_date(value)
    text = clean(value)
    return nil if text.empty?
    year = month = day = nil
    if (m = text.match(/\A(\d{1,2})\.(\d{1,2})\.(\d{4})\z/))
      day, month, year = m[1].to_i, m[2].to_i, m[3].to_i
    elsif (m = text.match(/\A(\d{4})-(\d{2})-(\d{2})\z/))
      year, month, day = m[1].to_i, m[2].to_i, m[3].to_i
    elsif (m = text.match(/\A(\d{4})(\d{2})(\d{2})\z/))
      year, month, day = m[1].to_i, m[2].to_i, m[3].to_i
    else
      raise ArgumentError, "Datum nicht erkannt"
    end
    begin
      Date.new(year, month, day)
    rescue ArgumentError
      raise ArgumentError, "Datum nicht erkannt"
    end
    format("%04d-%02d-%02d", year, month, day)
  end

  # Drops NUL bytes and surrounding space before a value is stored or compared.
  def clean(value)
    value.to_s.gsub("\0", "").strip
  end

  # clean, then a hard length cap.
  def clip(value, max)
    clean(value)[0, max].to_s
  end

  # Escapes \, % and _ so a search for those characters is literal.
  def like_query(value)
    "%" + clean(value).gsub(/[\\%_]/) { |ch| "\\#{ch}" } + "%"
  end

  # WEBrick may hand the body over as an IO.
  def read_raw(req)
    raw = req.body
    return "" if raw.nil?
    text = raw.respond_to?(:read) ? raw.read.to_s : raw.to_s
    text.dup
  end

  # Forces UTF-8 before JSON.parse. An empty body is an empty object.
  def body_json(req)
    raw = read_raw(req)
    return {} if raw.strip.empty?
    raw.force_encoding(Encoding::UTF_8)
    raw = raw.scrub
    data = JSON.parse(raw)
    raise ArgumentError, "Ungültige Eingabe" unless data.is_a?(Hash)
    data
  end

  # Upload bytes, capped at 25 MiB. The encoding is left binary.
  def raw_body(req)
    body = read_raw(req)
    body.force_encoding(Encoding::ASCII_8BIT)
    raise ArgumentError, "Die Datei ist zu groß" if body.bytesize > 25 * 1024 * 1024
    raise ArgumentError, "Die Datei ist leer" if body.bytesize == 0
    body
  end

  # Every JSON response is Cache-Control: no-store.
  def send_json(res, obj, status = 200)
    res.status = status
    res["Content-Type"] = "application/json; charset=utf-8"
    res["Cache-Control"] = "no-store"
    res.body = JSON.generate(obj)
  end

  # Serves one file from public/ and refuses a path that climbs out of it.
  # no-store, so a reload sees an edited page without a server restart.
  def serve_static(path, res)
    rel = path == "/" ? "index.html" : path.sub(%r{\A/}, "")
    return false if rel.include?("..")
    file = File.expand_path(rel, PUBLIC)
    return false unless file.start_with?(PUBLIC + File::SEPARATOR) && File.file?(file)
    type = {
      ".html" => "text/html; charset=utf-8",
      ".js" => "application/javascript; charset=utf-8",
      ".css" => "text/css; charset=utf-8",
      ".png" => "image/png",
      ".svg" => "image/svg+xml"
    }[File.extname(file)] || "application/octet-stream"
    res.status = 200
    res["Content-Type"] = type
    res["Cache-Control"] = "no-store"
    res.body = File.binread(file)
    true
  end

  # Loads one person or raises. The caller turns that into a 400.
  def person_row(id)
    row = lock { |db| db.get_first_row("SELECT * FROM person WHERE id = ?", [id]) }
    raise ArgumentError, "Person nicht gefunden" unless row
    row
  end

  # Person fields for the browser. The birth date is sent as ISO and as display text.
  def person_hash(row)
    return nil unless row
    {
      "id" => row["id"],
      "nummer" => row["nummer"] && row["nummer"].to_i,
      "species" => row["species"],
      "nachname" => row["nachname"].to_s,
      "vorname" => row["vorname"].to_s,
      "geburtsdatum" => row["geburtsdatum"],
      "geburtsdatum_anzeige" => show_date(row["geburtsdatum"]),
      "geburtsort" => row["geburtsort"].to_s,
      "wohnort" => row["wohnort"].to_s,
      "land" => row["land"].to_s,
      "plz" => row["plz"].to_s,
      "strasse" => row["strasse"].to_s,
      "ausweis" => row["ausweis"].to_s,
      "mutter" => row["mutter"].to_s,
      "krankenkasse" => row["krankenkasse"].to_s,
      "versicherung" => row["versicherung"].to_s,
      "geschlecht" => normalize_geschlecht(row["geschlecht"]),
      "empfaenger_id" => row["empfaenger_id"],
      "ist_patient" => row["ist_patient"]
    }
  end

  # One relationship as seen from the open chart. other_id is the other person.
  def relation_hash(row, other_id)
    {
      "id" => row["id"],
      "art" => row["art"],
      "to_id" => other_id,
      "nummer" => row["nummer"] && row["nummer"].to_i,
      "nachname" => row["nachname"].to_s,
      "vorname" => row["vorname"].to_s,
      "species" => row["species"],
      "geburtsdatum_anzeige" => show_date(row["geburtsdatum"]),
      "wohnort" => row["wohnort"].to_s
    }
  end

  # Both directions. The typed label is kept as it was entered.
  def relations_of(person_id)
    outgoing, incoming = lock do |db|
      out = db.execute(<<~SQL, [person_id])
        SELECT r.id, r.art, r.to_id, p.nummer, p.nachname, p.vorname, p.species, p.geburtsdatum, p.wohnort
        FROM relation r JOIN person p ON p.id = r.to_id
        WHERE r.from_id = ?
        ORDER BY r.id
      SQL
      inc = db.execute(<<~SQL, [person_id])
        SELECT r.id, r.art, r.from_id, p.nummer, p.nachname, p.vorname, p.species, p.geburtsdatum, p.wohnort
        FROM relation r JOIN person p ON p.id = r.from_id
        WHERE r.to_id = ?
        ORDER BY r.id
      SQL
      [out, inc]
    end
    outgoing.map { |row| relation_hash(row, row["to_id"]) } +
      incoming.map { |row| relation_hash(row, row["from_id"]) }
  end

  # Header payload: the person, both directions of relationship, and the invoice recipient.
  def person_full(id)
    row = person_row(id)
    hash = person_hash(row)
    hash["relations"] = relations_of(id)
    if row["empfaenger_id"]
      other = lock { |db| db.get_first_row("SELECT id, nachname, vorname FROM person WHERE id = ?", [row["empfaenger_id"]]) }
      hash["empfaenger"] = other && { "id" => other["id"], "nachname" => other["nachname"].to_s, "vorname" => other["vorname"].to_s }
    else
      hash["empfaenger"] = nil
    end
    hash
  end

  # The chart remembered in last_patient_id, or else the oldest chart.
  # Returns nil when there is no chart. Does not rewrite last_patient_id.
  def current_patient_id
    saved = meta_get("last_patient_id")
    if saved && lock { |db| db.get_first_value("SELECT id FROM person WHERE id = ?", [saved.to_i]) }
      return saved.to_i
    end
    lock { |db| db.get_first_value("SELECT id FROM person WHERE ist_patient = 1 ORDER BY id LIMIT 1") }
  end

  # First payload the page asks for: open chart, its rows, and the practice identity.
  def state
    pid = current_patient_id
    patient = pid ? person_full(pid) : nil
    chart = pid ? chart_for(pid) : []
    { "patient" => patient, "chart" => chart, "practice" => practice_hash }
  end

  # Lab parameter catalog, built once from parameter/*.json.
  def katalog
    @katalog || lock { @katalog ||= LaborKatalog.new(File.join(ROOT, "parameter")) }
  end

  # Grouped spreadsheet for one chart. Empty results are left out.
  def labor_sheet(person_id)
    person_row(person_id)
    rows = lock do |db|
      db.execute(<<~SQL, [person_id])
        SELECT tag, name, wert, einheit, norm, kuerzel, flag
        FROM labor
        WHERE person_id = ? AND wert IS NOT NULL AND trim(wert) <> ''
        ORDER BY tag, id
      SQL
    end
    data = katalog.sheet(rows)
    data["dates"] = data["dates"].map { |tag| { "tag" => tag, "anzeige" => show_date(tag) } }
    data
  end

  # Stores values the user has already confirmed. Each row gets its own quelle,
  # so the same result can be kept twice. A chart line Tabelle is added for that day if none exists.
  def add_labor_values(person_id, data)
    person_row(person_id)
    tag = parse_date(data["tag"])
    lines = data["zeilen"]
    raise ArgumentError, "Keine Werte" unless lines.is_a?(Array) && !lines.empty?
    raise ArgumentError, "Zu viele Zeilen" if lines.length > 80
    saved = 0
    entry = nil
    lock do |db|
      lines.each do |line|
        next unless line.is_a?(Hash)
        name = clip(line["name"], 120)
        wert = clip(line["wert"], 80)
        next if name.empty? || wert.empty?
        db.execute(
          "INSERT INTO labor (person_id, tag, name, wert, einheit, norm, kuerzel, flag, quelle) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
          [
            person_id, tag, name, wert,
            clip(line["einheit"], 40), clip(line["norm"], 80), clip(line["kuerzel"], 40),
            clip(line["flag"], 12), "manuell:#{person_id}:#{tag}:#{SecureRandom.hex(8)}"
          ]
        )
        saved += 1
      end
      raise ArgumentError, "Keine Werte" if saved.zero?
      entry = ensure_labor_marker(db, person_id, tag)
    end
    sheet = labor_sheet(person_id)
    sheet["gespeichert"] = saved
    sheet["eintrag"] = entry if entry
    sheet
  end

  # One chart row of kind LB per person and day. The quelle makes a second insert a no-op.
  def ensure_labor_marker(db, person_id, tag)
    quelle = "labor:tag:#{person_id}:#{tag}"
    return nil if db.get_first_value("SELECT id FROM entry WHERE quelle = ?", [quelle])
    return nil if db.get_first_value("SELECT id FROM entry WHERE person_id = ? AND tag = ? AND kind = 'LB'", [person_id, tag])
    db.execute(
      "INSERT INTO entry (person_id, tag, kind, label, text, ref_id, created, quelle) VALUES (?, ?, 'LB', 'Labor', 'Tabelle', NULL, ?, ?)",
      [person_id, tag, now_stamp, quelle]
    )
    entry_hash(db.get_first_row("SELECT * FROM entry WHERE id = ?", [db.last_insert_row_id]))
  end

  # Reads a file that belongs to this chart and proposes rows. Nothing is stored yet.
  def read_labor_file(person_id, data)
    person_row(person_id)
    begin
      fid = Integer(data["file_id"].to_s)
    rescue ArgumentError, TypeError
      raise ArgumentError, "Datei fehlt"
    end
    row, path = stored_file(fid)
    raise ArgumentError, "Datei gehört nicht zu dieser Akte" unless row["person_id"].to_i == person_id
    text = LaborKatalog.extract(path, row["mime"], ocr_home: File.join(APP, "ocr"))
    proposal = katalog.propose(text)
    proposal["tag_anzeige"] = proposal["tag"] ? show_date(proposal["tag"]) : ""
    proposal["datei_id"] = fid
    if proposal["zeilen"].empty?
      proposal["auszug"] = text.to_s.gsub(/\s+/, " ").strip[0, 800]
      proposal["hinweis"] = "Kein Laborwert erkannt. #{proposal["hinweis"]}"
    end
    proposal
  rescue ArgumentError
    raise
  rescue TypeError
    raise ArgumentError, "Datei fehlt"
  end

  # Writes a practice mapping. parameter/eigene.json wins over the shipped file on the same id.
  def save_labor_parameter(data)
    katalog.save_parameter(
      "name" => clip(data["name"], 80),
      "gruppe" => clip(data["gruppe"], 40),
      "einheit" => clip(data["einheit"], 40),
      "alias" => Array(data["alias"]).map { |item| clip(item, 80) },
      "ziel_id" => clip(data["ziel_id"], 40),
      "von" => clip(data["von"], 40),
      "faktor" => data["faktor"],
      "offset" => data["offset"]
    )
    katalog.public_data
  end

  # Chart rows in date order, then insertion order.
  def chart_for(person_id)
    rows = lock do |db|
      db.execute("SELECT * FROM entry WHERE person_id = ? ORDER BY tag, id", [person_id])
    end
    rows.map { |row| entry_hash(row) }
  end

  # One chart row for the browser. dauer 1 marks a Dauerdiagnose.
  def entry_hash(row)
    {
      "id" => row["id"],
      "tag" => row["tag"],
      "tag_anzeige" => show_date(row["tag"]),
      "kind" => row["kind"],
      "label" => row["label"],
      "text" => row["text"].to_s,
      "ref_id" => row["ref_id"],
      "dauer" => row["dauer"].to_i
    }
  end

  # Inserts a chart row and does not change which chart is open. The day defaults to today.
  def insert_entry(db, person_id, kind, label, text, ref_id = nil, tag = nil, dauer = 0)
    tag = today if tag.nil? || tag.empty?
    db.execute(
      "INSERT INTO entry (person_id, tag, kind, label, text, ref_id, created, dauer) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [person_id, tag, kind, label, text.to_s, ref_id, now_stamp, dauer.to_i]
    )
    db.last_insert_row_id
  end

  # Clips a person field. Unknown keys are ignored by the caller.
  def field_value(data, key)
    return nil unless data.key?(key)
    max = LIMITS[key] || 500
    clip(data[key], max)
  end

  # On create, every field is applied. On update, only keys present in the body change.
  # An unknown species becomes mensch. The birth date is parsed to ISO.
  def apply_person_fields(data, creating)
    fields = {}
    if creating || data.key?("species")
      species = clean(data["species"]).downcase
      species = "mensch" unless SPECIES.include?(species)
      fields["species"] = species
    end
    LIMITS.each_key do |key|
      next unless creating || data.key?(key)
      fields[key] = field_value(data, key).to_s
    end
    if creating || data.key?("geburtsdatum")
      fields["geburtsdatum"] = parse_date(data["geburtsdatum"])
    end
    if data.key?("nachname") || creating
      name = fields["nachname"].to_s
      raise ArgumentError, "Nachname fehlt" if name.empty?
    end
    if creating || data.key?("geschlecht") || data.key?("anrede")
      source = data.key?("geschlecht") ? data["geschlecht"] : data["anrede"]
      fields["geschlecht"] = normalize_geschlecht(source)
    end
    fields
  end

  # w, m or d. Frau and Herr from the earlier field count as w and m. Anything else is unset.
  def normalize_geschlecht(value)
    raw = clean(value).downcase
    return "w" if %w[w weiblich frau f].include?(raw)
    return "m" if %w[m männlich maennlich herr h].include?(raw)
    return "d" if %w[d divers].include?(raw)
    ""
  end

  # Next chart number is one above the highest number ever stored. Freed numbers stay free.
  # remember false does not change last_patient_id, so a new relative or recipient leaves the open chart in place.
  # ist_patient 0 is a person without a chart number.
  def create_patient(data, remember = true)
    fields = apply_person_fields(data, true)
    fields["ist_patient"] = data["ist_patient"] == 0 || data["ist_patient"] == false ? 0 : 1
    id = nil
    lock do |db|
      if fields["ist_patient"] == 1
        taken = identity_owner(db, fields["nachname"], fields["vorname"], fields["wohnort"], fields["geburtsdatum"], nil)
        raise ArgumentError, identity_message if taken
        fields["nummer"] = db.get_first_value("SELECT COALESCE(MAX(nummer), 0) FROM person").to_i + 1
      end
      cols = fields.keys
      db.execute(
        "INSERT INTO person (#{cols.join(", ")}) VALUES (#{cols.map { "?" }.join(", ")})",
        cols.map { |key| fields[key] }
      )
      id = db.last_insert_row_id
    end
    meta_set("last_patient_id", id) if remember && fields["ist_patient"] == 1
    person_full(id)
  end

  # Refuses a second chart with the same name, town and birth date.
  # An empty empfaenger_id clears the invoice recipient.
  def patch_person(id, data)
    row = person_row(id)
    fields = apply_person_fields(data, false)
    if data.key?("empfaenger_id") && (data["empfaenger_id"].nil? || data["empfaenger_id"].to_s.empty?)
      fields["empfaenger_id"] = nil
    end
    unless fields.empty?
      lock do |db|
        if row["ist_patient"].to_i == 1
          nach, vor, ort, geb = merged_identity(row, fields)
          taken = identity_owner(db, nach, vor, ort, geb, id)
          raise ArgumentError, identity_message if taken
        end
        sets = fields.keys.map { |key| "#{key} = ?" }.join(", ")
        db.execute("UPDATE person SET #{sets} WHERE id = ?", fields.values + [id])
      end
      lock { |inner| ensure_identity_index(inner) }
    end
    person_full(id)
  end

  # Shown when that name, town and birth date already belong to a chart.
  def identity_message
    "Nachname, Vorname, Wohnort und Geburtsdatum gibt es schon."
  end

  # The four identity fields as they would stand after this update.
  def merged_identity(row, fields)
    %w[nachname vorname wohnort geburtsdatum].map do |key|
      fields.key?(key) ? fields[key] : row[key]
    end
  end

  # Finds a chart with the same identity. Names and town are case-insensitive. The birth date is the stored ISO value.
  def identity_owner(db, nach, vor, ort, geb, except_id)
    sql = <<~SQL
      SELECT id FROM person
      WHERE ist_patient = 1
        AND nachname = ? COLLATE NOCASE
        AND ifnull(vorname, '') = ? COLLATE NOCASE
        AND ifnull(wohnort, '') = ? COLLATE NOCASE
        AND ifnull(geburtsdatum, '') = ?
    SQL
    args = [nach.to_s, vor.to_s, ort.to_s, geb.to_s]
    if except_id
      sql += " AND id != ?"
      args << except_id
    end
    sql += " LIMIT 1"
    db.get_first_value(sql, args)
  end

  # Deletes a chart and the rows that belong to it. A person who is only a recipient cannot be deleted here.
  # Files are removed after the commit, and only when the path stays inside dateien/ or briefe/.
  def delete_patient(id)
    row = person_row(id)
    raise ArgumentError, "Diese Person hat keine eigene Akte" if row["ist_patient"].to_i != 1
    paths = []
    lock do |db|
      db.transaction do
        paths = db.execute("SELECT path FROM file WHERE person_id = ?", [id]).map { |item| item["path"] }
        paths += db.execute("SELECT path FROM letter WHERE person_id = ?", [id]).map { |item| item["path"] }
        db.execute("UPDATE person SET empfaenger_id = NULL WHERE empfaenger_id = ?", [id])
        db.execute("UPDATE invoice SET empfaenger_id = NULL WHERE empfaenger_id = ?", [id])
        db.execute("SELECT id FROM prescription WHERE person_id = ?", [id]).each do |prow|
          db.execute("DELETE FROM prescription_line WHERE prescription_id = ?", [prow["id"]])
        end
        db.execute("DELETE FROM prescription WHERE person_id = ?", [id])
        db.execute("DELETE FROM relation WHERE from_id = ? OR to_id = ?", [id, id])
        db.execute("DELETE FROM plan WHERE person_id = ?", [id])
        db.execute("DELETE FROM position WHERE person_id = ?", [id])
        db.execute("DELETE FROM invoice WHERE person_id = ?", [id])
        db.execute("DELETE FROM file WHERE person_id = ?", [id])
        db.execute("DELETE FROM letter WHERE person_id = ?", [id])
        db.execute("DELETE FROM entry WHERE person_id = ?", [id])
        db.execute("DELETE FROM termin WHERE patient_id = ?", [id])
        db.execute("DELETE FROM wartezimmer WHERE patient_id = ?", [id])
        db.execute("DELETE FROM person WHERE id = ?", [id])
        db.execute("DELETE FROM meta WHERE key = 'last_patient_id' AND value = ?", [id.to_s])
      end
    end
    paths.each { |path| remove_stored_file(path) }
    lock { |inner| ensure_identity_index(inner) }
    state
  end

  # Deletes a file only under dateien/ or briefe/.
  def remove_stored_file(path)
    full = path.to_s.empty? ? "" : File.expand_path(path)
    [DATEIEN, BRIEFE].each do |root|
      base = File.expand_path(root) + File::SEPARATOR
      File.delete(full) if full.start_with?(base) && File.file?(full)
    end
  rescue StandardError
    nil
  end

  # Remembers this chart as last_patient_id and returns the full state.
  def open_patient(id)
    person_row(id)
    meta_set("last_patient_id", id)
    state
  end

  # A query that looks like a date is matched exactly. An impossible date is ignored, not an error.
  def search_date(text)
    return nil unless text =~ /\A(\d{1,2}\.\d{1,2}\.\d{4}|\d{4}-\d{2}-\d{2}|\d{8})\z/
    parse_date(text)
  rescue ArgumentError
    nil
  end

  # One row of the patient list. Address and insurance stay off this list.
  def patient_brief(row)
    {
      "id" => row["id"],
      "nummer" => row["nummer"] && row["nummer"].to_i,
      "species" => row["species"],
      "nachname" => row["nachname"].to_s,
      "vorname" => row["vorname"].to_s,
      "geburtsdatum_anzeige" => show_date(row["geburtsdatum"]),
      "geburtsort" => row["geburtsort"].to_s,
      "wohnort" => row["wohnort"].to_s
    }
  end

  # One box matches number, names, birth date, place, street, id card, insurer and species. At most 500 rows.
  def search_patients(query)
    q = clean(query)[0, 80]
    rows = lock do |db|
      if q.empty?
        db.execute(<<~SQL)
          SELECT id, nummer, species, nachname, vorname, geburtsdatum, geburtsort, wohnort
          FROM person WHERE ist_patient = 1
          ORDER BY nummer, id
          LIMIT 500
        SQL
      else
        like = like_query(q)
        nummer = q.match(/\A\d{1,9}\z/) ? q.to_i : nil
        datum = search_date(q)
        db.execute(<<~SQL, [nummer, nummer, datum, datum] + Array.new(19, like))
          SELECT id, nummer, species, nachname, vorname, geburtsdatum, geburtsort, wohnort
          FROM person
          WHERE ist_patient = 1 AND (
            (? IS NOT NULL AND nummer = ?)
            OR (? IS NOT NULL AND geburtsdatum = ?)
            OR nachname LIKE ? ESCAPE '\\'
            OR vorname LIKE ? ESCAPE '\\'
            OR (nachname || ' ' || ifnull(vorname, '')) LIKE ? ESCAPE '\\'
            OR (ifnull(vorname, '') || ' ' || nachname) LIKE ? ESCAPE '\\'
            OR (nachname || ', ' || ifnull(vorname, '')) LIKE ? ESCAPE '\\'
            OR ifnull(geburtsdatum, '') LIKE ? ESCAPE '\\'
            OR (
              substr(ifnull(geburtsdatum, ''), 9, 2) || '.' ||
              substr(ifnull(geburtsdatum, ''), 6, 2) || '.' ||
              substr(ifnull(geburtsdatum, ''), 1, 4)
            ) LIKE ? ESCAPE '\\'
            OR substr(ifnull(geburtsdatum, ''), 1, 4) LIKE ? ESCAPE '\\'
            OR ifnull(geburtsort, '') LIKE ? ESCAPE '\\'
            OR ifnull(wohnort, '') LIKE ? ESCAPE '\\'
            OR ifnull(land, '') LIKE ? ESCAPE '\\'
            OR ifnull(plz, '') LIKE ? ESCAPE '\\'
            OR ifnull(strasse, '') LIKE ? ESCAPE '\\'
            OR ifnull(ausweis, '') LIKE ? ESCAPE '\\'
            OR ifnull(versicherung, '') LIKE ? ESCAPE '\\'
            OR ifnull(krankenkasse, '') LIKE ? ESCAPE '\\'
            OR ifnull(mutter, '') LIKE ? ESCAPE '\\'
            OR species LIKE ? ESCAPE '\\'
            OR (
              CASE species
                WHEN 'mensch' THEN 'Mensch'
                WHEN 'hund' THEN 'Hund'
                WHEN 'pferd' THEN 'Pferd'
                WHEN 'tier' THEN 'Tier'
                ELSE ifnull(species, '')
              END
            ) LIKE ? ESCAPE '\\'
          )
          ORDER BY nummer, id
          LIMIT 500
        SQL
      end
    end
    rows.map { |row| patient_brief(row) }
  end

  # "Family, Given" splits on the comma. Without a comma the whole text is the family name.
  def split_name(raw)
    text = clean(raw)
    raise ArgumentError, "Name fehlt" if text.empty?
    if text.include?(",")
      left, right = text.split(",", 2)
      [clip(left, 30), clip(right, 30)]
    else
      [clip(text, 30), ""]
    end
  end

  # Exact name match, case-insensitive. Used when choosing a recipient.
  def named_people(db, nachname, vorname)
    db.execute(
      "SELECT id, ist_patient FROM person WHERE nachname = ? COLLATE NOCASE AND ifnull(vorname, '') = ? COLLATE NOCASE ORDER BY id",
      [nachname, vorname.to_s]
    )
  end

  # Links two people who already exist. Does not create a person and does not switch the open chart.
  # The same pair and label a second time is ignored.
  def add_relation(from_id, data)
    person_row(from_id)
    art = clip(data["art"], 80)
    raise ArgumentError, "Art der Beziehung fehlt" if art.empty?
    if data["to_id"].nil? || data["to_id"].to_s.strip.empty?
      raise ArgumentError, "Bitte eine vorhandene Person aus der Liste wählen."
    end
    to_id = Integer(data["to_id"].to_s)
    person_row(to_id)
    raise ArgumentError, "Eine Beziehung zeigt auf eine andere Person" if to_id.to_i == from_id.to_i
    lock do |db|
      have = db.get_first_value(
        "SELECT id FROM relation WHERE from_id = ? AND to_id = ? AND art = ? COLLATE NOCASE",
        [from_id, to_id, art]
      )
      unless have
        db.execute("INSERT INTO relation (from_id, to_id, art) VALUES (?, ?, ?)", [from_id, to_id, art])
      end
    end
    person_full(from_id)
  end

  # Removes one link and returns the chart it was attached to.
  def delete_relation(id)
    row = lock { |db| db.get_first_row("SELECT * FROM relation WHERE id = ?", [id]) }
    raise ArgumentError, "Beziehung nicht gefunden" unless row
    lock { |db| db.execute("DELETE FROM relation WHERE id = ?", [id]) }
    person_full(row["from_id"])
  end

  # Empty name means the patient is billed. A name with no person yet creates one
  # with ist_patient 0 and remember false, so the open chart stays put.
  def set_recipient(patient_id, data)
    person_row(patient_id)
    if clean(data["name"]).empty?
      lock { |db| db.execute("UPDATE person SET empfaenger_id = NULL WHERE id = ?", [patient_id]) }
      return person_full(patient_id)
    end
    nach, vor = split_name(data["name"])
    rows = lock { |db| named_people(db, nach, vor) }
    if rows.size > 1
      raise ArgumentError, "Mehrere Personen heißen so."
    end
    to_id = rows[0] && rows[0]["id"]
    if to_id && to_id.to_i == patient_id.to_i
      raise ArgumentError, "Leer lassen, wenn der Patient die Rechnung selbst erhält"
    end
    unless to_id
      created = create_patient({ "nachname" => nach, "vorname" => vor, "species" => "mensch", "ist_patient" => 0 }, false)
      to_id = created["id"]
    end
    lock { |db| db.execute("UPDATE person SET empfaenger_id = ? WHERE id = ?", [to_id, patient_id]) }
    person_full(patient_id)
  end

  # Inserts one text row. kind must be a key of TEXT_KINDS.
  # An Info may carry the label of an own shortcut. DD sets dauer 1. The open chart does not change.
  def add_text(person_id, data)
    person_row(person_id)
    kind = clean(data["kind"]).upcase
    label = TEXT_KINDS[kind]
    raise ArgumentError, "Unbekanntes Kürzel" unless label
    if kind == "I"
      custom = clip(data["label"], 40)
      label = custom unless custom.empty?
    end
    text = clip(data["text"], 100_000)
    dauer = kind == "DD" ? 1 : 0
    eid = nil
    lock { |db| eid = insert_entry(db, person_id, kind, label, text, nil, nil, dauer) }
    entry = lock { |db| db.get_first_row("SELECT * FROM entry WHERE id = ?", [eid]) }
    entry_hash(entry)
  end

  # True for kind D or DD, and for older rows still labelled Diagnose or Dauerdiagnose.
  def diagnosis_row?(row)
    kind = row["kind"].to_s
    label = row["label"].to_s
    %w[D DD].include?(kind) || label == "Diagnose" || label.casecmp("Dauerdiagnose").zero?
  end

  # Updates text only when that key is present, and only on a text kind.
  # Dauer can be toggled on a diagnosis. Clearing it on a row labelled Dauerdiagnose renames the label
  # to Diagnose, so the startup migration does not mark it again. The code label is kept.
  def patch_entry(id, data)
    row = lock { |db| db.get_first_row("SELECT * FROM entry WHERE id = ?", [id]) }
    raise ArgumentError, "Eintrag nicht gefunden" unless row
    raise ArgumentError, "Nichts zu ändern" unless data.key?("text") || data.key?("dauer")
    if data.key?("text")
      raise ArgumentError, "Dieser Eintrag bleibt so stehen" unless TEXT_KINDS.key?(row["kind"])
      text = clip(data["text"], 100_000)
      lock { |db| db.execute("UPDATE entry SET text = ? WHERE id = ?", [text, id]) }
      row["text"] = text
    end
    if data.key?("dauer")
      raise ArgumentError, "Nur eine Diagnose kann eine Dauerdiagnose sein." unless diagnosis_row?(row)
      dauer = data["dauer"] == true || data["dauer"].to_s == "1" ? 1 : 0
      kind = row["kind"].to_s
      label = row["label"].to_s
      if dauer == 1
        kind = "DD"
      else
        kind = "D"
        label = "Diagnose" if label.casecmp("Dauerdiagnose").zero?
      end
      lock { |db| db.execute("UPDATE entry SET dauer = ?, kind = ?, label = ? WHERE id = ?", [dauer, kind, label, id]) }
      row["dauer"] = dauer
      row["kind"] = kind
      row["label"] = label
    end
    entry_hash(row)
  end

  # The practice's own simple fees. No official tariff is shipped or modified here.
  def search_catalog(query)
    q = clean(query)[0, 80]
    rows = lock do |db|
      if q.empty?
        db.execute("SELECT code, text, betrag FROM catalog ORDER BY code")
      else
        like = like_query(q)
        db.execute(
          "SELECT code, text, betrag FROM catalog WHERE code LIKE ? ESCAPE '\\' OR text LIKE ? ESCAPE '\\' ORDER BY code LIMIT 50",
          [like, like]
        )
      end
    end
    rows.map { |row| { "code" => row["code"], "text" => row["text"], "betrag" => row["betrag"].to_i } }
  end

  # Faktor in Tausendsteln: 2300 ist 2,3. Der Katalogbetrag ist der einfache Satz.

  # Factor in thousandths. An empty value means 1. 2,3 is stored as 2300.
  # Allowed range is 0.001 to 20. A dot is accepted and treated as the decimal comma.
  def parse_faktor(value)
    text = clean(value).gsub(/\s+/, "").tr(".", ",")
    return 1000 if text.empty?
    unless text.match?(/\A\d{1,2}(,\d{1,3})?\z/)
      raise ArgumentError, "Faktor zwischen 0,001 und 20, zum Beispiel 2,3."
    end
    whole, frac = text.split(",", 2)
    frac = (frac || "").ljust(3, "0")[0, 3]
    ts = whole.to_i * 1000 + frac.to_i
    raise ArgumentError, "Faktor zwischen 0,001 und 20, zum Beispiel 2,3." if ts < 1 || ts > 20_000
    ts
  end

  # Thousandths back to a German decimal. Trailing zeros are dropped.
  def format_faktor(ts)
    whole, frac = ts.to_i.divmod(1000)
    return whole.to_s if frac.zero?
    format("%d,%03d", whole, frac).sub(/0+\z/, "")
  end

  # Half-up to the nearest cent. The result is copied onto the position and is not recomputed later.
  def charge_cents(base, ts)
    (base.to_i * ts.to_i + 500) / 1000
  end

  # German money: thousands separated by dots, decimal comma. Returns cents.
  def parse_euro_cents(value)
    text = clean(value).gsub(/\s+/, "")
    raise ArgumentError, "Einfachsatz fehlt" if text.empty?
    text = text.delete(".") if text.include?(",")
    text = text.tr(",", ".")
    raise ArgumentError, "Einfachsatz nicht erkannt" unless text.match?(/\A\d+(\.\d{1,2})?\z/)
    euros, cents = text.split(".", 2)
    cents = (cents || "").ljust(2, "0")
    amount = euros.to_i * 100 + cents.to_i
    raise ArgumentError, "Einfachsatz nicht erkannt" if amount > 10_000_000
    amount
  end

  # Own shortcuts live in kuerzel/eigene.json, outside the database file.
  def kuerzel_file
    File.join(KUERZEL, "eigene.json")
  end

  # Loads own shortcuts and drops any code that is reserved or not one to eight letters.
  def read_kuerzel
    path = kuerzel_file
    return [] unless File.file?(path)
    data = JSON.parse(File.read(path, encoding: "UTF-8"))
    Array(data["kuerzel"]).filter_map do |row|
      code = clean(row["code"]).upcase
      label = clip(row["label"], 40)
      next if code.empty? || label.empty?
      next unless code.match?(/\A[A-Z]{1,8}\z/)
      next if RESERVED_KUERZEL.include?(code)
      { "code" => code, "label" => label }
    end
  rescue JSON::ParserError
    []
  end

  # Writes the JSON beside the file and renames it into place.
  def write_kuerzel(rows)
    FileUtils.mkdir_p(KUERZEL)
    tmp = kuerzel_file + ".neu"
    File.write(tmp, JSON.generate({ "kuerzel" => rows }), encoding: "UTF-8")
    File.rename(tmp, kuerzel_file)
  end

  # Letters only, at most eight. A built-in code cannot be replaced.
  def save_kuerzel(data)
    code = clean(data["code"]).upcase
    label = clip(data["label"], 40)
    raise ArgumentError, "Kürzel fehlt" if code.empty?
    raise ArgumentError, "Bezeichnung fehlt" if label.empty?
    raise ArgumentError, "Nur Buchstaben, höchstens 8." unless code.match?(/\A[A-Z]{1,8}\z/)
    raise ArgumentError, "Dieses Kürzel ist schon vergeben." if RESERVED_KUERZEL.include?(code)
    taken = lock { |db| db.get_first_value("SELECT 1 FROM baustein WHERE kuerzel = ? COLLATE NOCASE LIMIT 1", [code]) }
    raise ArgumentError, "Dieses Kürzel ist schon ein Textbaustein." if taken
    rows = read_kuerzel.reject { |row| row["code"] == code }
    rows << { "code" => code, "label" => label }
    rows.sort_by! { |row| row["code"] }
    write_kuerzel(rows)
    { "kuerzel" => rows }
  end

  # Removes the shortcut only. Chart rows already written stay.
  def delete_kuerzel(code)
    rows = read_kuerzel.reject { |row| row["code"] == clean(code).upcase }
    write_kuerzel(rows)
    { "kuerzel" => rows }
  end

  # The two examples are inserted once. Deleting them afterwards stays deleted.
  # meta baustein_saat is that one-time mark. It is not a clinical catalog.
  def ensure_bausteine
    return if @db.get_first_value("SELECT value FROM meta WHERE key = 'baustein_saat'") == "1"
    examples = [
      ["B", "phar", "Rachen mäßig gerötet, kein Pus, keine isolierte pharyngeale schwellung, keine cervicale Lymphknotenschwellung, Pulmo frei"],
      ["A", "inf", "Seit einigen Tagen Erkältungssymptome, laufende Nase, kratzender Hals und subfebrile Temperaturen"]
    ]
    @db.transaction do
      examples.each do |kind, code, text|
        have = @db.get_first_value(
          "SELECT id FROM baustein WHERE kind = ? AND kuerzel = ? COLLATE NOCASE",
          [kind, code]
        )
        next if have
        @db.execute("INSERT INTO baustein (kind, kuerzel, text) VALUES (?, ?, ?)", [kind, code, text])
      end
      @db.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('baustein_saat', '1')")
    end
  end

  # One text block for the browser. The stored spelling of the shortcut is kept.
  def baustein_hash(row)
    {
      "id" => row["id"].to_i,
      "kind" => row["kind"].to_s,
      "rubrik" => TEXT_KINDS[row["kind"].to_s].to_s,
      "kuerzel" => row["kuerzel"].to_s,
      "text" => row["text"].to_s
    }
  end

  # Rubric, shortcut and text. A reserved shortcut cannot become a block.
  # The same shortcut may exist in two rubrics. Matching ignores case.
  def baustein_fields(data)
    kind = clean(data["kind"]).upcase
    unless TEXT_KINDS.key?(kind)
      raise ArgumentError, "Rubrik ist Anamnese, Befund, Diagnose, Dauerdiagnose, CAVE, Procedere, Info oder Labor."
    end
    code = clean(data["kuerzel"])
    code = clean(data["code"]) if code.empty?
    raise ArgumentError, "Kürzel fehlt." if code.empty?
    raise ArgumentError, "Nur Buchstaben und Ziffern, höchstens 16." unless code.match?(/\A[A-Za-z0-9]{1,16}\z/)
    raise ArgumentError, "Dieses Kürzel ist schon vergeben." if RESERVED_KUERZEL.include?(code.upcase)
    text = clip(data["text"], 100_000)
    raise ArgumentError, "Text fehlt." if text.empty?
    [kind, code, text]
  end

  # An Info shortcut and a text block must not share a code. The footer could not tell them apart.
  def baustein_info_clash?(code)
    read_kuerzel.any? { |row| row["code"] == code.upcase }
  end

  # Lists text blocks. q filters rubric, shortcut and text. Order follows the rubrics.
  def list_bausteine(query)
    needle = fold_text(query)
    rows = lock { |db| db.execute("SELECT * FROM baustein") }
    unless needle.empty?
      rows = rows.select do |row|
        blob = fold_text([TEXT_KINDS[row["kind"].to_s], row["kuerzel"], row["text"]].join(" "))
        blob.include?(needle)
      end
    end
    order = TEXT_KINDS.keys
    rows.sort_by! { |row| [order.index(row["kind"]) || 99, row["kuerzel"].to_s.upcase, row["id"].to_i] }
    rows.map { |row| baustein_hash(row) }
  end

  # Inserts one block. The same shortcut in the same rubric is refused.
  def add_baustein(data)
    kind, code, text = baustein_fields(data)
    raise ArgumentError, "Dieses Kürzel ist schon ein Info-Kürzel." if baustein_info_clash?(code)
    id = nil
    lock do |db|
      have = db.get_first_value(
        "SELECT id FROM baustein WHERE kind = ? AND kuerzel = ? COLLATE NOCASE",
        [kind, code]
      )
      raise ArgumentError, "Dieses Kürzel gibt es in dieser Rubrik schon." if have
      db.execute("INSERT INTO baustein (kind, kuerzel, text) VALUES (?, ?, ?)", [kind, code, text])
      id = db.last_insert_row_id
    end
    baustein_hash(lock { |db| db.get_first_row("SELECT * FROM baustein WHERE id = ?", [id]) })
  end

  # Replaces rubric, shortcut and text. Chart rows already written stay.
  def patch_baustein(id, data)
    kind, code, text = baustein_fields(data)
    raise ArgumentError, "Dieses Kürzel ist schon ein Info-Kürzel." if baustein_info_clash?(code)
    lock do |db|
      have = db.get_first_row("SELECT id FROM baustein WHERE id = ?", [id])
      raise ArgumentError, "Textbaustein nicht gefunden." unless have
      other = db.get_first_value(
        "SELECT id FROM baustein WHERE kind = ? AND kuerzel = ? COLLATE NOCASE AND id != ?",
        [kind, code, id.to_i]
      )
      raise ArgumentError, "Dieses Kürzel gibt es in dieser Rubrik schon." if other
      db.execute(
        "UPDATE baustein SET kind = ?, kuerzel = ?, text = ? WHERE id = ?",
        [kind, code, text, id.to_i]
      )
    end
    baustein_hash(lock { |db| db.get_first_row("SELECT * FROM baustein WHERE id = ?", [id]) })
  end

  # Removes the block only. Chart rows already written stay.
  def delete_baustein(id)
    lock do |db|
      have = db.get_first_row("SELECT id FROM baustein WHERE id = ?", [id])
      raise ArgumentError, "Textbaustein nicht gefunden." unless have
      db.execute("DELETE FROM baustein WHERE id = ?", [id])
    end
    { "ok" => true }
  end

  ICD_KODES = File.join(ROOT, "import", "icd", "meta", "Klassifikationsdateien", "icd10gm2026syst_kodes.txt").freeze
  ICD_VERSION = "2026".freeze

  # Creates the catalog table. Official rows are imported again only when the version or the count says they are missing.
  # Rows with quelle eigen are not deleted here.
  def ensure_diagnosen
    @db.execute_batch <<~SQL
      CREATE TABLE IF NOT EXISTS diagnose (
        code TEXT NOT NULL,
        kurz TEXT NOT NULL,
        lang TEXT NOT NULL DEFAULT '',
        quelle TEXT NOT NULL,
        norm TEXT NOT NULL,
        such TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (quelle, code)
      );
      CREATE INDEX IF NOT EXISTS diagnose_norm ON diagnose(quelle, norm);
    SQL
    version = @db.get_first_value("SELECT value FROM meta WHERE key = 'icd10gm'")
    count = @db.get_first_value("SELECT COUNT(*) FROM diagnose WHERE quelle = 'icd10'").to_i
    return if version == ICD_VERSION && count > 1000
    import_icd10
  end

  # Loads terminal class titles from the BfArM file. The official text is stored as given, and lang stays empty.
  # Own rows are a different quelle and are not touched. The file is not rewritten.
  def import_icd10
    unless File.file?(ICD_KODES)
      warn "ICD-10-GM fehlt: #{ICD_KODES}"
      return
    end
    rows = []
    CSV.foreach(ICD_KODES, col_sep: ";", encoding: "bom|utf-8") do |col|
      next unless col && col.length >= 26
      next unless col[1] == "T" && col[12] != "V" && col[25] == "J"
      code = clean(col[5])
      kurz = clean(col[8])
      kurz = clean(col[11]) if kurz.empty?
      kurz = clean(col[10]) if kurz.empty?
      kurz = clean(col[9]) if kurz.empty?
      next if code.empty? || kurz.empty?
      norm = diagnose_norm(code)
      next if norm.empty?
      leaf = [col[11], col[10], col[9]].map { |part| clean(part) }.reject(&:empty?).join(" ")
      rows << [code, kurz, norm, diagnose_such(code, kurz, leaf, norm)]
    end
    @db.transaction do
      @db.execute("DELETE FROM diagnose WHERE quelle = 'icd10'")
      stmt = @db.prepare("INSERT INTO diagnose (code, kurz, lang, quelle, norm, such) VALUES (?, ?, '', 'icd10', ?, ?)")
      rows.each { |row| stmt.execute(row) }
      stmt.close
      @db.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('icd10gm', ?)", [ICD_VERSION])
    end
  end

  # Letters and digits only, so a code with a dot and the same code without one match.
  def diagnose_norm(code)
    text = clean(code).dup.force_encoding(Encoding::UTF_8)
    text = text.scrub unless text.valid_encoding?
    text.upcase.gsub(/[^A-Z0-9]/, "")
  end

  # Search fold: lowercase, umlauts expanded, punctuation turned into spaces.
  def fold_text(value)
    text = clean(value).dup.force_encoding(Encoding::UTF_8)
    text = text.valid_encoding? ? text : text.scrub
    text = text.unicode_normalize(:nfc).downcase
    text = text.gsub("ä", "ae").gsub("ö", "oe").gsub("ü", "ue").gsub("ß", "ss")
    text.gsub(/[^a-z0-9]+/, " ").squeeze(" ").strip
  end

  # Blob stored for the catalog search.
  def diagnose_such(code, kurz, lang, norm)
    [norm.downcase, fold_text(code), fold_text(kurz), fold_text(lang)].reject(&:empty?).join(" ")
  end

  # One catalog row for the browser: code, short title, long text, source.
  def diagnose_hash(row)
    {
      "code" => row["code"],
      "kurz" => row["kurz"],
      "lang" => row["lang"].to_s,
      "quelle" => row["quelle"]
    }
  end

  # Empty query lists own rows only. A search prefers an exact code, then an own row over the official one.
  def search_diagnosen(query)
    norm = diagnose_norm(query)
    folded = fold_text(query)
    rows = lock do |db|
      if norm.empty? && folded.empty?
        db.execute("SELECT code, kurz, lang, quelle FROM diagnose WHERE quelle = 'eigen' ORDER BY code")
      else
        key = folded.empty? ? norm.downcase : folded
        like = like_query(key)
        db.execute(<<~SQL, [norm, key, like, norm])
          SELECT code, kurz, lang, quelle FROM diagnose
          WHERE norm = ? OR (length(?) >= 2 AND such LIKE ? ESCAPE '\\')
          ORDER BY CASE WHEN norm = ? THEN 0 ELSE 1 END,
                   CASE quelle WHEN 'eigen' THEN 0 ELSE 1 END,
                   code
          LIMIT 40
        SQL
      end
    end
    { "diagnosen" => rows.map { |row| diagnose_hash(row) } }
  end

  # Stores an own row. The same normalized code replaces the previous own row and leaves the official title in place.
  def save_diagnose(data)
    code = clean(data["code"]).upcase
    kurz = clip(data["kurz"], 200)
    lang = clip(data["lang"], 300)
    raise ArgumentError, "Kürzel fehlt" if code.empty?
    raise ArgumentError, "Diagnose fehlt" if kurz.empty?
    unless code.match?(/\A[A-Z0-9][A-Z0-9.!*+\-]{0,15}\z/)
      raise ArgumentError, "Kürzel: Buchstaben, Ziffern und . ! * + -, höchstens 16 Zeichen."
    end
    norm = diagnose_norm(code)
    raise ArgumentError, "Kürzel fehlt" if norm.empty?
    if RESERVED_KUERZEL.include?(code) || RESERVED_KUERZEL.include?(norm)
      raise ArgumentError, "Dieses Kürzel ist schon vergeben."
    end
    lang = "" if lang == kurz
    such = diagnose_such(code, kurz, lang, norm)
    lock do |db|
      db.execute("DELETE FROM diagnose WHERE quelle = 'eigen' AND norm = ?", [norm])
      db.execute(
        "INSERT INTO diagnose (code, kurz, lang, quelle, norm, such) VALUES (?, ?, ?, 'eigen', ?, ?)",
        [code, kurz, lang, norm, such]
      )
    end
    { "code" => code, "kurz" => kurz, "lang" => lang, "quelle" => "eigen" }
  end

  # Deletes an own row only. Official titles cannot be removed from here.
  def delete_diagnose(code)
    norm = diagnose_norm(code)
    raise ArgumentError, "Kürzel fehlt" if norm.empty?
    gone = lock do |db|
      have = db.get_first_value("SELECT code FROM diagnose WHERE quelle = 'eigen' AND norm = ?", [norm])
      db.execute("DELETE FROM diagnose WHERE quelle = 'eigen' AND norm = ?", [norm]) if have
      have
    end
    raise ArgumentError, "Diese eigene Diagnose gibt es nicht." unless gone
    search_diagnosen("")
  end

  # Looks up a code. An own row wins over the official row with the same normalized code.
  def find_diagnose(code)
    norm = diagnose_norm(code)
    raise ArgumentError, "Kürzel fehlt" if norm.empty?
    rows = lock do |db|
      db.execute(
        "SELECT code, kurz, lang, quelle FROM diagnose WHERE norm = ? ORDER BY CASE quelle WHEN 'eigen' THEN 0 ELSE 1 END",
        [norm]
      )
    end
    row = rows.find { |item| item["quelle"] == "eigen" } || rows.first
    raise ArgumentError, "Diese Diagnose gibt es nicht." unless row
    row
  end

  # Copies the catalog code into the chart label, and the title plus any long text into the body.
  # dauer stores kind DD. Does not change which chart is open.
  def add_diagnose(person_id, data)
    person_row(person_id)
    row = find_diagnose(data["code"])
    text = row["kurz"].to_s
    lang = row["lang"].to_s
    text = "#{text}\n\n#{lang}" unless lang.empty? || lang == text
    dauer = data["dauer"] == true || data["dauer"].to_s == "1" ? 1 : 0
    kind = dauer == 1 ? "DD" : "D"
    eid = nil
    lock { |db| eid = insert_entry(db, person_id, kind, row["code"], text, nil, nil, dauer) }
    entry = lock { |db| db.get_first_row("SELECT * FROM entry WHERE id = ?", [eid]) }
    entry_hash(entry)
  end

  # Adds one simple fee. A code that already exists is refused. Charged positions are not rewritten.
  def add_catalog(data)
    code = clean(data["code"])[0, 40]
    text = clip(data["text"], 200)
    raise ArgumentError, "Kürzel fehlt" if code.empty?
    raise ArgumentError, "Bezeichnung fehlt" if text.empty?
    betrag = parse_euro_cents(data["betrag"])
    lock do |db|
      have = db.get_first_row("SELECT code FROM catalog WHERE code = ? COLLATE NOCASE", [code])
      raise ArgumentError, "Dieses Kürzel gibt es schon." if have
      db.execute(
        "INSERT INTO catalog (code, text, betrag) VALUES (?, ?, ?)",
        [code, text, betrag]
      )
    end
    { "code" => code, "text" => text, "betrag" => betrag }
  end

  # Changes the label and the simple fee. The code stays. Charged positions keep their own amount.
  def patch_catalog(data)
    code = clean(data["code"])[0, 40]
    text = clip(data["text"], 200)
    raise ArgumentError, "Kürzel fehlt" if code.empty?
    raise ArgumentError, "Bezeichnung fehlt" if text.empty?
    betrag = parse_euro_cents(data["betrag"])
    stored = nil
    lock do |db|
      have = db.get_first_row("SELECT code FROM catalog WHERE code = ? COLLATE NOCASE", [code])
      raise ArgumentError, "Dieses Kürzel gibt es nicht." unless have
      stored = have["code"]
      db.execute("UPDATE catalog SET text = ?, betrag = ? WHERE code = ? COLLATE NOCASE", [text, betrag, stored])
    end
    { "code" => stored, "text" => text, "betrag" => betrag }
  end

  # Drops one catalog row. Positions already charged keep their copied text and amount.
  def delete_catalog(code)
    # The query string arrives as binary. SQLite only matches it once it is UTF-8.
    key = clean(code).dup.force_encoding(Encoding::UTF_8)[0, 40]
    raise ArgumentError, "Ungültige Eingabe" unless key.valid_encoding?
    raise ArgumentError, "Kürzel fehlt" if key.empty?
    gone = lock do |db|
      have = db.get_first_row("SELECT code FROM catalog WHERE code = ? COLLATE NOCASE", [key])
      db.execute("DELETE FROM catalog WHERE code = ? COLLATE NOCASE", [key]) if have
      have && have["code"]
    end
    raise ArgumentError, "Dieses Kürzel gibt es nicht." unless gone
    { "code" => gone }
  end

  # Opens one letter template in LibreOffice. The name is a file stem inside vorlagen/.
  def open_template(data)
    name = template_stem(data["name"])
    path = template_path(name)
    opened = workstation_here? ? reveal_office(path) : false
    raise ArgumentError, "LibreOffice hat die Vorlage nicht geöffnet." if workstation_here? && !opened
    { "ok" => true, "opened" => opened, "holen" => "/api/templates/#{name}/datei", "name" => File.basename(path) }
  end

  # The configured standard, or 1 when the setting is empty.
  def standard_faktor_ts
    raw = lock { |db| db.get_first_value("SELECT standardfaktor FROM practice WHERE id = 1") }
    value = raw.to_i
    value < 1 || value > 20_000 ? 1000 : value
  end

  # An empty or missing factor uses the standard. A typed factor is used as given.
  def chosen_faktor(data)
    return standard_faktor_ts if !data.key?("faktor") || clean(data["faktor"]).empty?
    parse_faktor(data["faktor"])
  end

  # Chart text shows the factor only when it is not 1.
  def position_text(text, faktor)
    faktor == 1000 ? text.to_s : "#{text} × #{format_faktor(faktor)}"
  end

  # Copies a catalog row onto today, or onto the given day. An unknown code is refused, not created.
  # The charged cents, the factor and the simple fee are stored on the position.
  def add_position(person_id, data, invoice_id = nil)
    person_row(person_id)
    code = clean(data["code"])[0, 40]
    raise ArgumentError, "Kürzel fehlt" if code.empty?
    faktor = chosen_faktor(data)
    row = lock { |db| db.get_first_row("SELECT code, text, betrag FROM catalog WHERE code = ? COLLATE NOCASE", [code]) }
    raise ArgumentError, "Unbekanntes Kürzel" unless row
    tag = clean(data["datum"]).empty? ? today : parse_date(data["datum"])
    basis = row["betrag"].to_i
    betrag = charge_cents(basis, faktor)
    shown = position_text(row["text"], faktor)
    eid = nil
    lock do |db|
      eid = insert_entry(db, person_id, "ZI", row["code"], shown, nil, tag)
      db.execute(
        "INSERT INTO position (person_id, tag, code, text, betrag, entry_id, faktor, basis, invoice_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [person_id, tag, row["code"], row["text"], betrag, eid, faktor, basis, invoice_id]
      )
      pid = db.last_insert_row_id
      db.execute("UPDATE entry SET ref_id = ? WHERE id = ?", [pid, eid])
      refresh_invoice_sum(db, invoice_id) if invoice_id
    end
    entry = lock { |db| db.get_first_row("SELECT * FROM entry WHERE id = ?", [eid]) }
    entry_hash(entry)
  end

  # Open positions, and every invoice of this chart, paid ones included.
  def billing(person_id)
    person_row(person_id)
    open_rows = lock do |db|
      db.execute("SELECT * FROM position WHERE person_id = ? AND invoice_id IS NULL ORDER BY tag, id", [person_id])
    end
    invoices = lock do |db|
      db.execute("SELECT * FROM invoice WHERE person_id = ? ORDER BY datum, id", [person_id])
    end
    {
      "open" => open_rows.map { |row| position_hash(row) },
      "invoices" => invoices.map { |row| invoice_hash(row) }
    }
  end

  # faktor nil means the row was stored before factors existed. Its amount stands as stored.
  def position_hash(row)
    {
      "id" => row["id"],
      "tag" => row["tag"],
      "tag_anzeige" => show_date(row["tag"]),
      "code" => row["code"],
      "text" => row["text"],
      "betrag" => row["betrag"].to_i,
      "faktor" => row["faktor"].nil? ? nil : format_faktor(row["faktor"])
    }
  end

  # The date on the paper is the first print. Before that, it is the day the invoice was made.
  def invoice_paper_date(row)
    printed = row["gedruckt"].to_s
    printed.empty? ? row["datum"] : printed
  end

  # Invoice header for the list.
  def invoice_hash(row)
    {
      "id" => row["id"],
      "nummer" => row["nummer"],
      "datum" => row["datum"],
      "datum_anzeige" => show_date(row["datum"]),
      "paper_anzeige" => show_date(invoice_paper_date(row)),
      "gedruckt" => row["gedruckt"].to_s,
      "gedruckt_anzeige" => show_date(row["gedruckt"]),
      "bezahlt" => row["bezahlt"].to_s,
      "bezahlt_anzeige" => show_date(row["bezahlt"]),
      "betrag" => row["betrag"].to_i,
      "mahnung" => row["mahnung"],
      "mahnung_anzeige" => show_date(row["mahnung"])
    }
  end

  # Rewrites the stored total from the lines that are on the invoice now.
  def refresh_invoice_sum(db, invoice_id)
    sum = db.get_first_value("SELECT COALESCE(SUM(betrag), 0) FROM position WHERE invoice_id = ?", [invoice_id]).to_i
    db.execute("UPDATE invoice SET betrag = ? WHERE id = ?", [sum, invoice_id])
  end

  # Changes the factor, the treatment day, or both. The simple fee stored on the line is kept.
  # The chart row moves to the same day. The first print date of the invoice is not touched.
  def patch_invoice_position(invoice_id, position_id, data)
    raise ArgumentError, "Nichts zu ändern." unless data.key?("faktor") || data.key?("datum")
    fresh = nil
    entry = nil
    lock do |db|
      db.transaction do
        pos = db.get_first_row("SELECT * FROM position WHERE id = ? AND invoice_id = ?", [position_id, invoice_id])
        raise ArgumentError, "Position nicht gefunden" unless pos
        fresh, entry = apply_position_change(db, pos, data)
        refresh_invoice_sum(db, invoice_id)
      end
    end
    payload = invoice_full(invoice_id)
    payload["entry"] = entry_hash(entry) if entry
    payload
  end

  # Changes the day of a position that is not on an invoice yet.
  def patch_open_position(person_id, position_id, data)
    raise ArgumentError, "Datum fehlt." unless data.key?("datum")
    fresh = nil
    entry = nil
    lock do |db|
      db.transaction do
        pos = db.get_first_row(
          "SELECT * FROM position WHERE id = ? AND person_id = ? AND invoice_id IS NULL",
          [position_id, person_id]
        )
        raise ArgumentError, "Position nicht gefunden" unless pos
        fresh, entry = apply_position_change(db, pos, data)
      end
    end
    { "position" => position_hash(fresh), "entry" => entry ? entry_hash(entry) : nil }
  end

  # Writes factor and day onto one position and its chart row. Called inside a lock.
  def apply_position_change(db, pos, data)
    faktor = pos["faktor"]
    basis = pos["basis"]
    betrag = pos["betrag"].to_i
    tag = pos["tag"]
    text = pos["text"]
    change_factor = data.key?("faktor") && !clean(data["faktor"]).empty?
    if change_factor
      faktor = parse_faktor(data["faktor"])
      if basis.nil?
        basis = betrag if pos["faktor"].nil? || pos["faktor"].to_i == 1000
        basis ||= db.get_first_value("SELECT betrag FROM catalog WHERE code = ? COLLATE NOCASE", [pos["code"]])
        basis ||= betrag
      end
      betrag = charge_cents(basis.to_i, faktor)
      text = position_text(pos["text"], faktor)
    end
    if data.key?("datum")
      raw = clean(data["datum"])
      raise ArgumentError, "Datum fehlt." if raw.empty?
      tag = parse_date(raw)
    end
    db.execute(
      "UPDATE position SET tag = ?, betrag = ?, basis = ?, faktor = ? WHERE id = ?",
      [tag, betrag, basis.nil? ? nil : basis.to_i, faktor, pos["id"]]
    )
    entry = nil
    if pos["entry_id"]
      if change_factor
        db.execute("UPDATE entry SET text = ?, tag = ? WHERE id = ?", [text, tag, pos["entry_id"]])
      else
        db.execute("UPDATE entry SET tag = ? WHERE id = ?", [tag, pos["entry_id"]])
      end
      entry = db.get_first_row("SELECT * FROM entry WHERE id = ?", [pos["entry_id"]])
    end
    [db.get_first_row("SELECT * FROM position WHERE id = ?", [pos["id"]]), entry]
  end

  # Puts one line back among the open positions. The last line stays on the invoice.
  def detach_invoice_position(invoice_id, position_id)
    lock do |db|
      db.transaction do
        count = db.get_first_value("SELECT COUNT(*) FROM position WHERE invoice_id = ?", [invoice_id]).to_i
        raise ArgumentError, "Die letzte Position bleibt auf der Rechnung." if count <= 1
        have = db.get_first_value("SELECT id FROM position WHERE id = ? AND invoice_id = ?", [position_id, invoice_id])
        raise ArgumentError, "Position nicht gefunden" unless have
        db.execute("UPDATE position SET invoice_id = NULL WHERE id = ?", [position_id])
        refresh_invoice_sum(db, invoice_id)
      end
    end
    invoice_full(invoice_id)
  end

  # Adds a catalog fee straight onto this invoice. The print date stays as it is.
  def add_invoice_position(invoice_id, data)
    invoice = lock { |db| db.get_first_row("SELECT * FROM invoice WHERE id = ?", [invoice_id]) }
    raise ArgumentError, "Rechnung nicht gefunden" unless invoice
    entry = add_position(invoice["person_id"], data, invoice_id)
    invoice_full(invoice_id).merge("entry" => entry)
  end

  # Remembers the day of the first print and leaves it unchanged after that.
  def print_invoice(id)
    row = lock { |db| db.get_first_row("SELECT * FROM invoice WHERE id = ?", [id]) }
    raise ArgumentError, "Rechnung nicht gefunden" unless row
    if row["gedruckt"].to_s.strip.empty?
      lock { |db| db.execute("UPDATE invoice SET gedruckt = ? WHERE id = ? AND (gedruckt IS NULL OR trim(gedruckt) = '')", [today, id]) }
    end
    invoice_full(id)
  end

  # Attaches every open position to a new invoice. The number is YEAR-NNN, counted in that year.
  # The recipient is copied from the chart as it stands now.
  def create_invoice(person_id)
    person_row(person_id)
    inv_id = nil
    lock do |db|
      db.transaction do
        rows = db.execute("SELECT id, betrag FROM position WHERE person_id = ? AND invoice_id IS NULL ORDER BY tag, id", [person_id])
        raise ArgumentError, "Keine offenen Positionen" if rows.empty?
        sum = rows.reduce(0) { |acc, row| acc + row["betrag"].to_i }
        year = Date.today.year
        count = db.get_first_value("SELECT COUNT(*) FROM invoice WHERE nummer LIKE ?", ["#{year}-%"]).to_i
        nummer = format("%d-%03d", year, count + 1)
        patient = db.get_first_row("SELECT empfaenger_id FROM person WHERE id = ?", [person_id])
        db.execute(
          "INSERT INTO invoice (person_id, empfaenger_id, nummer, datum, betrag) VALUES (?, ?, ?, ?, ?)",
          [person_id, patient["empfaenger_id"], nummer, today, sum]
        )
        inv_id = db.last_insert_row_id
        rows.each do |row|
          db.execute("UPDATE position SET invoice_id = ? WHERE id = ?", [inv_id, row["id"]])
        end
      end
    end
    invoice_full(inv_id)
  end

  # Sets mahnung or bezahlt to today. field is one of those two route names, not free text.
  # A paid invoice cannot be reminded.
  def mark_invoice(id, field)
    row = lock { |db| db.get_first_row("SELECT * FROM invoice WHERE id = ?", [id]) }
    raise ArgumentError, "Rechnung nicht gefunden" unless row
    raise ArgumentError, "Die Rechnung ist bezahlt" if row["bezahlt"] && field == "mahnung"
    lock { |db| db.execute("UPDATE invoice SET #{field} = ? WHERE id = ?", [today, id]) }
    invoice_full(id)
  end

  # Invoice plus its lines, the patient, the recipient, and the practice identity. The recipient falls back to the patient.
  def invoice_full(id)
    row = lock { |db| db.get_first_row("SELECT * FROM invoice WHERE id = ?", [id]) }
    raise ArgumentError, "Rechnung nicht gefunden" unless row
    lines = lock { |db| db.execute("SELECT * FROM position WHERE invoice_id = ? ORDER BY tag, id", [id]) }
    patient = person_hash(person_row(row["person_id"]))
    recipient = if row["empfaenger_id"]
                  person_hash(person_row(row["empfaenger_id"]))
                else
                  patient
                end
    invoice_hash(row).merge(
      "lines" => lines.map { |line| position_hash(line) },
      "patient" => patient,
      "empfaenger" => recipient,
      "practice" => practice_hash
    )
  end

  # Needs at least two characters. Matches the name or the registration number.
  def search_medicines(query)
    q = clean(query)[0, 80]
    return [] if q.length < 2
    like = like_query(q)
    rows = lock do |db|
      db.execute(
        "SELECT id, name, zulassung FROM medicine WHERE name LIKE ? ESCAPE '\\' OR zulassung LIKE ? ESCAPE '\\' ORDER BY name LIMIT 30",
        [like, like]
      )
    end
    rows.map { |row| { "id" => row["id"], "name" => row["name"], "zulassung" => row["zulassung"].to_s } }
  end

  # One medication line. A stop date means it is history.
  def plan_hash(row)
    {
      "id" => row["id"],
      "typ" => row["typ"],
      "artikel" => row["artikel"],
      "dosis" => row["dosis"].to_s,
      "start" => row["start"],
      "start_anzeige" => show_date(row["start"]),
      "instruktion" => row["instruktion"].to_s,
      "grund" => row["grund"].to_s,
      "stop" => row["stop"],
      "stop_anzeige" => show_date(row["stop"]),
      "stop_grund" => row["stop_grund"].to_s
    }
  end

  # Active lines have no stop date. Stopped lines are returned separately.
  def plan_for(person_id)
    person_row(person_id)
    rows = lock { |db| db.execute("SELECT * FROM plan WHERE person_id = ? ORDER BY id", [person_id]) }
    active, stopped = rows.partition { |row| row["stop"].nil? || row["stop"].to_s.empty? }
    { "active" => active.map { |row| plan_hash(row) }, "stopped" => stopped.map { |row| plan_hash(row) } }
  end

  # typ is F, R or S. Anything else is stored as F, the standing medication.
  def add_plan(person_id, data)
    person_row(person_id)
    typ = clean(data["typ"]).upcase
    typ = "F" unless %w[F R S].include?(typ)
    artikel = clip(data["artikel"], 300)
    raise ArgumentError, "Artikel fehlt" if artikel.empty?
    start = parse_date(data["start"]) || today
    lock do |db|
      db.execute(<<~SQL, [person_id, typ, data["medicine_id"], artikel, clip(data["dosis"], 40), start, clip(data["instruktion"], 500), clip(data["grund"], 500)])
        INSERT INTO plan (person_id, typ, medicine_id, artikel, dosis, start, instruktion, grund)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      SQL
    end
    plan_for(person_id)
  end

  # Only the dose can be changed from here.
  def patch_plan(id, data)
    row = lock { |db| db.get_first_row("SELECT * FROM plan WHERE id = ?", [id]) }
    raise ArgumentError, "Zeile nicht gefunden" unless row
    raise ArgumentError, "Dosierung fehlt" unless data.key?("dosis")
    lock { |db| db.execute("UPDATE plan SET dosis = ? WHERE id = ?", [clip(data["dosis"], 40), id]) }
    plan_for(row["person_id"])
  end

  # Sets the stop date and an optional reason. The line stays in the history.
  def stop_plan(id, data)
    row = lock { |db| db.get_first_row("SELECT * FROM plan WHERE id = ?", [id]) }
    raise ArgumentError, "Zeile nicht gefunden" unless row
    stop = parse_date(data["stop"]) || today
    lock { |db| db.execute("UPDATE plan SET stop = ?, stop_grund = ? WHERE id = ?", [stop, clip(data["grund"], 500), id]) }
    plan_for(row["person_id"])
  end

  # Writes the prescription, its lines, and a chart row of kind RP. The chart text is a one-line summary.
  def add_prescription(person_id, data)
    person_row(person_id)
    lines = data["lines"]
    raise ArgumentError, "Keine Medikamente" unless lines.is_a?(Array) && !lines.empty?
    raise ArgumentError, "Zu viele Medikamente" if lines.length > 60
    pid = nil
    eid = nil
    text_lines = []
    lock do |db|
      db.transaction do
        eid = insert_entry(db, person_id, "RP", "Rezept", "")
        db.execute("INSERT INTO prescription (person_id, datum, entry_id) VALUES (?, ?, ?)", [person_id, today, eid])
        pid = db.last_insert_row_id
        db.execute("UPDATE entry SET ref_id = ? WHERE id = ?", [pid, eid])
        lines.each_with_index do |line, index|
          raise ArgumentError, "Artikel fehlt" unless line.is_a?(Hash)
          artikel = clip(line["artikel"], 300)
          raise ArgumentError, "Artikel fehlt" if artikel.empty?
          menge = clip(line["menge"], 20)
          dosis = clip(line["dosis"], 40)
          anweisung = clip(line["anweisung"], 500)
          db.execute(
            "INSERT INTO prescription_line (prescription_id, artikel, menge, dosis, anweisung, sort) VALUES (?, ?, ?, ?, ?, ?)",
            [pid, artikel, menge, dosis, anweisung, index]
          )
          bits = [artikel]
          bits << "#{menge} OP" unless menge.empty?
          bits << dosis unless dosis.empty?
          bits << anweisung unless anweisung.empty?
          text_lines << bits.join(", ")
        end
        db.execute("UPDATE entry SET text = ? WHERE id = ?", [text_lines.join(" · "), eid])
      end
    end
    entry = lock { |db| db.get_first_row("SELECT * FROM entry WHERE id = ?", [eid]) }
    { "id" => pid, "entry" => entry_hash(entry) }
  end

  # Payload for the printed prescription: patient, practice and lines.
  def prescription_full(id)
    row = lock { |db| db.get_first_row("SELECT * FROM prescription WHERE id = ?", [id]) }
    raise ArgumentError, "Rezept nicht gefunden" unless row
    lines = lock { |db| db.execute("SELECT * FROM prescription_line WHERE prescription_id = ? ORDER BY sort, id", [id]) }
    {
      "id" => row["id"],
      "datum" => row["datum"],
      "datum_anzeige" => show_date(row["datum"]),
      "patient" => person_hash(person_row(row["person_id"])),
      "practice" => practice_hash,
      "lines" => lines.map { |line|
        {
          "artikel" => line["artikel"],
          "menge" => line["menge"].to_s,
          "dosis" => line["dosis"].to_s,
          "anweisung" => line["anweisung"].to_s
        }
      }
    }
  end

  # Printed above the invoice lines when no own text is stored.
  RECHNUNG_TEXT = "{Anrede},\n\nvielen Dank für Ihren Besuch. Für die erbrachten Leistungen stelle ich Ihnen die folgenden Positionen in Rechnung."

  # Letterheads. Empty storage prints these. The invoice head stays above the address window.
  # The prescription head is the block at the top left. Bodies are not part of either text.
  HEAD_TEXT = {
    "rechnungskopf" => "{{ARZT}}\n{{ARZTNUMMER}}\n{{ADRESSE}}\n{{TELEFON}}",
    "rezeptkopf" => "{{ARZT}}\n{{FACH}}\n{{ARZTNUMMER}}\n{{ADRESSE}}\n{{TELEFON}}"
  }.freeze

  # The single practice row. Phone numbers are one per line in the database and an array in JSON.
  # An empty IBAN is omitted from the invoice. An empty invoice text uses RECHNUNG_TEXT.
  def practice_hash
    row = lock { |db| db.get_first_row("SELECT * FROM practice WHERE id = 1") }
    path = signature_file
    stored = row["rechnungstext"].to_s
    rechnungskopf = row["rechnungskopf"].to_s
    rezeptkopf = row["rezeptkopf"].to_s
    {
      "titel" => row["titel"].to_s,
      "fach" => row["fach"].to_s,
      "name" => row["name"].to_s,
      "vorname" => row["vorname"].to_s,
      "arztnummer" => row["arztnummer"].to_s,
      "adresse" => row["adresse"].to_s,
      "telefone" => row["telefone"].to_s.split("\n").map(&:strip).reject(&:empty?),
      "iban" => row["iban"].to_s,
      "bic" => row["bic"].to_s,
      "rechnungstext" => stored,
      "rechnung_vorlage" => stored.strip.empty? ? RECHNUNG_TEXT : stored,
      "rechnungskopf" => rechnungskopf,
      "rechnungskopf_vorlage" => rechnungskopf.strip.empty? ? HEAD_TEXT["rechnungskopf"] : rechnungskopf,
      "rezeptkopf" => rezeptkopf,
      "rezeptkopf_vorlage" => rezeptkopf.strip.empty? ? HEAD_TEXT["rezeptkopf"] : rezeptkopf,
      "standardfaktor" => row["standardfaktor"].nil? || row["standardfaktor"].to_i <= 0 ? "" : format_faktor(row["standardfaktor"]),
      "signature" => !path.nil?,
      "signature_mtime" => path ? File.mtime(path).to_i : nil
    }
  end

  # Replaces the practice identity. The signature file and the invoice text are left as they are.
  # IBAN and BIC change only when the request carries those keys, so an older save cannot clear them.
  def save_practice(data)
    telefone = data["telefone"]
    phones = telefone.is_a?(Array) ? telefone.map { |phone| clip(phone, 40) }.reject(&:empty?) : []
    assigns = {
      "titel" => clip(data["titel"], 80),
      "fach" => clip(data["fach"], 120),
      "name" => clip(data["name"], 120),
      "vorname" => clip(data["vorname"], 80),
      "arztnummer" => clip(data["arztnummer"], 40),
      "adresse" => clip(data["adresse"], 500),
      "telefone" => phones.join("\n")
    }
    assigns["iban"] = blank_nil(normalize_iban(data["iban"])) if data.key?("iban")
    assigns["bic"] = blank_nil(normalize_bic(data["bic"])) if data.key?("bic")
    sets = assigns.keys.map { |key| "#{key} = ?" }.join(", ")
    lock { |db| db.execute("UPDATE practice SET #{sets} WHERE id = 1", assigns.values) }
    practice_hash
  end

  # Own letterhead, or nothing. Nothing prints the built-in lines. The column is one of HEAD_TEXT.
  def save_head_text(column, data)
    raise ArgumentError, "Unbekannter Kopf" unless HEAD_TEXT.key?(column)
    raw = clean(data["text"]).gsub("\r\n", "\n").strip
    raw = "" if raw == HEAD_TEXT[column]
    raise ArgumentError, "Der Text ist zu lang." if raw.length > 400
    lock { |db| db.execute("UPDATE practice SET #{column} = ? WHERE id = 1", [raw.empty? ? nil : raw]) }
    practice_hash
  end

  # Own wording for the invoice, or nothing. Nothing prints the built-in greeting.
  def save_invoice_text(data)
    raw = clean(data["text"]).gsub("\r\n", "\n")
    raw = "" if raw == RECHNUNG_TEXT
    raise ArgumentError, "Der Text ist zu lang." if raw.length > 800
    lock { |db| db.execute("UPDATE practice SET rechnungstext = ? WHERE id = 1", [raw.empty? ? nil : raw]) }
    practice_hash
  end

  def blank_nil(value)
    value.to_s.empty? ? nil : value
  end

  # Spaces are ignored. Empty is allowed. A stored IBAN has no spaces.
  def normalize_iban(value)
    raw = clean(value).gsub(/\s+/, "").upcase
    return "" if raw.empty?
    raise ArgumentError, "Die IBAN ist nicht gültig." unless iban_ok?(raw)
    raw
  end

  # Two letters, two check digits, then the account. The check digits must match.
  def iban_ok?(raw)
    return false unless raw.match?(/\A[A-Z]{2}\d{2}[A-Z0-9]{11,30}\z/)
    moved = raw[4..] + raw[0, 4]
    digits = moved.chars.map { |char| char.match?(/[A-Z]/) ? (char.ord - 55).to_s : char }.join
    rest = 0
    digits.each_char { |digit| rest = (rest * 10 + digit.to_i) % 97 }
    rest == 1
  end

  # Empty is allowed. Eight or eleven letters and digits, without spaces.
  def normalize_bic(value)
    raw = clean(value).gsub(/\s+/, "").upcase
    return "" if raw.empty?
    raise ArgumentError, "Die BIC hat acht oder elf Stellen." unless raw.match?(/\A[A-Z]{4}[A-Z]{2}[A-Z0-9]{2}([A-Z0-9]{3})?\z/)
    raw
  end

  # Empty stores no standard, and charging then uses factor 1. A number is stored in thousandths.
  def save_standard_faktor(data)
    raw = clean(data["faktor"])
    ts = raw.empty? ? nil : parse_faktor(raw)
    lock { |db| db.execute("UPDATE practice SET standardfaktor = ? WHERE id = 1", [ts]) }
    practice_hash
  end

  # The first file named unterschrift.* in data/, or nil.
  def signature_file
    Dir[File.join(DATA, "unterschrift.*")].find { |path| File.file?(path) }
  end

  # Sniffs the magic bytes. The type claimed by the browser is not trusted.
  def image_ext(body)
    bytes = body.dup.force_encoding(Encoding::ASCII_8BIT)
    return "png" if bytes.start_with?([0x89, 0x50, 0x4E, 0x47].pack("C*"))
    return "jpg" if bytes.byteslice(0, 3) == [0xFF, 0xD8, 0xFF].pack("C*")
    return "gif" if bytes.start_with?("GIF8".b)
    return "webp" if bytes.byteslice(0, 4) == "RIFF".b && bytes.byteslice(8, 4) == "WEBP".b
    nil
  end

  # Replaces any previous signature file.
  def save_signature(req)
    body = raw_body(req)
    ext = image_ext(body)
    raise ArgumentError, "Die Unterschrift muss ein Bild sein" unless ext
    Dir[File.join(DATA, "unterschrift.*")].each { |path| File.delete(path) }
    File.binwrite(File.join(DATA, "unterschrift.#{ext}"), body)
    practice_hash
  end

  # Sends the signature image, or 404 when none is stored.
  def send_signature(res)
    path = signature_file
    unless path
      res.status = 404
      res["Content-Type"] = "text/plain; charset=utf-8"
      res.body = "Keine Unterschrift"
      return
    end
    type = { ".png" => "image/png", ".jpg" => "image/jpeg", ".gif" => "image/gif", ".webp" => "image/webp" }[File.extname(path)] || "application/octet-stream"
    res.status = 200
    res["Content-Type"] = type
    res["Cache-Control"] = "no-store"
    res.body = File.binread(path)
  end

  # Files of one chart, newest first. The path stays on the server.
  def files_for(person_id)
    person_row(person_id)
    rows = lock { |db| db.execute("SELECT * FROM file WHERE person_id = ? ORDER BY created DESC, id DESC", [person_id]) }
    rows.map { |row| file_hash(row) }
  end

  # File metadata for the browser. path is omitted.
  def file_hash(row)
    {
      "id" => row["id"],
      "name" => row["name"],
      "mime" => row["mime"].to_s,
      "translation" => row["translation"].to_s,
      "created" => row["created"],
      "entry_id" => row["entry_id"]
    }
  end

  # One file's metadata, or an error when the id is unknown.
  def file_meta(id)
    row = lock { |db| db.get_first_row("SELECT * FROM file WHERE id = ?", [id]) }
    raise ArgumentError, "Datei nicht gefunden" unless row
    file_hash(row)
  end

  # Stores the bytes at dateien/<id>, without the original extension, and adds a chart row of kind DA.
  def add_upload(person_id, req)
    person_row(person_id)
    body = raw_body(req)
    name = clip(req["x-filename"], 180)
    name = "datei" if name.empty?
    mime = clean(req.content_type).split(";").first[0, 80]
    fid = nil
    eid = nil
    lock do |db|
      db.execute(
        "INSERT INTO file (person_id, name, mime, translation, created) VALUES (?, ?, ?, '', ?)",
        [person_id, name, mime, now_stamp]
      )
      fid = db.last_insert_row_id
      path = File.join(DATEIEN, fid.to_s)
      File.binwrite(path, body)
      db.execute("UPDATE file SET path = ? WHERE id = ?", [path, fid])
      eid = insert_entry(db, person_id, "DA", "Datei", name, fid)
      db.execute("UPDATE file SET entry_id = ? WHERE id = ?", [eid, fid])
    end
    {
      "file" => file_meta(fid),
      "entry" => entry_hash(lock { |db| db.get_first_row("SELECT * FROM entry WHERE id = ?", [eid]) })
    }
  end

  # Saves a reading on the file. into_chart also copies that reading into a Befund for today.
  def patch_file(id, data)
    row = lock { |db| db.get_first_row("SELECT * FROM file WHERE id = ?", [id]) }
    raise ArgumentError, "Datei nicht gefunden" unless row
    if data.key?("translation")
      text = clip(data["translation"], 100_000)
      lock do |db|
        db.execute("UPDATE file SET translation = ? WHERE id = ?", [text, id])
        write_german_line(db, row, text)
      end
    end
    if data["into_chart"] && !clean(data["translation"]).empty?
      text = clip(data["translation"], 100_000)
      lock { |db| insert_entry(db, row["person_id"], "B", "Befund", text) }
    end
    result = { "file" => file_meta(id) }
    if data.key?("translation") && row["entry_id"]
      entry = lock { |db| db.get_first_row("SELECT * FROM entry WHERE id = ?", [row["entry_id"]]) }
      result["entry"] = entry_hash(entry) if entry
    end
    if data["into_chart"]
      result["chart"] = chart_for(row["person_id"])
    end
    result
  end

  # Sends the working copy. A broken RTF trailer is cut in that copy first. The nosniff header stays on.
  def send_file_raw(res, id)
    row, full = stored_file(id)
    sanitize_stored_rtf(row, full)
    res.status = 200
    res["Content-Type"] = row["mime"].to_s.empty? ? "application/octet-stream" : row["mime"]
    res["Cache-Control"] = "no-store"
    res["X-Content-Type-Options"] = "nosniff"
    res.body = File.binread(full)
  end

  # Gives the working copy to the local desktop only for a browser on this machine.
  # The path is under dateien/.
  def open_stored_file(id)
    row, path = stored_file(id)
    sanitize_stored_rtf(row, path)
    {
      "opened" => workstation_here? ? reveal_desktop(path) : false,
      "holen" => "/api/files/#{id}/raw",
      "name" => row["name"].to_s
    }
  end

  # Replaces the working copy. The path stays inside dateien/.
  def replace_stored_file(id, req)
    _row, path = stored_file(id)
    write_file_bytes(path, raw_body(req))
    { "ok" => true }
  end

  # Cuts a broken RTF trailer from the working copy and writes it back. A failure leaves the file unchanged.
  def sanitize_stored_rtf(row, path)
    mime = row["mime"].to_s.downcase
    return unless mime.include?("rtf") || path.downcase.end_with?(".rtf")
    raw = File.binread(path)
    cleaned = LaborKatalog.sanitize_rtf(raw)
    return if cleaned == raw
    tmp = path + ".neu"
    File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(cleaned) }
    File.rename(tmp, path)
  rescue StandardError
    FileUtils.rm_f(path + ".neu")
  end

  # Resolves a file id. The path must sit inside dateien/ and must not contain NUL or a newline.
  def stored_file(id)
    row = lock { |db| db.get_first_row("SELECT * FROM file WHERE id = ?", [id]) }
    full = row && row["path"] ? File.expand_path(row["path"].to_s) : ""
    root = File.expand_path(DATEIEN) + File::SEPARATOR
    raise ArgumentError, "Datei nicht gefunden" if full.include?("\0") || full.include?("\n")
    raise ArgumentError, "Datei nicht gefunden" unless full.start_with?(root) && File.file?(full)
    [row, full]
  end

  # /usr/bin, Homebrew, then PATH. PRAXIS_UNZIP and the same pattern override one name.
  def program(name)
    key = "PRAXIS_#{name.tr("-", "_").upcase}"
    given = ENV[key].to_s
    return given if !given.empty? && File.executable?(given)
    dirs = ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"] + ENV["PATH"].to_s.split(File::PATH_SEPARATOR)
    dirs.each do |dir|
      candidate = File.join(dir, name)
      return candidate if File.executable?(candidate) && File.file?(candidate)
    end
    nil
  end

  def require_program(name)
    found = program(name)
    raise ArgumentError, "Programm fehlt: #{name}" unless found
    found
  end

  # Runs xdg-open, or open on a Mac. PRAXIS_NO_OPEN skips it. A launcher still running after two seconds counts as opened.
  def reveal_desktop(path)
    return false if ENV["PRAXIS_NO_OPEN"] == "1"
    if RUBY_PLATFORM.include?("darwin")
      pid = spawn("open", path, [:out, :err] => File::NULL)
      Process.detach(pid)
      return true
    end
    bin = program("xdg-open")
    return false unless bin
    env = ENV.to_h
    env["DISPLAY"] = ":0" if env["DISPLAY"].to_s.empty?
    runtime = "/run/user/#{Process.uid}"
    env["XDG_RUNTIME_DIR"] ||= runtime if Dir.exist?(runtime)
    bus = File.join(runtime, "bus")
    env["DBUS_SESSION_BUS_ADDRESS"] ||= "unix:path=#{bus}" if File.exist?(bus)
    pid = spawn(env, bin, path, [:out, :err] => File::NULL)
    begin
      Timeout.timeout(2) do
        _pid, status = Process.wait2(pid)
        status.success?
      end
    rescue Timeout::Error
      Process.detach(pid)
      true
    end
  rescue StandardError
    false
  end

  # Stem names of the .odt files in vorlagen/.
  def templates
    Dir[File.join(VORLAGEN, "*.odt")].sort.map { |path| File.basename(path, ".odt") }
  end

  # Practice-wide addresses for letters. A row is not a person and does not open a chart.
  def list_adressen(query)
    needle = fold_text(query)
    rows = lock { |db| db.execute("SELECT * FROM adresse") }
    rows.select! do |row|
      next true if needle.empty?
      blob = fold_text([
        row["name"], row["anrede"], row["zusatz"], row["strasse"],
        row["plz"], row["ort"], row["telefon"], ADRESS_ART[row["art"].to_s]
      ].join(" "))
      blob.include?(needle)
    end
    rows.sort_by { |row| [fold_text(row["name"]), row["id"].to_i] }.map { |row| adresse_hash(row) }
  end

  # Inserts one address. The open chart and last_patient_id stay as they are.
  def add_adresse(data)
    fields = adress_fields(data, true)
    id = nil
    lock do |db|
      cols = fields.keys
      db.execute(
        "INSERT INTO adresse (#{cols.join(", ")}) VALUES (#{cols.map { "?" }.join(", ")})",
        cols.map { |key| fields[key] }
      )
      id = db.last_insert_row_id
    end
    adresse_full(id)
  end

  # Replaces the fields that were sent. An unknown id is refused.
  def patch_adresse(id, data)
    adresse_row(id)
    fields = adress_fields(data, false)
    unless fields.empty?
      lock do |db|
        sets = fields.keys.map { |key| "#{key} = ?" }.join(", ")
        db.execute("UPDATE adresse SET #{sets} WHERE id = ?", fields.values + [id])
      end
    end
    adresse_full(id)
  end

  # Removes the address. Letters already written keep their file. The pointer on those rows is cleared.
  def delete_adresse(id)
    adresse_row(id)
    lock do |db|
      db.execute("UPDATE letter SET adresse_id = NULL WHERE adresse_id = ?", [id])
      db.execute("DELETE FROM adresse WHERE id = ?", [id])
    end
    { "ok" => true }
  end

  def adresse_full(id)
    adresse_hash(adresse_row(id))
  end

  def adresse_row(id)
    row = lock { |db| db.get_first_row("SELECT * FROM adresse WHERE id = ?", [id]) }
    raise ArgumentError, "Adresse nicht gefunden." unless row
    row
  end

  def adresse_hash(row)
    art = row["art"].to_s
    {
      "id" => row["id"],
      "art" => art,
      "art_label" => ADRESS_ART[art] || "Sonstige",
      "anrede" => row["anrede"].to_s,
      "name" => row["name"].to_s,
      "zusatz" => row["zusatz"].to_s,
      "strasse" => row["strasse"].to_s,
      "plz" => row["plz"].to_s,
      "ort" => row["ort"].to_s,
      "telefon" => row["telefon"].to_s,
      "notiz" => row["notiz"].to_s
    }
  end

  # art is arzt, versicherung or sonst. The German labels are accepted too.
  def adress_art(value)
    key = clean(value).downcase
    key = "sonst" if key.empty? || key == "sonstige"
    raise ArgumentError, "Art ist Arzt, Versicherung oder Sonstige." unless ADRESS_ART.key?(key)
    key
  end

  # Empty is allowed. A filled code has four or five digits.
  def adress_plz(value)
    plz = clean(value).gsub(/\s/, "")
    return "" if plz.empty?
    raise ArgumentError, "Die PLZ hat vier oder fünf Stellen." unless plz.match?(/\A\d{4,5}\z/)
    plz
  end

  # Fields for insert or patch. On create every column is set. On patch only keys that were sent.
  def adress_fields(data, creating)
    fields = {}
    if creating || data.key?("art")
      fields["art"] = adress_art(data["art"])
    end
    if creating || data.key?("name")
      name = clip(data["name"], 80)
      raise ArgumentError, "Name fehlt." if name.empty?
      fields["name"] = name
    end
    { "anrede" => 40, "zusatz" => 80, "strasse" => 120, "telefon" => 40, "notiz" => 200 }.each do |key, max|
      next unless creating || data.key?(key)
      fields[key] = clip(data[key], max)
    end
    fields["plz"] = adress_plz(data["plz"]) if creating || data.key?("plz")
    fields["ort"] = clip(data["ort"], 80) if creating || data.key?("ort")
    fields
  end

  # The address chosen for this letter, or nil when the letter goes to the patient.
  def letter_adresse(data)
    raw = data["adresse_id"]
    return nil if raw.nil? || raw.to_s.strip.empty?
    begin
      id = Integer(raw)
    rescue ArgumentError, TypeError
      raise ArgumentError, "Adresse nicht gefunden."
    end
    adresse_hash(adresse_row(id))
  end

  # Fills a template and stores it under briefe/. The chart row is only the file name.
  # The letter text, including a Hungarian draft, stays in the file.
  # adresse_id chooses a window address. It does not change the open chart.
  def add_letter(person_id, data)
    patient = person_full(person_id)
    vorlage = File.basename(clean(data["vorlage"]))
    raise ArgumentError, "Vorlage fehlt" if vorlage.empty?
    template = File.join(VORLAGEN, vorlage + ".odt")
    raise ArgumentError, "Vorlage nicht gefunden" unless File.file?(template)
    betreff = clip(data["betreff"], 200)
    betreff = vorlage if betreff.empty?
    text = clip(data["text"], 100_000)
    text = with_hungarian(text) if data["ungarisch"] == true || data["ungarisch"] == 1
    practice = practice_hash
    adresse = letter_adresse(data)
    lid = nil
    lock do |db|
      db.execute(
        "INSERT INTO letter (person_id, vorlage, betreff, body, datum, adresse_id) VALUES (?, ?, ?, ?, ?, ?)",
        [person_id, vorlage, betreff, text, today, adresse && adresse["id"]]
      )
      lid = db.last_insert_row_id
    end
    path = File.join(BRIEFE, letter_filename(patient, today, lid))
    begin
      fill_odt(template, path, letter_vars(patient, practice, betreff, text, adresse))
    rescue StandardError
      lock { |db| db.execute("DELETE FROM letter WHERE id = ?", [lid]) }
      raise
    end
    eid = nil
    lock do |db|
      db.execute("UPDATE letter SET path = ? WHERE id = ?", [path, lid])
      eid = insert_entry(db, person_id, "BRIEF", "Brief", File.basename(path), lid)
      db.execute("UPDATE letter SET entry_id = ? WHERE id = ?", [eid, lid])
    end
    {
      "id" => lid,
      "path" => path,
      "name" => File.basename(path),
      "holen" => "/api/letters/#{lid}/datei",
      "opened" => false,
      "entry" => entry_hash(lock { |db| db.get_first_row("SELECT * FROM entry WHERE id = ?", [eid]) })
    }
  end

  # Nachname_Vorname_yyyy-mm-dd_id.odt. The id keeps two letters on the same day apart.
  def letter_filename(patient, datum, lid)
    stem = [patient["nachname"], patient["vorname"]].map { |part| clean(part) }.reject(&:empty?).join("_")
    stem = stem.gsub(/[^\p{L}\p{N}._-]+/, "_").gsub(/_+/, "_").sub(/\A_+/, "").sub(/_+\z/, "")
    stem = "Brief" if stem.empty?
    "#{stem}_#{datum}_#{lid}.odt"
  end

  # The browser on this machine may ask the server to open the file. A remote browser must not.
  # PRAXIS_CLIENT_REMOTE=1 treats every request as remote, for a probe.
  def workstation_here?
    return false if ENV["PRAXIS_CLIENT_REMOTE"] == "1"
    ip = @req && @req.peeraddr ? @req.peeraddr[3].to_s : ""
    ip == "127.0.0.1" || ip == "::1"
  end

  # A stored path that is a real file inside root. Anything else is refused.
  def path_inside(root, path)
    full = File.expand_path(path.to_s)
    base = File.expand_path(root) + File::SEPARATOR
    raise ArgumentError, "Datei nicht gefunden" if full.include?("\0") || full.include?("\n")
    raise ArgumentError, "Datei nicht gefunden" unless full.start_with?(base) && File.file?(full)
    full
  end

  # Writes bytes beside the file and renames them into place.
  def write_file_bytes(path, body)
    tmp = path + ".neu"
    File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(body) }
    File.rename(tmp, path)
  rescue StandardError
    FileUtils.rm_f(path + ".neu")
    raise
  end

  # Sends one stored letter. The workstation saves its own copy and opens that.
  def send_letter_file(res, id)
    path = letter_file_path(id)
    send_bytes(res, File.binread(path), "application/vnd.oasis.opendocument.text", File.basename(path))
  end

  # Replaces the stored letter with the copy edited on the workstation.
  def replace_letter_file(id, req)
    path = letter_file_path(id)
    write_file_bytes(path, raw_body(req))
    { "ok" => true }
  end

  def letter_file_path(id)
    row = lock { |db| db.get_first_row("SELECT path FROM letter WHERE id = ?", [id]) }
    raise ArgumentError, "Brief fehlt" unless row && row["path"].to_s != ""
    path_inside(BRIEFE, row["path"])
  end

  # Sends one template from vorlagen/. The name is the file stem.
  def send_template_file(res, name)
    path = template_path(name)
    send_bytes(res, File.binread(path), "application/vnd.oasis.opendocument.text", File.basename(path))
  end

  # Replaces one template. A name outside vorlagen/ is refused, and a new name is not created.
  def replace_template_file(name, req)
    path = template_path(name)
    write_file_bytes(path, raw_body(req))
    { "ok" => true }
  end

  # File stem of a template. Letters may be German. A path that climbs out is refused.
  def template_stem(raw)
    name = raw.to_s
    name = WEBrick::HTTPUtils.unescape(name) if name.include?("%")
    name = name.dup.force_encoding(Encoding::UTF_8)
    raise ArgumentError, "Vorlage fehlt" unless name.valid_encoding?
    name = File.basename(name).sub(/\.odt\z/i, "")
    raise ArgumentError, "Vorlage fehlt" if name.empty? || name == "." || name == ".."
    raise ArgumentError, "Vorlage fehlt" unless name.match?(/\A[\p{L}\p{N} _.()-]{1,80}\z/)
    name
  end

  def template_path(name)
    stem = template_stem(name)
    path = File.expand_path(stem + ".odt", VORLAGEN)
    root = File.expand_path(VORLAGEN) + File::SEPARATOR
    raise ArgumentError, "Vorlage nicht gefunden" unless path.start_with?(root) && File.file?(path)
    path
  end

  # Sends bytes. The name is a file name, not a path.
  def send_bytes(res, bytes, type, filename)
    safe = File.basename(filename.to_s).gsub(/[\r\n"]/, "")
    res.status = 200
    res["Content-Type"] = type
    res["Cache-Control"] = "no-store"
    res["X-Content-Type-Options"] = "nosniff"
    res["Content-Disposition"] = %(attachment; filename="#{safe}")
    res.body = bytes
  end

  # Opens the stored letter only when the browser is on this same machine.
  # A remote browser gets the address and opens the file through praxis lokal.
  def open_letter(id)
    path = letter_file_path(id)
    {
      "opened" => workstation_here? ? reveal_office(path) : false,
      "holen" => "/api/letters/#{id}/datei",
      "name" => File.basename(path)
    }
  end

  # Appends a Hungarian draft. Translation stays on this machine. An empty letter is left as it is.
  def with_hungarian(text)
    source = text.to_s.strip
    return text if source.empty?
    [source, "Magyarul", translate_hu(source)].join("\n\n")
  end

  # Runs the local Argos models, German to Hungarian, pivoting through English when no direct model exists.
  def translate_hu(text)
    translate_text(
      text, "de", "hu",
      "Ungarisch ist auf diesem Rechner noch nicht bereit.",
      "Die ungarische Fassung ist nicht entstanden.",
      "Die ungarische Fassung hat zu lange gebraucht."
    )
  end

  # Hungarian letter to a German draft. The letter text is not sent off this machine.
  def translate_to_de(text)
    translate_text(
      text, "hu", "de",
      "Deutsch ist auf diesem Rechner noch nicht bereit.",
      "Die deutsche Fassung ist nicht entstanden.",
      "Die deutsche Fassung hat zu lange gebraucht."
    )
  end

  # One local translation. src and dst are de, en or hu. stderr from the model stays off the response.
  def translate_text(text, src, dst, missing, empty, slow)
    py = File.join(APP, "uebersetzung", "bin", "python")
    script = File.join(APP, "uebersetzung", "hu.py")
    raise ArgumentError, missing unless File.executable?(py) && File.file?(script)
    out = err = status = nil
    Timeout.timeout(120) do
      out, err, status = Open3.capture3(py, script, src, dst, stdin_data: text.to_s)
    end
    raise ArgumentError, empty unless status.success? && !out.to_s.strip.empty?
    out.strip
  rescue Timeout::Error
    raise ArgumentError, slow
  end

  # Reads a stored letter and saves the German draft on the file and on its chart row, under the file name.
  def translate_file_de(id)
    row, path = stored_file(id)
    source = read_letter_text(row, path)
    raise ArgumentError, "In dem Brief steht kein Text." if source.empty?
    german = translate_to_de(clip(source, 100_000))
    raise ArgumentError, "Die deutsche Fassung ist nicht entstanden." if german == source
    german = clip(german, 100_000)
    lock do |db|
      db.execute("UPDATE file SET translation = ? WHERE id = ?", [german, id])
      write_german_line(db, row, german)
    end
    result = { "file" => file_meta(id) }
    if row["entry_id"]
      entry = lock { |db| db.get_first_row("SELECT * FROM entry WHERE id = ?", [row["entry_id"]]) }
      result["entry"] = entry_hash(entry) if entry
    end
    result
  end

  # Chart row of the file: the file name, then the heading Deutsch, then the draft.
  # An empty draft leaves only the file name.
  def write_german_line(db, row, german)
    return unless row["entry_id"]
    db.execute(
      "UPDATE entry SET text = ? WHERE id = ? AND person_id = ?",
      [german_under(row["name"], german), row["entry_id"], row["person_id"]]
    )
  end

  def german_under(name, german)
    title = clean(name)
    title = "Brief" if title.empty?
    body = german.to_s.strip
    return title if body.empty?
    [title, "Deutsch", body].join("\n\n")
  end

  # Text of an uploaded letter. ODT and DOCX are read here. PDF, Word, RTF, text and images use the lab reader.
  def read_letter_text(row, path)
    name = row["name"].to_s
    mime = row["mime"].to_s
    case office_kind(path, mime, name)
    when :odt then office_plain(path, "content.xml")
    when :docx then office_plain(path, "word/document.xml")
    else
      reading = mime_for_reading(mime, name)
      if LaborKatalog.kind(path, reading) == :other
        raise ArgumentError, "Diesen Brief kann ich nicht lesen. PDF, Word, LibreOffice, RTF, Text oder ein Bild gehen."
      end
      LaborKatalog.extract(path, reading, ocr_home: File.join(APP, "ocr"), lang: scan_lang).to_s.strip
    end
  end

  # hun+deu when the Hungarian recognition data is installed. Lab reading does not use this.
  def scan_lang
    File.file?(File.join(APP, "ocr", "tessdata", "hun.traineddata")) ? "hun+deu" : "deu"
  end

  def office_kind(path, mime, name)
    lowered = mime.to_s.downcase
    filename = name.to_s.downcase
    return :odt if lowered.include?("opendocument.text") || filename.end_with?(".odt")
    return :docx if lowered.include?("wordprocessingml") || filename.end_with?(".docx")
    return nil unless lowered.include?("zip") || lowered == "application/octet-stream"
    names = zip_names(path)
    return :odt if names.include?("content.xml")
    return :docx if names.include?("word/document.xml")
    nil
  end

  def office_plain(path, inner)
    Dir.mktmpdir("praxis-brief") do |dir|
      ok = system(require_program("unzip"), "-qq", "-o", path, inner, "-d", dir)
      file = File.join(dir, inner)
      raise ArgumentError, "Der Brief ließ sich nicht lesen." unless ok && File.file?(file)
      xml_plain(File.read(file, encoding: "UTF-8"))
    end
  end

  def zip_names(path)
    out, status = Open3.capture2(require_program("unzip"), "-Z1", path)
    return [] unless status.success?
    out.lines.map { |line| line.strip }
  rescue StandardError
    []
  end

  def xml_plain(xml)
    text = xml.to_s.dup
    text.gsub!(%r{<text:line-break\s*/>}, "\n")
    text.gsub!(%r{<w:br[^>]*/>}, "\n")
    text.gsub!("</text:p>", "\n")
    text.gsub!("</w:p>", "\n")
    text.gsub!(/<[^>]+>/, "")
    text.gsub!("&lt;", "<")
    text.gsub!("&gt;", ">")
    text.gsub!("&quot;", '"')
    text.gsub!("&apos;", "'")
    text.gsub!("&amp;", "&")
    text.gsub!(/[ \t]+\n/, "\n")
    text.gsub!(/\n{3,}/, "\n\n")
    text.strip
  end

  # The stored copy has no extension, so a generic MIME type is read from the original file name.
  def mime_for_reading(mime, name)
    lowered = mime.to_s.downcase
    return lowered unless lowered.empty? || lowered == "application/octet-stream"
    ext = File.extname(name.to_s).downcase
    {
      ".pdf" => "application/pdf",
      ".txt" => "text/plain",
      ".rtf" => "application/rtf",
      ".doc" => "application/msword",
      ".jpg" => "image/jpeg",
      ".jpeg" => "image/jpeg",
      ".png" => "image/png",
      ".tif" => "image/tiff",
      ".tiff" => "image/tiff",
      ".gif" => "image/gif",
      ".bmp" => "image/bmp",
      ".webp" => "image/webp"
    }[ext] || lowered
  end

  # Reads a file of visits captured away from the desk. Does not change the open chart.
  # A new person is created only when no chart has the same name, town and birth date.
  def import_besuche(data)
    list = data.is_a?(Hash) ? data["besuche"] : nil
    raise ArgumentError, "Keine Besuche." unless list.is_a?(Array) && !list.empty?
    done = 0
    created = 0
    offen = []
    list.each_with_index do |visit, index|
      next unless visit.is_a?(Hash)
      begin
        created += 1 if import_one_besuch(visit) == :neu
        done += 1
      rescue ArgumentError => e
        offen << { "index" => index, "grund" => e.message }
      end
    end
    { "uebernommen" => done, "neu" => created, "offen" => offen }
  end

  # One visit. Returns :neu when a chart was created.
  def import_one_besuch(visit)
    nummer = clean(visit["nummer"])
    neu = visit["neu"] == true || visit["neu"] == 1
    art = clean(visit["art"]).downcase
    art = "besuch" if art == "hausbesuch"
    raise ArgumentError, "Ordi oder Besuch." unless %w[ordi besuch].include?(art)
    tag = parse_date(visit["tag"] || visit["datum"])
    raise ArgumentError, "Datum fehlt." if tag.nil?
    uhr = visit_clock(visit["uhrzeit"])
    sv = clean(visit["versicherung"]).gsub(/[\s-]/, "")
    raise ArgumentError, "Die Versicherungsnummer hat zehn Stellen." unless sv.match?(/\A\d{10}\z/)
    raise ArgumentError, "Die Patientennummer hat höchstens fünf Stellen." if !nummer.empty? && !nummer.match?(/\A\d{1,5}\z/)
    plz = visit_plz(visit)
    street = visit_street(visit)
    found = lock { |db| visit_person(db, nummer, visit) }
    made = :da
    if found.nil?
      raise ArgumentError, "Die Akte fehlt." unless neu
      raise ArgumentError, "Nachname fehlt." if clean(visit["nachname"]).empty?
      raise ArgumentError, "Wohnort fehlt." if clean(visit["wohnort"]).empty?
      found = create_patient({
        "nachname" => visit["nachname"],
        "vorname" => visit["vorname"],
        "geburtsdatum" => visit["geburtsdatum"],
        "wohnort" => visit["wohnort"],
        "strasse" => street,
        "plz" => plz,
        "versicherung" => sv,
        "species" => "mensch",
        "remember" => false
      }, false)
      made = :neu
    else
      lock do |db|
        db.execute("UPDATE person SET versicherung = ? WHERE id = ? AND ifnull(versicherung, '') = ''", [sv, found["id"]])
        db.execute("UPDATE person SET plz = ? WHERE id = ? AND ifnull(plz, '') = '' AND ? != ''", [plz, found["id"], plz])
        db.execute("UPDATE person SET strasse = ? WHERE id = ? AND ifnull(strasse, '') = '' AND ? != ''", [street, found["id"], street])
      end
    end
    pid = found["id"]
    header = "#{art == "ordi" ? "Ordi" : "Besuch"} #{uhr}"
    info = [header, clean(visit["info"])].reject(&:empty?).join("\n\n")
    pieces = [
      ["A", "Anamnese", visit["anamnese"]],
      ["B", "Befund", visit["befund"]],
      ["D", "Diagnose", visit["diagnose"]],
      ["PR", "Procedere", visit["procedere"]],
      ["I", "Info", info]
    ]
    lock do |db|
      pieces.each do |kind, label, body|
        text = clean(body)
        next if text.empty?
        insert_entry(db, pid, kind, label, text, nil, tag, 0)
      end
    end
    made
  end

  # Street at most 30 characters, house number at most 10. They share the one street column.
  def visit_street(visit)
    street = clean(visit["strasse"])
    number = clean(visit["hausnummer"])
    raise ArgumentError, "Die Straße hat höchstens 30 Stellen." if street.length > 30
    raise ArgumentError, "Die Hausnummer hat höchstens 10 Stellen." if number.length > 10
    [street, number].reject(&:empty?).join(" ")
  end

  # Empty is allowed. A filled code has four or five digits.
  def visit_plz(visit)
    plz = clean(visit["plz"]).gsub(/\s/, "")
    return "" if plz.empty?
    raise ArgumentError, "Die PLZ hat vier oder fünf Stellen." unless plz.match?(/\A\d{4,5}\z/)
    plz
  end

  # Chart by number, otherwise by the four identity fields.
  def visit_person(db, nummer, visit)
    if nummer.match?(/\A\d+\z/)
      row = db.get_first_row("SELECT * FROM person WHERE nummer = ? AND ist_patient = 1", [nummer.to_i])
      return row if row
    end
    nach = clean(visit["nachname"])
    return nil if nach.empty?
    geb = parse_date_soft(visit["geburtsdatum"])
    owner = identity_owner(db, nach, clean(visit["vorname"]), clean(visit["wohnort"]), geb, nil)
    return nil unless owner
    db.get_first_row("SELECT * FROM person WHERE id = ?", [owner])
  end

  # 14:30, 14.30 and 1430 all become 14:30.
  def visit_clock(value)
    text = clean(value).gsub(".", ":").gsub(/\s+uhr\z/i, "")
    if (m = text.match(/\A(\d{1,2}):(\d{2})\z/))
      hour = m[1].to_i
      minute = m[2].to_i
    elsif (m = text.match(/\A(\d{2})(\d{2})\z/))
      hour = m[1].to_i
      minute = m[2].to_i
    else
      raise ArgumentError, "Uhrzeit fehlt."
    end
    raise ArgumentError, "Uhrzeit fehlt." if hour > 23 || minute > 59
    format("%02d:%02d", hour, minute)
  end

  # Placeholder values for the template. Newlines in the body become separate paragraphs.
  # Without an address, the window is the patient. With one, the window is that address
  # and the patient name and birth date stay in GEBOREN, on the right.
  def letter_vars(patient, practice, betreff, text, adresse = nil)
    phones = practice["telefone"].join(" · ")
    arzt = [practice["titel"], practice["vorname"], practice["name"]].reject(&:empty?).join(" ")
    name, anschrift, geboren = letter_window(patient, adresse)
    nummer = practice["arztnummer"].to_s
    {
      "TITEL" => practice["titel"],
      "VORNAME" => practice["vorname"],
      "NAME" => practice["name"],
      "FACH" => practice["fach"],
      "ARZT" => arzt,
      "ARZTNUMMER" => nummer.empty? ? "" : "Arztnummer #{nummer}",
      "ADRESSE" => practice["adresse"],
      "TELEFON" => phones,
      "DATUM" => show_date(today),
      "PATIENT" => name,
      "GEBOREN" => geboren,
      "ANSCHRIFT" => anschrift,
      "BETREFF" => betreff,
      "TEXT" => text
    }
  end

  # Window lines and the right-hand patient line. The first postal line is PATIENT, the rest ANSCHRIFT.
  def letter_window(patient, adresse)
    patient_name = [patient["nachname"], patient["vorname"]].reject(&:empty?).join(", ")
    born = patient["geburtsdatum_anzeige"].to_s
    born_line = born.empty? ? "" : "geb. #{born}"
    if adresse.nil?
      place = [patient["plz"], patient["wohnort"]].reject(&:empty?).join(" ")
      anschrift = [patient["strasse"], place].reject(&:empty?).join("\n")
      return [patient_name, anschrift, born_line]
    end
    place = [adresse["plz"], adresse["ort"]].reject(&:empty?).join(" ")
    lines = [adresse["anrede"], adresse["name"], adresse["zusatz"], adresse["strasse"], place].reject(&:empty?)
    first = lines.shift.to_s
    geboren = [patient_name, born_line].reject(&:empty?).join(", ")
    [first, lines.join("\n"), geboren]
  end

  # Display and session bus for LibreOffice. A server started without them still reaches this screen.
  def office_env
    env = ENV.to_h
    env["DISPLAY"] = ":0" if env["DISPLAY"].to_s.empty?
    runtime = "/run/user/#{Process.uid}"
    env["XDG_RUNTIME_DIR"] ||= runtime if Dir.exist?(runtime)
    bus = File.join(runtime, "bus")
    env["DBUS_SESSION_BUS_ADDRESS"] ||= "unix:path=#{bus}" if File.exist?(bus)
    env
  end

  # Opens the letter in LibreOffice and does not wait for it. PRAXIS_NO_OPEN skips it.
  def reveal_office(path)
    return false if ENV["PRAXIS_NO_OPEN"] == "1"
    if RUBY_PLATFORM.include?("darwin") && File.directory?("/Applications/LibreOffice.app")
      pid = spawn("open", "-a", "LibreOffice", path)
      Process.detach(pid)
      true
    else
      bin = program("libreoffice") || program("soffice")
      return false unless bin
      pid = spawn(office_env, bin, "--nologo", path, [:out, :err] => File::NULL)
      Process.detach(pid)
      true
    end
  rescue StandardError
    false
  end

  # Writes Befundbericht and Kurzbrief only when those files are missing. An edited template is left alone.
  def ensure_templates
    %w[Befundbericht Kurzbrief].each do |name|
      path = File.join(VORLAGEN, "#{name}.odt")
      next if File.file?(path)
      write_template(path)
    end
  end

  # Puts the DIN 5008 page on a stock template. A file LibreOffice has saved already has a page size and stays.
  def refresh_stock_templates
    %w[Befundbericht Kurzbrief].each do |name|
      path = File.join(VORLAGEN, "#{name}.odt")
      next unless File.file?(path)
      styles = template_styles(path)
      next if styles.include?("font-face")
      next if styles.include?('style:name="Brief-Form-B"')
      write_template(path)
    end
  end

  # The styles part of one template, or an empty string when it cannot be read.
  def template_styles(path)
    Dir.mktmpdir("praxis-stil") do |dir|
      system(require_program("unzip"), "-q", "-o", path, "styles.xml", "-d", dir)
      file = File.join(dir, "styles.xml")
      return File.file?(file) ? File.read(file, encoding: "UTF-8") : ""
    end
  end

  # Builds a DIN 5008 Form B letter. The address field starts 45 mm from the top.
  def write_template(path)
    content = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:fo:1.0" office:version="1.3">
       <office:automatic-styles>
        <style:style style:name="AnschriftTabelle" style:family="table">
         <style:table-properties style:width="180mm" table:align="left"/>
        </style:style>
        <style:style style:name="AnschriftTabelle.L" style:family="table-column">
         <style:table-column-properties style:column-width="5mm"/>
        </style:style>
        <style:style style:name="AnschriftTabelle.A" style:family="table-column">
         <style:table-column-properties style:column-width="100mm"/>
        </style:style>
        <style:style style:name="AnschriftTabelle.B" style:family="table-column">
         <style:table-column-properties style:column-width="75mm"/>
        </style:style>
        <style:style style:name="AnschriftTabelle.1" style:family="table-row">
         <style:table-row-properties style:min-row-height="45mm"/>
        </style:style>
        <style:style style:name="AnschriftTabelle.A1" style:family="table-cell">
         <style:table-cell-properties fo:padding-top="14mm" fo:padding-left="5mm" fo:padding-right="2mm" style:vertical-align="top"/>
        </style:style>
        <style:style style:name="AnschriftTabelle.B1" style:family="table-cell">
         <style:table-cell-properties fo:padding-top="5mm" style:vertical-align="top"/>
        </style:style>
       </office:automatic-styles>
       <office:body>
        <office:text>
         <table:table table:name="Anschrift" table:style-name="AnschriftTabelle">
          <table:table-column table:style-name="AnschriftTabelle.L"/>
          <table:table-column table:style-name="AnschriftTabelle.A"/>
          <table:table-column table:style-name="AnschriftTabelle.B"/>
          <table:table-row table:style-name="AnschriftTabelle.1">
           <table:table-cell table:style-name="AnschriftTabelle.A1" office:value-type="string">
            <text:p text:style-name="Abstand"/>
           </table:table-cell>
           <table:table-cell table:style-name="AnschriftTabelle.A1" office:value-type="string">
            <text:p text:style-name="Abstand"/>
            <text:p text:style-name="Abstand"/>
            <text:p text:style-name="Abstand"/>
            <text:p text:style-name="Rueck">{{ARZT}}</text:p>
            <text:p text:style-name="Anschrift">{{PATIENT}}</text:p>
            <text:p text:style-name="Anschrift">{{ANSCHRIFT}}</text:p>
           </table:table-cell>
           <table:table-cell table:style-name="AnschriftTabelle.B1" office:value-type="string">
            <text:p text:style-name="Info">{{DATUM}}</text:p>
            <text:p text:style-name="Info">{{GEBOREN}}</text:p>
           </table:table-cell>
          </table:table-row>
         </table:table>
         <text:p text:style-name="Betreff">{{BETREFF}}</text:p>
         <text:p text:style-name="Standard">{{TEXT}}</text:p>
        </office:text>
       </office:body>
      </office:document-content>
    XML
    pack_parts(path, content)
  end

  # Unzips the template, replaces placeholders in content.xml, and zips a new file. The template is not modified.
  def fill_odt(template, dest, vars)
    Dir.mktmpdir("praxis-odt") do |dir|
      ok = system(require_program("unzip"), "-q", template, "-d", dir)
      raise ArgumentError, "Vorlage lässt sich nicht öffnen" unless ok
      %w[content.xml styles.xml].each do |name|
        file = File.join(dir, name)
        next unless File.file?(file)
        xml = File.read(file, encoding: "UTF-8")
        vars.each { |key, value| xml = replace_placeholder(xml, key, value) }
        File.write(file, xml)
      end
      pack_dir(dir, dest)
    end
  end

  # A placeholder that fills one paragraph becomes one paragraph per line, in that same style.
  # A placeholder LibreOffice has split is escaped as a single line so the XML stays intact.
  def replace_placeholder(xml, key, value)
    token = "{{#{key}}}"
    xml = xml.gsub(%r{<text:p\b([^>]*)>\{\{#{Regexp.escape(key)}\}\}</text:p>}) do
      style = Regexp.last_match(1)[/text:style-name="([^"]+)"/, 1] || "Standard"
      odt_lines(value, style)
    end
    xml.gsub(token, xml_escape(value.to_s.gsub("\n", " ")))
  end

  # One paragraph per line. The style name comes from the template, not from the letter text.
  # An empty value still keeps the paragraph. Ruby's split drops a blank string, which would delete the line.
  def odt_lines(value, style)
    safe = style.to_s.gsub(/[^A-Za-z0-9_.-]/, "")
    safe = "Standard" if safe.empty?
    lines = value.to_s.split("\n", -1)
    lines = [""] if lines.empty?
    lines.map { |line|
      %(<text:p text:style-name="#{safe}">#{xml_escape(line)}</text:p>)
    }.join
  end

  # Escapes &, < and >. Quotes are not needed in the text nodes used here.
  def xml_escape(text)
    text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
  end

  # Writes a new ODT from the content XML and the small companion files.
  def pack_parts(dest, content)
    Dir.mktmpdir("praxis-tpl") do |dir|
      File.write(File.join(dir, "mimetype"), "application/vnd.oasis.opendocument.text")
      File.write(File.join(dir, "content.xml"), content)
      File.write(File.join(dir, "styles.xml"), styles_xml)
      File.write(File.join(dir, "meta.xml"), meta_xml)
      FileUtils.mkdir_p(File.join(dir, "META-INF"))
      File.write(File.join(dir, "META-INF/manifest.xml"), manifest_xml)
      pack_dir(dir, dest)
    end
  end

  # The mimetype entry is stored uncompressed and first, which is what ODT requires. Other parts are deflated.
  def pack_dir(dir, dest)
    FileUtils.rm_f(dest)
    FileUtils.mkdir_p(File.dirname(dest))
    stored = system(require_program("zip"), "-X", "-0", "-q", dest, "mimetype", chdir: dir)
    packed = system(require_program("zip"), "-X", "-q", dest, "content.xml", "styles.xml", "meta.xml", "META-INF/manifest.xml", chdir: dir)
    raise ArgumentError, "Vorlage lässt sich nicht schreiben" unless stored && packed
  end

  # DIN 5008 Form B. The header fills the top 45 mm. The address table then begins.
  def styles_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <office:document-styles xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:fo:1.0" office:version="1.3">
       <office:styles>
        <style:style style:name="Standard" style:family="paragraph">
         <style:paragraph-properties fo:margin-top="0mm" fo:margin-bottom="0mm" fo:line-height="120%"/>
         <style:text-properties fo:font-family="Liberation Serif" fo:font-size="12pt"/>
        </style:style>
        <style:style style:name="Kopf" style:family="paragraph">
         <style:paragraph-properties fo:margin-top="0mm" fo:margin-bottom="0mm" fo:line-height="110%"/>
         <style:text-properties fo:font-family="Liberation Sans" fo:font-size="11pt"/>
        </style:style>
        <style:style style:name="Abstand" style:family="paragraph">
         <style:paragraph-properties fo:margin-top="0mm" fo:margin-bottom="0mm" fo:line-height="100%"/>
         <style:text-properties fo:font-family="Liberation Sans" fo:font-size="8pt"/>
        </style:style>
        <style:style style:name="Rueck" style:family="paragraph">
         <style:paragraph-properties fo:margin-top="0mm" fo:margin-bottom="1mm"/>
         <style:text-properties fo:font-family="Liberation Sans" fo:font-size="8pt"/>
        </style:style>
        <style:style style:name="Anschrift" style:family="paragraph">
         <style:paragraph-properties fo:margin-top="0mm" fo:margin-bottom="0mm" fo:line-height="120%"/>
         <style:text-properties fo:font-family="Liberation Sans" fo:font-size="11pt"/>
        </style:style>
        <style:style style:name="Info" style:family="paragraph">
         <style:paragraph-properties fo:margin-top="5mm" fo:margin-bottom="0mm"/>
         <style:text-properties fo:font-family="Liberation Sans" fo:font-size="11pt"/>
        </style:style>
        <style:style style:name="Betreff" style:family="paragraph">
         <style:paragraph-properties fo:margin-top="8mm" fo:margin-bottom="8mm"/>
         <style:text-properties fo:font-family="Liberation Serif" fo:font-size="12pt" fo:font-weight="bold"/>
        </style:style>
       </office:styles>
       <office:automatic-styles>
        <style:page-layout style:name="Brief-Form-B">
         <style:page-layout-properties fo:page-width="210mm" fo:page-height="297mm" style:print-orientation="portrait" fo:margin-top="45mm" fo:margin-bottom="20mm" fo:margin-left="20mm" fo:margin-right="10mm" style:writing-mode="lr-tb"/>
         <style:header-style>
          <style:header-footer-properties fo:min-height="32mm" fo:margin-left="0mm" fo:margin-right="0mm" fo:margin-bottom="0mm" style:dynamic-spacing="false"/>
         </style:header-style>
        </style:page-layout>
       </office:automatic-styles>
       <office:master-styles>
        <style:master-page style:name="Standard" style:page-layout-name="Brief-Form-B">
         <style:header>
          <text:p text:style-name="Kopf">{{ARZT}}</text:p>
          <text:p text:style-name="Kopf">{{FACH}}</text:p>
          <text:p text:style-name="Kopf">{{ADRESSE}}</text:p>
          <text:p text:style-name="Kopf">{{TELEFON}}</text:p>
          <text:p text:style-name="Kopf">{{ARZTNUMMER}}</text:p>
         </style:header>
        </style:master-page>
       </office:master-styles>
      </office:document-styles>
    XML
  end

  # ODT meta with this program named as the generator.
  def meta_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <office:document-meta xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0" office:version="1.3">
       <office:meta><meta:generator>Praxis</meta:generator></office:meta>
      </office:document-meta>
    XML
  end

  # ODT manifest for the parts pack_dir writes.
  def manifest_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.3">
       <manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.text"/>
       <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>
       <manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/>
       <manifest:file-entry manifest:full-path="meta.xml" manifest:media-type="text/xml"/>
      </manifest:manifest>
    XML
  end

  # Like parse_date, but an unreadable date becomes nil.
  def parse_date_soft(value)
    return nil if clean(value).empty?
    parse_date(value)
  rescue ArgumentError
    nil
  end

  # Minutes of the practice grid. Only 10 or 20. Missing or foreign values mean 10.
  def termin_raster(db = nil)
    read = lambda do |base|
      n = base.get_first_value("SELECT value FROM meta WHERE key = 'termin_raster'").to_i
      [10, 20].include?(n) ? n : 10
    end
    return read.call(db) if db
    lock { |base| read.call(base) }
  end

  # Stores the grid. Existing appointments stay where they are. New ones must start on the new grid.
  def set_termin_raster(data)
    n = data["minuten"].to_i
    raise ArgumentError, "Das Raster ist 10 oder 20 Minuten." unless [10, 20].include?(n)
    lock { |db| meta_set_db(db, "termin_raster", n.to_s) }
    { "raster" => n }
  end

  def meta_set_db(db, key, value)
    db.execute("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, value])
  end

  # "08:00" to minutes from midnight. Also accepts 8, 8.00, 8,00 and 0800.
  # 24:00 is the end of the day. nil when the text is not a clock time.
  def parse_clock(value)
    text = clean(value).downcase.sub(/uhr\z/, "").tr(".,", ":")
    text = clean(text)
    if (match = text.match(/\A(\d{1,2})\z/))
      text = format("%d:00", match[1].to_i)
    elsif (match = text.match(/\A(\d{3,4})\z/))
      digits = match[1].rjust(4, "0")
      text = "#{digits[0, 2].to_i}:#{digits[2, 2]}"
    end
    match = text.match(/\A(\d{1,2}):(\d{2})\z/)
    return nil unless match
    hour = match[1].to_i
    minute = match[2].to_i
    return 24 * 60 if hour == 24 && minute.zero?
    return nil if hour > 23 || minute > 59
    hour * 60 + minute
  end

  def format_clock(minutes)
    format("%02d:%02d", minutes / 60, minutes % 60)
  end

  # Opening hours snap onto the raster. 8.00 stays 08:00. 8:05 on a 10-minute grid runs to the next line.
  def snap_clock_span(von, bis, raster)
    start_min = parse_clock(von)
    end_min = parse_clock(bis)
    raise ArgumentError, "Die Uhrzeit fehlt." unless start_min && end_min
    start_min = (start_min / raster) * raster
    end_min = ((end_min + raster - 1) / raster) * raster
    end_min = 24 * 60 if end_min > 24 * 60
    raise ArgumentError, "Das Ende liegt vor dem Anfang." unless end_min > start_min
    [start_min, end_min]
  end

  # Both ends must lie on the raster, and the end must be later.
  def clock_span(von, bis, raster)
    start_min = parse_clock(von)
    end_min = parse_clock(bis)
    raise ArgumentError, "Die Uhrzeit fehlt." unless start_min && end_min
    raise ArgumentError, "Das Ende liegt vor dem Anfang." unless end_min > start_min
    unless (start_min % raster).zero? && (end_min % raster).zero?
      raise ArgumentError, "Die Zeit liegt nicht auf dem Raster."
    end
    [start_min, end_min]
  end

  # Week payload. Inactive resources stay in the list so the setup can still edit them.
  # Does not change which chart is open.
  def termine_between(von, bis)
    from = parse_date(von)
    to = parse_date(bis)
    raise ArgumentError, "Datum nicht erkannt" unless from && to
    raise ArgumentError, "Das Ende liegt vor dem Anfang." if to < from
    raise ArgumentError, "Der Zeitraum ist zu lang." if Date.parse(to) - Date.parse(from) > 370
    lock do |db|
      raster = termin_raster(db)
      resources = db.execute("SELECT id, name, aktiv FROM ressource ORDER BY id")
      hours = db.execute("SELECT ressource_id, wochentag, von, bis FROM ressource_zeit ORDER BY wochentag, von")
      by_res = Hash.new { |hash, key| hash[key] = [] }
      hours.each do |row|
        by_res[row["ressource_id"]] << {
          "wochentag" => row["wochentag"].to_i,
          "von" => row["von"],
          "bis" => row["bis"]
        }
      end
      rows = db.execute(<<~SQL, [to, from])
        SELECT t.id, t.ressource_id, t.patient_id, t.tag, t.bis_tag, t.von, t.bis,
               t.ganztaegig, t.alle, t.notiz, p.nachname, p.vorname
        FROM termin t
        LEFT JOIN person p ON p.id = t.patient_id
        WHERE t.tag <= ? AND t.bis_tag >= ?
        ORDER BY t.tag, t.von, t.id
      SQL
      {
        "raster" => raster,
        "ressourcen" => resources.map { |row|
          {
            "id" => row["id"],
            "name" => row["name"],
            "aktiv" => row["aktiv"].to_i,
            "zeiten" => by_res[row["id"]]
          }
        },
        "termine" => rows.map { |row| termin_hash(row) }
      }
    end
  end

  def termin_hash(row)
    parts = [row["nachname"].to_s, row["vorname"].to_s].reject(&:empty?)
    {
      "id" => row["id"],
      "ressource_id" => row["ressource_id"],
      "patient_id" => row["patient_id"],
      "name" => parts.join(", "),
      "tag" => row["tag"],
      "bis_tag" => row["bis_tag"],
      "von" => row["von"],
      "bis" => row["bis"],
      "ganztaegig" => row["ganztaegig"].to_i,
      "alle" => row["alle"].to_i,
      "notiz" => row["notiz"].to_s
    }
  end

  def add_ressource(data)
    name = clip(data["name"], 80)
    raise ArgumentError, "Der Name fehlt." if name.empty?
    lock do |db|
      raise ArgumentError, "Diesen Namen gibt es schon." if ressource_named(db, name)
      db.execute("INSERT INTO ressource (name, aktiv) VALUES (?, 1)", [name])
      { "id" => db.last_insert_row_id }
    end
  end

  def ressource_named(db, name, except = nil)
    sql = "SELECT id FROM ressource WHERE name = ? COLLATE NOCASE"
    args = [name]
    if except
      sql += " AND id != ?"
      args << except
    end
    db.get_first_value(sql, args)
  end

  # Replaces the weekly hours. A day may carry more than one span, so a pause is a gap between them.
  # Spans of one day must not overlap, and both ends lie on the raster.
  def patch_ressource(id, data)
    name = clip(data["name"], 80)
    raise ArgumentError, "Der Name fehlt." if name.empty?
    aktiv = (data["aktiv"] == false || data["aktiv"] == 0) ? 0 : 1
    zeiten = data["zeiten"]
    raise ArgumentError, "Die Zeiten fehlen." unless zeiten.is_a?(Array)
    raise ArgumentError, "Die Zeiten fehlen. Anfang und Ende eintragen, dann Speichern." if zeiten.empty?
    lock do |db|
      raise ArgumentError, "Die Ressource fehlt." unless db.get_first_value("SELECT id FROM ressource WHERE id = ?", [id])
      raise ArgumentError, "Diesen Namen gibt es schon." if ressource_named(db, name, id)
      spans = normalize_zeiten(zeiten, termin_raster(db))
      db.transaction do
        db.execute("UPDATE ressource SET name = ?, aktiv = ? WHERE id = ?", [name, aktiv, id])
        db.execute("DELETE FROM ressource_zeit WHERE ressource_id = ?", [id])
        spans.each do |weekday, von, bis|
          db.execute(
            "INSERT INTO ressource_zeit (ressource_id, wochentag, von, bis) VALUES (?, ?, ?, ?)",
            [id, weekday, von, bis]
          )
        end
      end
    end
    { "ok" => true }
  end

  def normalize_zeiten(zeiten, raster)
    spans = zeiten.map do |row|
      weekday = row["wochentag"].to_i
      raise ArgumentError, "Der Wochentag stimmt nicht." unless (1..7).cover?(weekday)
      start_min, end_min = snap_clock_span(row["von"], row["bis"], raster)
      [weekday, start_min, end_min]
    end
    spans.group_by(&:first).each_value do |day|
      ordered = day.sort_by { |span| span[1] }
      ordered.each_cons(2) do |left, right|
        raise ArgumentError, "Die Zeiten überschneiden sich." if right[1] < left[2]
      end
    end
    spans.map { |weekday, von, bis| [weekday, format_clock(von), format_clock(bis)] }
  end

  # Refuses while any appointment or block still names this resource.
  def delete_ressource(id)
    lock do |db|
      raise ArgumentError, "Die Ressource fehlt." unless db.get_first_value("SELECT id FROM ressource WHERE id = ?", [id])
      used = db.get_first_value("SELECT COUNT(*) FROM termin WHERE ressource_id = ?", [id]).to_i
      raise ArgumentError, "Diese Ressource hat noch Termine." if used > 0
      db.execute("DELETE FROM ressource WHERE id = ?", [id])
    end
    { "ok" => true }
  end

  # A timed entry occupies one resource. A vacation covers whole days, of one resource or of every resource.
  # Booking a patient does not change last_patient_id.
  # Two resources may be busy at the same hour. The same resource may not.
  def add_termin(data)
    notiz = clip(data["notiz"], 200)
    if data["ganztaegig"] == true || data["ganztaegig"] == 1
      add_vacation(data, notiz)
    else
      add_slot(data, notiz)
    end
  end

  def add_vacation(data, notiz)
    from = parse_date(data["tag"])
    to = parse_date(data["bis_tag"] || data["tag"])
    raise ArgumentError, "Datum nicht erkannt" unless from && to
    raise ArgumentError, "Das Ende liegt vor dem Anfang." if to < from
    all = data["alle"] == true || data["alle"] == 1
    ressource_id = all ? nil : data["ressource_id"].to_i
    lock do |db|
      unless all
        raise ArgumentError, "Die Ressource fehlt." unless db.get_first_value("SELECT id FROM ressource WHERE id = ?", [ressource_id])
      end
      db.execute(
        "INSERT INTO termin (ressource_id, patient_id, tag, bis_tag, von, bis, ganztaegig, alle, notiz) VALUES (?, NULL, ?, ?, NULL, NULL, 1, ?, ?)",
        [ressource_id, from, to, all ? 1 : 0, notiz]
      )
      { "id" => db.last_insert_row_id }
    end
  end

  def add_slot(data, notiz)
    tag = parse_date(data["tag"])
    raise ArgumentError, "Datum nicht erkannt" unless tag
    ressource_id = data["ressource_id"].to_i
    patient_id = data["patient_id"]
    patient_id = nil if patient_id.nil? || patient_id.to_s.empty?
    patient_id = patient_id.to_i if patient_id
    lock do |db|
      raster = termin_raster(db)
      von, bis = clock_span(data["von"], data["bis"], raster)
      raise ArgumentError, "Die Ressource fehlt." unless db.get_first_value("SELECT id FROM ressource WHERE id = ?", [ressource_id])
      if patient_id
        raise ArgumentError, "Die Akte fehlt." unless db.get_first_value("SELECT id FROM person WHERE id = ?", [patient_id])
      end
      raise ArgumentError, hour_message(db, ressource_id) unless inside_hours?(db, ressource_id, tag, von, bis)
      raise ArgumentError, "Diese Zeit ist schon belegt." if slot_taken?(db, ressource_id, tag, von, bis)
      db.execute(
        "INSERT INTO termin (ressource_id, patient_id, tag, bis_tag, von, bis, ganztaegig, alle, notiz) VALUES (?, ?, ?, ?, ?, ?, 0, 0, ?)",
        [ressource_id, patient_id, tag, tag, format_clock(von), format_clock(bis), notiz]
      )
      { "id" => db.last_insert_row_id }
    end
  end

  def hour_message(db, ressource_id)
    any = db.get_first_value("SELECT COUNT(*) FROM ressource_zeit WHERE ressource_id = ?", [ressource_id]).to_i
    return "Keine Öffnungszeiten. Unter Einrichten eintragen und Speichern." if any.zero?
    "Außerhalb der Öffnungszeit."
  end

  # The whole span must sit inside one opening interval of that weekday.
  def inside_hours?(db, ressource_id, tag, von, bis)
    weekday = Date.parse(tag).cwday
    db.execute(
      "SELECT von, bis FROM ressource_zeit WHERE ressource_id = ? AND wochentag = ?",
      [ressource_id, weekday]
    ).any? do |row|
      start_min = parse_clock(row["von"])
      end_min = parse_clock(row["bis"])
      start_min && end_min && von >= start_min && bis <= end_min
    end
  end

  # A whole-day block closes every minute. Timed blocks use a half-open range, so 09:30 can follow 09:00–09:30.
  def slot_taken?(db, ressource_id, tag, von, bis)
    db.execute("SELECT * FROM termin WHERE tag <= ? AND bis_tag >= ?", [tag, tag]).any? do |row|
      next false unless row["alle"].to_i == 1 || row["ressource_id"].to_i == ressource_id
      next true if row["ganztaegig"].to_i == 1
      next false unless row["tag"] == tag
      start_min = parse_clock(row["von"])
      end_min = parse_clock(row["bis"])
      start_min && end_min && von < end_min && start_min < bis
    end
  end

  def delete_termin(id)
    lock do |db|
      raise ArgumentError, "Der Termin fehlt." unless db.get_first_value("SELECT id FROM termin WHERE id = ?", [id])
      db.execute("DELETE FROM termin WHERE id = ?", [id])
    end
    { "ok" => true }
  end

  # People physically in the practice. Arrival does not change which chart is open.
  # A row without a termin is the waiting list. A row with a termin is that appointment, marked as arrived.
  def warte_list
    lock do |db|
      db.execute(<<~SQL).map { |row| warte_hash(row) }
        SELECT w.id, w.patient_id, w.termin_id, w.gekommen, w.reihe,
               p.nachname, p.vorname, p.nummer,
               t.von, t.bis, r.name AS ressource
        FROM wartezimmer w
        JOIN person p ON p.id = w.patient_id
        LEFT JOIN termin t ON t.id = w.termin_id
        LEFT JOIN ressource r ON r.id = t.ressource_id
        ORDER BY COALESCE(w.reihe, 1000000), w.gekommen, w.id
      SQL
    end
  end

  def warte_hash(row)
    gekommen = row["gekommen"].to_s
    uhr = gekommen =~ /T(\d{2}:\d{2})/ ? $1 : gekommen
    termin = nil
    if row["von"] && row["bis"]
      where = row["ressource"].to_s
      termin = row["von"] + "–" + row["bis"]
      termin = where + " " + termin unless where.empty?
    end
    {
      "id" => row["id"],
      "patient_id" => row["patient_id"],
      "nummer" => row["nummer"] && row["nummer"].to_i,
      "name" => [row["nachname"].to_s, row["vorname"].to_s].reject(&:empty?).join(", "),
      "gekommen" => uhr,
      "termin_id" => row["termin_id"],
      "termin" => termin,
      "warteliste" => row["termin_id"].nil?,
      "reihe" => row["reihe"] && row["reihe"].to_i
    }
  end

  # Today's appointments of an existing chart, and the next free slots from now.
  # Does not create a person and does not open a chart.
  def warte_angebot(patient_id, dauer_text)
    pid = patient_id.to_i
    lock do |db|
      person = db.get_first_row("SELECT id, ist_patient, nachname, vorname, nummer FROM person WHERE id = ?", [pid])
      raise ArgumentError, "Zuerst aufnehmen." unless person && person["ist_patient"].to_i == 1
      raster = termin_raster(db)
      dauer = dauer_text.to_i
      dauer = 20 if dauer <= 0
      raise ArgumentError, "Die Dauer folgt dem Raster." if dauer < raster || (dauer % raster) != 0
      tag = today
      termine = db.execute(<<~SQL, [pid, tag])
        SELECT t.id, t.von, t.bis, r.name AS ressource
        FROM termin t
        LEFT JOIN ressource r ON r.id = t.ressource_id
        WHERE t.patient_id = ? AND t.tag = ? AND t.ganztaegig = 0
        ORDER BY t.von
      SQL
      {
        "patient_id" => pid,
        "name" => [person["nachname"].to_s, person["vorname"].to_s].reject(&:empty?).join(", "),
        "nummer" => person["nummer"] && person["nummer"].to_i,
        "termine" => termine.map { |row|
          {
            "id" => row["id"],
            "von" => row["von"],
            "bis" => row["bis"],
            "ressource" => row["ressource"].to_s
          }
        },
        "frei" => freie_slots(db, tag, raster, dauer, 6)
      }
    end
  end

  # Soonest free stretches today, from the next grid line. At most `limit` rows.
  def freie_slots(db, tag, raster, dauer, limit)
    weekday = Date.parse(tag).cwday
    now_min = Time.now.hour * 60 + Time.now.min
    now_min = ((now_min + raster - 1) / raster) * raster
    slots = []
    db.execute("SELECT id, name FROM ressource WHERE aktiv = 1 ORDER BY id").each do |res|
      db.execute(
        "SELECT von, bis FROM ressource_zeit WHERE ressource_id = ? AND wochentag = ?",
        [res["id"], weekday]
      ).each do |span|
        start_min = parse_clock(span["von"])
        stop_min = parse_clock(span["bis"])
        next unless start_min && stop_min
        cursor = [start_min, now_min].max
        cursor += raster - (cursor % raster) unless (cursor % raster).zero?
        while cursor + dauer <= stop_min
          unless slot_taken?(db, res["id"], tag, cursor, cursor + dauer)
            slots << {
              "ressource_id" => res["id"],
              "ressource" => res["name"],
              "tag" => tag,
              "von" => format_clock(cursor),
              "bis" => format_clock(cursor + dauer),
              "minute" => cursor
            }
          end
          cursor += raster
        end
      end
    end
    slots.sort_by { |slot| [slot["minute"], slot["ressource_id"]] }.first(limit).map { |slot| slot.reject { |key, _| key == "minute" } }
  end

  # Puts an existing chart into the waiting room.
  # termin_id assigns that appointment. von/bis books a free stretch. Neither means the waiting list.
  # nur_hinzufuegen adds the chart at the end and leaves an existing row untouched.
  # A new row is last, so someone without an appointment starts behind whoever is already here.
  # The chart must already be a patient. That check happens before a slot is booked.
  # Does not change last_patient_id.
  def arrive(data)
    pid = data["patient_id"].to_i
    raise ArgumentError, "Zuerst aufnehmen." if pid <= 0
    known = lock do |db|
      db.get_first_value("SELECT id FROM person WHERE id = ? AND ist_patient = 1", [pid])
    end
    raise ArgumentError, "Zuerst aufnehmen." unless known
    termin_id = nil
    assigning = false
    if !data["termin_id"].nil? && data["termin_id"].to_s != ""
      assigning = true
      termin_id = data["termin_id"].to_i
      owner = lock { |db| db.get_first_value("SELECT patient_id FROM termin WHERE id = ?", [termin_id]) }
      raise ArgumentError, "Der Termin gehört zu einer anderen Akte." unless owner.to_i == pid
    elsif data["von"].to_s != ""
      assigning = true
      created = add_slot({
        "ressource_id" => data["ressource_id"],
        "patient_id" => pid,
        "tag" => data["tag"] || today,
        "von" => data["von"],
        "bis" => data["bis"]
      }, "")
      termin_id = created["id"]
    end
    only_add = !assigning && (data["nur_hinzufuegen"] == true || data["nur_hinzufuegen"] == 1)
    lock do |db|
      existing = db.get_first_value("SELECT id FROM wartezimmer WHERE patient_id = ?", [pid])
      if existing
        db.execute("UPDATE wartezimmer SET termin_id = ? WHERE id = ?", [termin_id, existing]) unless only_add
      else
        reihe = db.get_first_value("SELECT COALESCE(MAX(reihe), 0) FROM wartezimmer").to_i + 1
        db.execute(
          "INSERT INTO wartezimmer (patient_id, termin_id, gekommen, reihe) VALUES (?, ?, ?, ?)",
          [pid, termin_id, now_stamp, reihe]
        )
      end
      normalize_reihe(db)
    end
    { "anwesend" => warte_list }
  end

  def leave_warte(id)
    lock do |db|
      raise ArgumentError, "Nicht im Wartezimmer." unless db.get_first_value("SELECT id FROM wartezimmer WHERE id = ?", [id])
      db.execute("DELETE FROM wartezimmer WHERE id = ?", [id])
      normalize_reihe(db)
    end
    { "anwesend" => warte_list }
  end

  # Swaps one person with the neighbour above or below. The call order is reihe, starting at 1.
  def move_warte(id, data)
    direction = data["richtung"].to_s
    raise ArgumentError, "Hoch oder runter." unless %w[hoch runter].include?(direction)
    lock do |db|
      normalize_reihe(db)
      ids = db.execute("SELECT id FROM wartezimmer ORDER BY reihe").map { |row| row["id"] }
      index = ids.index(id)
      raise ArgumentError, "Nicht im Wartezimmer." unless index
      swap = direction == "hoch" ? index - 1 : index + 1
      raise ArgumentError, "Das ist schon der Anfang." if swap.negative?
      raise ArgumentError, "Das ist schon das Ende." if swap >= ids.length
      ids[index], ids[swap] = ids[swap], ids[index]
      ids.each_with_index do |row_id, place|
        db.execute("UPDATE wartezimmer SET reihe = ? WHERE id = ?", [place + 1, row_id])
      end
    end
    { "anwesend" => warte_list }
  end

  # Rewrites reihe as 1, 2, 3… in the current order. Call while holding the lock.
  def normalize_reihe(db)
    db.execute("SELECT id FROM wartezimmer ORDER BY COALESCE(reihe, 1000000), gekommen, id").each_with_index do |row, index|
      db.execute("UPDATE wartezimmer SET reihe = ? WHERE id = ?", [index + 1, row["id"]])
    end
  end
end

# A non-loopback bind is refused unless PRAXIS_ALLOW_REMOTE=1. There is still no login.
# The access log is empty. server.log receives errors. INT and TERM close the database cleanly.
if BIND != "127.0.0.1" && BIND != "::1" && ENV["PRAXIS_ALLOW_REMOTE"] != "1"
  warn "Nur localhost. Ein zentraler Rechner braucht später eine Anmeldung."
  exit 1
end

praxis = Praxis.new
server = WEBrick::HTTPServer.new(
  BindAddress: BIND,
  Port: PORT,
  AccessLog: [],
  Logger: WEBrick::Log.new(File.join(DATA, "server.log"))
)
handler = Class.new(WEBrick::HTTPServlet::AbstractServlet) do

  # Hands the Praxis instance to the servlet class.
  def self.app=(value)
    @app = value
  end

  # The Praxis instance the servlet calls.
  def self.app
    @app
  end

  # Every verb is handled here. POST, PUT, PATCH and DELETE are aliases of this method.
  def do_GET(req, res)
    self.class.app.handle(req, res)
  end
  alias do_POST do_GET
  alias do_PUT do_GET
  alias do_PATCH do_GET
  alias do_DELETE do_GET
end
handler.app = praxis
server.mount "/", handler
trap("INT") { server.shutdown }
trap("TERM") { server.shutdown }
puts "Praxis bereit auf http://#{BIND}:#{PORT}"
server.start
