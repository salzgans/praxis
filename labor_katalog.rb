# coding: utf-8
# Lab parameter catalog and report reading.
# parameter/standard.json is the shipped mapping. Other JSON files in that folder
# load next, and parameter/eigene.json wins on the same id. standard.json is not modified.
# propose only reads. Rows are stored by the server after the user confirms them.
# OHNE is the group id for a name that has no assignment.

require "json"
require "date"
require "fileutils"
require "open3"
require "tmpdir"
require "timeout"

class LaborKatalog
  OHNE = "ohne"

  # Loads every parameter JSON file under the given directory.
  def initialize(dir)
    @dir = dir
    @mutex = Mutex.new
    @groups = []
    @params = []
    @sensitive = {}
    @insensitive = {}
    @norm = {}
    @conflicts = []
    load!
  end

  # Reads the JSON files again.
  def reload
    @mutex.synchronize { load! }
  end

  # Alias strings that two parameters both claimed while indexing.
  def conflicts
    @conflicts
  end

  # Groups stored results into the spreadsheet shape.
  def sheet(rows)
    @mutex.synchronize { build_sheet(rows) }
  end

  # Parses report text into rows. The caller decides whether to store them.
  def propose(text)
    @mutex.synchronize { build_proposal(text) }
  end

  # Looks up a parameter by name or short code.
  def find(name, kuerzel = nil)
    @mutex.synchronize { lookup(name) || lookup(kuerzel) }
  end

  # Groups and parameters for the browser. The note says where the JSON files live.
  def public_data
    @mutex.synchronize do
      {
        "gruppen" => group_list.reject { |g| g["id"] == OHNE },
        "parameter" => @params.map { |p| public_param(p) }.sort_by { |p| p["name"].downcase },
        "hinweis" => "Gruppen und Aliase stehen in den JSON-Dateien unter parameter/. Eigene Zuordnungen schreibt das Programm nach eigene.json."
      }
    end
  end

  # Writes one practice mapping, then reloads so the new alias is visible.
  def save_parameter(attrs)
    @mutex.synchronize { write_parameter(attrs) }
  end

  # Folds a name for matching: lowercase, umlauts expanded, only letters and digits.
  def self.norm(text)
    s = text.to_s.unicode_normalize(:nfkc).downcase
    s = s.gsub("ä", "ae").gsub("ö", "oe").gsub("ü", "ue").gsub("ß", "ss")
    s.gsub(/[^a-z0-9]+/, "")
  end

  # Folds a unit so µg and ug, and a trailing dot, compare equal.
  def self.unit_key(text)
    t = text.to_s.unicode_normalize(:nfkc).downcase
    t = t.gsub("µ", "u").gsub("μ", "u")
    t = t.gsub(/\s+/, "")
    t = t.delete(".")
    t = "s" if t == "sec" || t == "sek"
    t
  end

  # Reads a German or plain decimal. A leading <, > or ca. is stripped for the number only.
  def self.numeric_value(text)
    t = text.to_s.strip
    t = t.sub(/\A(?:<|>|≤|≥)\s*/, "")
    t = t.sub(/\Aca\.?\s*/i, "")
    t = t.delete(" ")
    return nil if t.empty?
    if t.match?(/\A-?\d{1,3}(\.\d{3})+(,\d+)?\z/)
      t = t.delete(".").sub(",", ".")
    elsif t.match?(/\A-?\d{1,3}(,\d{3})+(\.\d+)?\z/)
      t = t.delete(",")
    elsif t.match?(/\A-?\d+,\d+\z/)
      t = t.sub(",", ".")
    elsif !t.match?(/\A-?\d+(\.\d+)?\z/)
      return nil
    end
    Float(t)
  rescue ArgumentError, TypeError
    nil
  end

  # A number as German decimal text, with a precision that depends on its size.
  def self.format_de(number)
    rounded = if number.abs >= 100
      number.round(1)
    elsif number.abs >= 1
      number.round(2)
    else
      number.round(3)
    end
    text = format("%.3f", rounded)
    text.sub!(/0+\z/, "")
    text.sub!(/\.\z/, "")
    text.tr(".", ",")
  end

  # Text aus PDF, Bild, RTF oder Word. ocr_home zeigt auf praxis/ocr.
  # Manche RTF enden mit {\settingssize …} und einem Java-Block.
  # LibreOffice meldet dann, die Datei lasse sich nicht laden.

  # Cuts a trailer that starts at {\settingssize and is followed by a Java serialization header.
  # Unclosed groups are closed. A trailing NUL is removed only when the remaining groups balance.
  # Anything else is returned unchanged. This buffer is the working copy.
  def self.sanitize_rtf(raw)
    data = raw.to_s.dup.force_encoding(Encoding::ASCII_8BIT)
    return data unless data.start_with?("{\\rtf".b)
    marker = "{\\settingssize".b
    idx = data.index(marker)
    if idx
      java = "\xAC\xED\x00\x05".b
      j = data.index(java, idx)
      if j && (j - idx) <= 64
        prefix = data.byteslice(0, idx)
        depth = rtf_group_depth(prefix)
        return data if depth.nil? || depth < 0 || depth > 200
        return prefix + ("}".b * depth)
      end
    end
    return data unless data.getbyte(data.bytesize - 1) == 0
    end_at = data.bytesize
    end_at -= 1 while end_at.positive? && data.getbyte(end_at - 1) == 0
    stripped = data.byteslice(0, end_at)
    return data if stripped.empty? || stripped.include?("\0".b)
    return data unless rtf_group_depth(stripped) == 0
    stripped
  end

  # Group depth of an RTF byte string, ignoring escaped braces and \\bin blobs. nil means the scan was not reliable.
  def self.rtf_group_depth(data)
    i = 0
    depth = 0
    min_depth = 0
    n = data.bytesize
    while i < n
      byte = data.getbyte(i)
      if byte == 0x7b
        depth += 1
        i += 1
      elsif byte == 0x7d
        depth -= 1
        min_depth = depth if depth < min_depth
        i += 1
      elsif byte == 0x5c
        i += 1
        return nil if i >= n
        control = data.getbyte(i)
        if control == 0x5c || control == 0x7b || control == 0x7d
          i += 1
        elsif control == 0x27
          i += 1
          2.times do
            break if i >= n
            hex = data.getbyte(i)
            break unless (hex >= 48 && hex <= 57) || (hex >= 65 && hex <= 70) || (hex >= 97 && hex <= 102)
            i += 1
          end
        elsif (control >= 65 && control <= 90) || (control >= 97 && control <= 122)
          start = i
          i += 1
          i += 1 while i < n && (((b = data.getbyte(i)) >= 65 && b <= 90) || (b >= 97 && b <= 122))
          word = data.byteslice(start, i - start)
          negative = false
          if i < n && data.getbyte(i) == 0x2d
            negative = true
            i += 1
          end
          number = nil
          if i < n && (d = data.getbyte(i)) >= 48 && d <= 57
            num_at = i
            i += 1
            i += 1 while i < n && (d = data.getbyte(i)) >= 48 && d <= 57
            number = data.byteslice(num_at, i - num_at).to_i
            number = -number if negative
          end
          i += 1 if i < n && data.getbyte(i) == 0x20
          if word == "bin".b && number && number >= 0
            return nil if i + number > n
            i += number
          end
        else
          i += 1
        end
      else
        i += 1
      end
    end
    return nil if min_depth < 0
    depth
  end

  # Text of a PDF, image, RTF, Word or plain-text file, capped at 25 MiB. ocr_home points at praxis/ocr.
  def self.extract(path, mime, ocr_home:, lang: "deu")
    raise ArgumentError, "Datei nicht gefunden" unless File.file?(path)
    raise ArgumentError, "Die Datei ist zu groß" if File.size(path) > 25_000_000
    case kind(path, mime)
    when :pdf then extract_pdf(path, ocr_home, lang)
    when :image then ocr_image(path, ocr_home, lang)
    when :rtf then extract_rtf(path)
    when :doc then extract_doc(path)
    when :text then File.read(path, encoding: "UTF-8").scrub
    else
      raise ArgumentError, "Für diese Dateiart gibt es keine Texterkennung"
    end
  end

  # Picks a reader from the MIME type, then from the extension.
  def self.kind(path, mime)
    m = mime.to_s.downcase
    ext = File.extname(path).downcase
    return :pdf if m.include?("pdf") || ext == ".pdf"
    return :image if m.start_with?("image/") || %w[.jpg .jpeg .png .tif .tiff .gif .bmp .webp].include?(ext)
    return :rtf if m.include?("rtf") || ext == ".rtf"
    return :doc if m.include?("msword") || m.include?("word") || ext == ".doc"
    return :text if m.start_with?("text/") || ext == ".txt"
    :other
  end

  class << self
    private

    # Uses pdftotext. A page with almost no text is rendered and passed to Tesseract, first three pages only.
    def extract_pdf(path, ocr_home, lang)
      text = capture([require_program("pdftotext"), "-layout", "-enc", "UTF-8", path, "-"], {}, 25)
      return text if text.gsub(/\s/, "").length >= 40
      Dir.mktmpdir("praxis-ocr") do |dir|
        prefix = File.join(dir, "seite")
        capture([require_program("pdftoppm"), "-png", "-f", "1", "-l", "3", "-r", "250", path, prefix], {}, 40)
        pages = Dir[prefix + "*.png"].sort
        raise ArgumentError, "Die Seiten ließen sich nicht lesen" if pages.empty?
        pages.map { |img| ocr_image(img, ocr_home, lang) }.join("\n")
      end
    end

    # Tesseract. A system binary wins. The copy under ocr/ is Linux x86-64 and is the fallback.
    # lang stays deu for lab sheets. A Hungarian letter asks for hun+deu.
    def ocr_image(path, ocr_home, lang)
      bin, env = tesseract_command(ocr_home)
      capture([bin, path, "stdout", "-l", lang, "--psm", "6"], env, 40)
    end

    # /usr/bin, Homebrew, then PATH. PRAXIS_PDFTOPPM and the same pattern override one name.
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

    # The bundled binary is used only on Linux, and only when no system tesseract exists.
    def tesseract_command(ocr_home)
      found = program("tesseract")
      return [found, {}] if found
      bundled = File.join(ocr_home, "tesseract")
      if RUBY_PLATFORM.include?("linux") && File.executable?(bundled)
        return [bundled, {
          "LD_LIBRARY_PATH" => File.join(ocr_home, "lib"),
          "TESSDATA_PREFIX" => File.join(ocr_home, "tessdata")
        }]
      end
      raise ArgumentError, "Texterkennung fehlt"
    end

    # Sanitizes the working bytes, then strips RTF controls. This is a reading aid, not a word processor.
    def extract_rtf(path)
      raw = sanitize_rtf(File.binread(path))
      raise ArgumentError, "Die RTF-Datei ließ sich nicht lesen" unless raw.include?("\\rtf")
      text = raw.dup
      text = text.gsub(/\\'([0-9a-fA-F]{2})/) { [::Regexp.last_match(1).hex].pack("C") }
      text = text.gsub(/\\u(-?\d+)\??/) do
        cp = ::Regexp.last_match(1).to_i
        cp += 65536 if cp.negative?
        [cp].pack("U")
      rescue RangeError
        " "
      end
      text = text.gsub(/\\par\b/, "\n").gsub(/\\line\b/, "\n").gsub(/\\tab\b/, "\t")
      text = text.gsub(/\\[a-zA-Z]+-?\d* ?/, " ")
      text = text.gsub(/[{}]/, " ")
      text.force_encoding("Windows-1252").encode("UTF-8", invalid: :replace, undef: :replace)
    end

    # Reads an old .doc through catdoc.
    def extract_doc(path)
      capture([require_program("catdoc"), "-w", path], {}, 20)
    end

    # Runs an external reader with a timeout. The binary must be executable. stderr is not returned.
    def capture(cmd, env, seconds)
      raise ArgumentError, "Programm fehlt: #{File.basename(cmd[0])}" unless File.executable?(cmd[0])
      out = err = status = nil
      Timeout.timeout(seconds) do
        out, err, status = Open3.capture3(env, *cmd)
      end
      raise ArgumentError, "Lesen ist fehlgeschlagen" unless status.success?
      out.to_s.force_encoding("UTF-8").scrub
    rescue Timeout::Error
      raise ArgumentError, "Lesen hat zu lange gedauert"
    end
  end

  private

  # Reads every JSON file. eigene.json is applied last, so it wins on the same parameter id.
  # A group id that starts with an underscore is ignored.
  def load!
    groups = {}
    params = {}
    files = Dir[File.join(@dir, "*.json")].sort
    eigene = files.select { |path| File.basename(path) == "eigene.json" }
    (files - eigene + eigene).each do |path|
      data = JSON.parse(File.read(path, encoding: "UTF-8"))
      Array(data["gruppen"]).each do |group|
        id = group["id"].to_s.strip
        next if id.empty? || id.start_with?("_")
        groups[id] = { "id" => id, "name" => group["name"].to_s.strip, "ordnung" => group["ordnung"].to_i }
      end
      Array(data["parameter"]).each do |param|
        id = param["id"].to_s.strip
        next if id.empty?
        params[id] = clean_param(param)
      end
    end
    @groups = groups.values.sort_by { |g| [g["ordnung"], g["name"].downcase] }
    @params = params.values
    index!
  rescue JSON::ParserError
    raise ArgumentError, "Eine Parameterdatei ist kein gültiges JSON"
  end

  # Normalizes one parameter. The display name is also an alias. A conversion is factor and offset.
  def clean_param(param)
    alias_list = Array(param["alias"]).map { |item| item.to_s.strip }.reject(&:empty?)
    name = param["name"].to_s.strip
    alias_list.unshift(name) unless name.empty? || alias_list.include?(name)
    rules = Array(param["umrechnung"]).filter_map do |rule|
      next unless rule.is_a?(Hash)
      von = rule["von"].to_s.strip
      next if von.empty?
      {
        "von" => von,
        "faktor" => Float(rule["faktor"]),
        "offset" => rule["offset"] ? Float(rule["offset"]) : 0.0
      }
    end
    {
      "id" => param["id"].to_s.strip,
      "name" => name,
      "gruppe" => param["gruppe"].to_s.strip,
      "einheit" => param["einheit"].to_s.strip,
      "ordnung" => param["ordnung"].to_i,
      "alias" => alias_list.uniq,
      "gleiche" => Array(param["gleiche"]).map { |item| item.to_s.strip }.reject(&:empty?),
      "umrechnung" => rules
    }
  end

  # Builds the lookup maps. An exact alias claimed by two parameters is recorded in conflicts and the first one stays.
  def index!
    @sensitive = {}
    @insensitive = {}
    @norm = {}
    @conflicts = []
    @matchers = nil
    ordered = @params.sort_by { |p| [p["name"].match?(/\A[A-Z0-9]+\z/) ? 1 : 0, p["ordnung"], p["name"]] }
    ordered.each do |param|
      param["alias"].each do |token|
        text = token.to_s.strip
        next if text.empty?
        if @sensitive[text] && @sensitive[text]["id"] != param["id"]
          @conflicts << [text, @sensitive[text]["id"], param["id"]]
        else
          @sensitive[text] = param
        end
        key = text.downcase
        (@insensitive[key] ||= []) << param unless (@insensitive[key] || []).include?(param)
        folded = self.class.norm(text)
        @norm[folded] ||= param unless folded.empty?
      end
    end
  end

  # Exact alias, then a unique case-insensitive alias, then the folded name. An ambiguous short code prefers a plain name.
  def lookup(text)
    s = text.to_s.strip
    return nil if s.empty?
    return @sensitive[s] if @sensitive[s]
    list = @insensitive[s.downcase] || []
    if list.length == 1
      list[0]
    elsif list.length > 1
      plain = list.find { |p| p["name"].casecmp?(s) && !p["name"].match?(/\A[A-Z0-9]+\z/) }
      plain || list.find { |p| p["name"].casecmp?(s) } || list[0]
    else
      @norm[self.class.norm(s)]
    end
  end

  # Shipped groups in order, then Ohne Zuordnung for a name that has no group.
  def group_list
    list = @groups.reject { |g| g["id"] == OHNE }
    list + [{ "id" => OHNE, "name" => "Ohne Zuordnung", "ordnung" => 10_000 }]
  end

  # Display name of a group. An unknown id is Ohne Zuordnung.
  def group_name(id)
    found = group_list.find { |g| g["id"] == id }
    found ? found["name"] : "Ohne Zuordnung"
  end

  # One parameter for the browser, without the conversion rules.
  def public_param(param)
    {
      "id" => param["id"],
      "name" => param["name"],
      "gruppe" => param["gruppe"],
      "gruppe_name" => group_name(param["gruppe"]),
      "einheit" => param["einheit"],
      "alias" => param["alias"]
    }
  end

  # Rows down, days across. The stored value and unit stay. A converted reading is added beside them, marked with an approximation sign.
  def build_sheet(rows)
    grouped = {}
    rows.each do |row|
      name = row["name"].to_s.strip
      name = row["kuerzel"].to_s.strip if name.empty?
      wert = row["wert"].to_s.strip
      next if name.empty? || wert.empty?
      param = lookup(name) || lookup(row["kuerzel"])
      key = param ? param["id"] : "raw:#{self.class.norm(name)}"
      slot = grouped[key] ||= {
        "name" => param ? param["name"] : name,
        "parameter_id" => param && param["id"],
        "gruppe" => param && group_list.any? { |g| g["id"] == param["gruppe"] } ? param["gruppe"] : OHNE,
        "ordnung" => param ? param["ordnung"].to_i : 10_000,
        "einheit" => param ? param["einheit"].to_s : "",
        "cells" => {}
      }
      tag = row["tag"].to_s
      cell = slot["cells"][tag] ||= { "teile" => [], "norm" => "" }
      einheit = row["einheit"].to_s.strip
      text = [wert, einheit].reject(&:empty?).join(" ")
      next if text.empty? || cell["teile"].any? { |part| part["text"] == text }
      part = { "text" => text, "flag" => !row["flag"].to_s.strip.empty? }
      converted = convert_text(param, wert, einheit)
      part["umgerechnet"] = converted if converted
      cell["teile"] << part
      normv = row["norm"].to_s.strip
      cell["norm"] = normv if cell["norm"].empty? && !normv.empty?
    end
    dates = rows.map { |row| row["tag"].to_s }.reject(&:empty?).uniq.sort.reverse
    by_group = grouped.values.group_by { |row| row["gruppe"] }
    groups = group_list.filter_map do |group|
      list = by_group[group["id"]]
      next if list.nil? || list.empty?
      {
        "id" => group["id"],
        "name" => group["name"],
        "rows" => list.sort_by { |row| [row["ordnung"], row["name"].downcase] }
      }
    end
    { "dates" => dates, "groups" => groups }
  end

  # Applies Ziel = value * factor + offset when the unit differs and a rule exists.
  # A unit listed as gleich is already the preferred scale and is not converted.
  def convert_text(param, wert, einheit)
    return nil if param.nil?
    target = param["einheit"].to_s
    have = einheit.to_s.strip
    return nil if target.empty? || have.empty?
    have_key = self.class.unit_key(have)
    return nil if have_key.empty? || have_key == self.class.unit_key(target)
    return nil if param["gleiche"].any? { |item| self.class.unit_key(item) == have_key }
    rule = param["umrechnung"].find { |item| self.class.unit_key(item["von"]) == have_key }
    return nil unless rule
    return nil if (rule["faktor"] - 1.0).abs < 1e-9 && rule["offset"].abs < 1e-9
    number = self.class.numeric_value(wert)
    return nil unless number
    ziel = number * rule["faktor"] + rule["offset"]
    mark = wert.to_s.strip[/\A[<>≤≥]/]
    prefix = mark ? "#{mark} " : ""
    "≈ #{prefix}#{self.class.format_de(ziel)} #{target}"
  end

  # Finds a report date and parses lines. Unmatched names stay, with an empty parameter id, so the user can assign them.
  def build_proposal(text)
    lines = text.to_s.gsub("\r\n", "\n").gsub("\r", "\n").split("\n")
    zeilen = []
    seen = {}
    lines.each do |line|
      row = parse_line(line)
      next unless row
      key = [row["name"], row["wert"], row["einheit"]].join("\t")
      next if seen[key]
      seen[key] = true
      zeilen << row
      break if zeilen.length >= 80
    end
    {
      "tag" => find_tag(lines),
      "zeilen" => zeilen,
      "hinweis" => "Bitte jede Zeile prüfen. Die Texterkennung verwechselt Komma, Einheit und Namen. Erst Übernehmen schreibt die Werte."
    }
  end

  # Looks for a report date in the first lines.
  def find_tag(lines)
    ranked = []
    lines.each do |line|
      match = line.match(/(\d{1,2})\.(\d{1,2})\.(\d{2,4})/)
      next unless match
      iso = iso_date(match[1], match[2], match[3])
      next unless iso
      score = if line.match?(/abnahme|entnahme|probenahme|blutentnahme/i)
        3
      elsif line.match?(/analyse/i)
        2
      elsif line.match?(/geburt|geb\.|patient|seite|tel/i)
        0
      elsif line.match?(/datum/i)
        1
      else
        0
      end
      ranked << [score, iso] if score.positive?
    end
    best = ranked.max_by { |score, _iso| score }
    best && best[1]
  end

  # Day, month and year to ISO, or nil when the date is impossible.
  def iso_date(day, month, year)
    y = year.to_i
    y += y >= 70 ? 1900 : 2000 if y < 100
    Date.new(y, month.to_i, day.to_i).strftime("%Y-%m-%d")
  rescue Date::Error, ArgumentError
    nil
  end

  # One report line into a value, a unit, a reference range and an optional flag.
  def parse_line(line)
    text = line.to_s.strip
    return nil if text.length < 3
    return nil if text.match?(/\Aseite\b/i)
    param, tail = split_alias(text)
    if param
      row = value_from(tail, param)
      if row
        row["zeile"] = text[0, 160]
        return row
      end
    end
    return nil if text.match?(/telefon|tel\.|fax|straße|strasse|geburts|geb\.|patient|herr|frau|\bseite\b|abnahme|analyse|datum|eingang|probenahme/i)
    match = text.match(/\A([^\d<>]{2,70}?)\s+([<>≤≥]?\s*\d[\d.,]*|positiv|negativ|reaktiv|grenzwertig)\b(.*)\z/i)
    return nil unless match
    raw = match[1].to_s.strip.sub(/[:.\s]+\z/, "")
    return nil if raw.length < 2 || !raw.match?(/\p{L}/)
    return nil if raw.match?(/\A(abnahme|analyse|datum|seite|tel)\b/i)
    param = lookup(raw)
    wert_tail = "#{match[2]}#{match[3]}"
    row = value_from(wert_tail, param)
    return nil unless row
    row["name"] = param ? param["name"] : raw
    row["parameter_id"] = param && param["id"]
    row["gruppe"] = param ? param["gruppe"] : OHNE
    row["gruppe_name"] = group_name(row["gruppe"])
    row["zeile"] = text[0, 160]
    row
  end

  # Splits a name from the rest of a report line when the name matches a known alias.
  def split_alias(line)
    hits = []
    matchers.each do |len, rx, param|
      match = rx.match(line)
      next unless match
      hits << [match.begin(0), -len, match.end(0), param, match[0]]
    end
    return nil if hits.empty?
    start = hits.map(&:first).min
    longest = hits.select { |hit| hit[0] == start }.min_by { |hit| hit[1] }
    pool = hits.select { |hit| hit[0] == start && hit[1] == longest[1] }
    chosen = pool.find { |hit| hit[3]["name"] == hit[4] } ||
      pool.find { |hit| !hit[3]["name"].match?(/\A[A-Z0-9]+\z/) } ||
      pool[0]
    [chosen[3], line[chosen[2]..].to_s]
  end

  # Alias patterns, longest first, so a longer name wins over its prefix.
  def matchers
    @matchers ||= begin
      list = []
      @params.each do |param|
        param["alias"].each do |token|
          text = token.to_s.strip
          next if text.length < 3
          rx = Regexp.new("(?<![\\p{L}\\p{N}])#{Regexp.escape(text)}(?![\\p{L}\\p{N}])", Regexp::IGNORECASE)
          list << [text.length, rx, param]
        end
      end
      list.sort_by { |len, _rx, _param| -len }
    end
  end

  # True when a match sits inside a date, so a number in the date is not taken as a result.
  def inside_date?(text, match)
    text.to_enum(:scan, /\d{1,2}\.\d{1,2}\.\d{2,4}/).any? do
      date = Regexp.last_match
      match.begin(0) < date.end(0) && match.end(0) > date.begin(0)
    end
  end

  # Takes the result from the tail of a line.
  def value_from(tail, param)
    text = tail.to_s.strip
    quali = text.match(/\b(positiv|negativ|nicht\s+reaktiv|reaktiv|grenzwertig)\b/i)
    match = nil
    text.to_enum(:scan, /([<>≤≥])?\s*(\d{1,6}(?:[.,]\d{1,4})?)/).each do
      cand = Regexp.last_match
      next if inside_date?(text, cand)
      match = cand
      break
    end
    if match && (quali.nil? || match.begin(0) <= (quali.begin(0)))
      comp = match[1].to_s
      wert = comp.empty? ? match[2] : "#{comp} #{match[2]}"
      unit, norm, flag = split_rest(text[match.end(0)..].to_s)
      flag = comp unless comp.empty?
      return pack(param, wert, unit, norm, flag)
    elsif quali && param
      return pack(param, quali[1], "", "", "")
    end
    nil
  end

  # Separates unit, reference range and flag from the tail.
  def split_rest(rest)
    tokens = rest.to_s.strip.split(/\s+/)
    unit = ""
    if tokens[0] && unit_token?(tokens[0])
      unit = correct_unit(tokens.shift.to_s.sub(/\.\z/, ""))
      unit = "" if self.class.unit_key(unit) == "keine"
    end
    flag = ""
    kept = []
    tokens.each do |token|
      if flag.empty? && token.match?(/\A(\+{1,3}|\*{1,2}|H{1,2}|L{1,2})\z/)
        flag = token
      else
        kept << token
      end
    end
    norm = kept.join(" ").gsub(/\s+/, " ").strip[0, 80].to_s
    norm = "" if norm.match?(/\Anormal\z/i)
    [unit, norm, flag]
  end

  # Repairs a few OCR misreads such as g/di for g/dl. An unknown token is kept.
  def correct_unit(token)
    fixes = {
      "g/di" => "g/dl", "g/d1" => "g/dl", "gidl" => "g/dl", "gdl" => "g/dl",
      "mg/di" => "mg/dl", "mg/d1" => "mg/dl", "mgdl" => "mg/dl",
      "ug/di" => "µg/dl", "mmol/i" => "mmol/l", "mmol/1" => "mmol/l",
      "u/i" => "U/l", "ui" => "U/l"
    }
    fixes[self.class.unit_key(token)] || token
  end

  # True when a token looks like a unit rather than a word of the reference range.
  def unit_token?(token)
    return false if token.match?(/\A(normal|siehe|bis|und|oder|keine|positiv|negativ|reaktiv)\z/i)
    return true if token.include?("/") || token.include?("%")
    token.match?(/\A[A-Za-zµμ%]{1,8}\.?\z/)
  end

  # One proposed row. An unknown name is placed under Ohne Zuordnung.
  def pack(param, wert, unit, norm, flag)
    gruppe = param ? param["gruppe"] : OHNE
    gruppe = OHNE unless group_list.any? { |g| g["id"] == gruppe }
    {
      "name" => param ? param["name"] : "",
      "wert" => wert.to_s,
      "einheit" => unit.to_s,
      "norm" => norm.to_s,
      "flag" => flag.to_s,
      "parameter_id" => param && param["id"],
      "gruppe" => gruppe,
      "gruppe_name" => group_name(gruppe)
    }
  end

  # Validates a mapping and stores it in eigene.json. The shipped standard.json is not modified.
  def write_parameter(attrs)
    name = attrs["name"].to_s.strip
    raise ArgumentError, "Name fehlt" if name.empty?
    gruppe = attrs["gruppe"].to_s.strip
    raise ArgumentError, "Gruppe fehlt" unless @groups.any? { |g| g["id"] == gruppe }
    aliases = Array(attrs["alias"]).map { |item| item.to_s.strip }.reject(&:empty?)
    aliases << name unless aliases.any? { |item| item.casecmp?(name) }
    raise ArgumentError, "Zu viele Aliase" if aliases.length > 40
    ziel = attrs["ziel_id"].to_s.strip
    target = @params.find { |p| p["id"] == ziel } if !ziel.empty?
    target ||= @params.find { |p| p["name"].casecmp?(name) }
    id = target ? target["id"] : self.class.norm(name)[0, 40]
    raise ArgumentError, "Name ergibt keinen Schlüssel" if id.nil? || id.empty?
    target ||= @params.find { |p| p["id"] == id }
    einheit = attrs["einheit"].to_s.strip
    einheit = target["einheit"] if einheit.empty? && target
    rules = target ? target["umrechnung"].map(&:dup) : []
    von = attrs["von"].to_s.strip
    unless von.empty?
      begin
        faktor = Float(attrs["faktor"])
        offset = attrs["offset"].to_s.strip.empty? ? 0.0 : Float(attrs["offset"])
      rescue ArgumentError, TypeError
        raise ArgumentError, "Faktor muss eine Zahl sein"
      end
      raise ArgumentError, "Faktor liegt außerhalb" unless faktor.finite? && faktor.abs.between?(1e-6, 1e6)
      raise ArgumentError, "Offset liegt außerhalb" unless offset.finite? && offset.abs <= 10_000
      rules.reject! { |rule| self.class.unit_key(rule["von"]) == self.class.unit_key(von) }
      rules << { "von" => von, "faktor" => faktor, "offset" => offset }
    end
    entry = {
      "id" => id,
      "name" => target ? target["name"] : name,
      "gruppe" => gruppe,
      "einheit" => einheit.to_s,
      "ordnung" => target ? target["ordnung"] : 800,
      "alias" => (target ? target["alias"] + aliases : aliases).map(&:to_s).uniq,
      "gleiche" => target ? target["gleiche"] : [],
      "umrechnung" => rules.map { |rule| compact_rule(rule) }
    }
    store_eigene(entry)
    load!
    public_param(@params.find { |p| p["id"] == id })
  rescue ArgumentError
    raise
  rescue TypeError
    raise ArgumentError, "Faktor muss eine Zahl sein"
  end

  # Drops an offset that is effectively zero so the JSON stays small.
  def compact_rule(rule)
    out = { "von" => rule["von"], "faktor" => rule["faktor"] }
    out["offset"] = rule["offset"] if rule["offset"] && rule["offset"].abs > 1e-12
    out
  end

  # Replaces the parameter of the same id in eigene.json and renames the file into place.
  def store_eigene(entry)
    path = File.join(@dir, "eigene.json")
    data = if File.file?(path)
      JSON.parse(File.read(path, encoding: "UTF-8"))
    else
      { "name" => "Eigene Zuordnungen", "gruppen" => [], "parameter" => [] }
    end
    data["parameter"] = Array(data["parameter"]).reject { |param| param["id"] == entry["id"] }
    data["parameter"] << entry
    data["parameter"].sort_by! { |param| param["name"].to_s.downcase }
    tmp = "#{path}.tmp"
    File.write(tmp, JSON.pretty_generate(data), encoding: "UTF-8")
    File.rename(tmp, path)
  end
end
