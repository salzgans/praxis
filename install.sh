#!/bin/bash
# Installs the programs Praxis calls. It does not read or write the chart.
# --pruefen only reports. --mit-ungarisch also builds the local German-Hungarian draft.
set -eu

APP="$(cd "$(dirname "$0")" && pwd)"
CHECK_ONLY=0
WITH_HU=0

for arg in "$@"; do
  case "$arg" in
    --pruefen) CHECK_ONLY=1 ;;
    --mit-ungarisch) WITH_HU=1 ;;
    -h|--hilfe)
      cat <<EOF
Aufruf: $APP/install.sh [--pruefen] [--mit-ungarisch]

Richtet Ruby, LibreOffice, Poppler, Tesseract mit Deutsch und Ungarisch,
catdoc, zip und unzip ein. Die Akte bleibt unberührt.

--pruefen          zeigt nur, was schon da ist
--mit-ungarisch    lädt die Übersetzungsmodelle. Das dauert und braucht Netz.
EOF
      exit 0
      ;;
    *)
      printf 'Unbekannte Angabe: %s\n' "$arg" >&2
      exit 1
      ;;
  esac
done

OS=$(uname -s)

# Prints one line and exits 1.
die() {
  printf '%s\n' "$1" >&2
  exit 1
}

# First executable of that name on PATH, or empty.
find_bin() {
  command -v "$1" 2>/dev/null || true
}

# True when that ruby can load the chart libraries.
ruby_ready() {
  [ -n "${1:-}" ] && [ -x "$1" ] && "$1" -e 'require "sqlite3"; require "webrick"' >/dev/null 2>&1
}

# The ruby Praxis will use, or empty.
pick_ruby() {
  local candidate
  if ruby_ready "${PRAXIS_RUBY:-}"; then
    printf '%s\n' "$PRAXIS_RUBY"
    return
  fi
  if ruby_ready /usr/bin/ruby; then
    printf '%s\n' /usr/bin/ruby
    return
  fi
  if [ -n "$(find_bin ruby)" ] && ruby_ready "$(find_bin ruby)"; then
    find_bin ruby
    return
  fi
  for candidate in /opt/homebrew/opt/ruby/bin/ruby /usr/local/opt/ruby/bin/ruby; do
    if ruby_ready "$candidate"; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  printf '%s\n' ""
}

# System tesseract, or the bundled Linux copy when that is what Praxis would run.
tesseract_bin() {
  local bin
  bin=$(find_bin tesseract)
  if [ -n "$bin" ]; then
    printf '%s\n' "$bin"
    return
  fi
  if [ "$OS" = "Linux" ] && [ -x "$APP/ocr/tesseract" ]; then
    printf '%s\n' "$APP/ocr/tesseract"
  fi
}

# Runs tesseract --list-langs. The bundled copy needs its own libraries.
tesseract_langs() {
  local bin="$1"
  if [ "$bin" = "$APP/ocr/tesseract" ]; then
    LD_LIBRARY_PATH="$APP/ocr/lib" TESSDATA_PREFIX="$APP/ocr/tessdata" "$bin" --list-langs 2>&1 || true
  else
    "$bin" --list-langs 2>&1 || true
  fi
}

install_linux() {
  local sudo=""
  if [ "$(id -u)" -ne 0 ]; then
    sudo=sudo
  fi
  printf 'Pakete über apt. Das fragt nach dem Kennwort, wenn nötig.\n'
  $sudo apt-get update
  $sudo apt-get install -y \
    ruby ruby-sqlite3 ruby-webrick sqlite3 \
    libreoffice poppler-utils \
    tesseract-ocr tesseract-ocr-deu tesseract-ocr-hun \
    catdoc zip unzip lsof
  if [ "$WITH_HU" -eq 1 ]; then
    $sudo apt-get install -y python3 python3-venv python3-pip
  fi
}

install_mac() {
  local brew ruby_prefix
  brew=$(find_bin brew)
  [ -n "$brew" ] || die "Homebrew fehlt. Zuerst https://brew.sh, danach dieses Skript noch einmal."
  printf 'Pakete über Homebrew.\n'
  "$brew" install ruby sqlite poppler tesseract tesseract-lang catdoc
  if ! ruby_ready "$(pick_ruby)"; then
    ruby_prefix=$("$brew" --prefix ruby)
    "$ruby_prefix/bin/gem" install sqlite3 webrick --no-document
  fi
  if [ ! -d /Applications/LibreOffice.app ]; then
    "$brew" install --cask libreoffice
  fi
  if [ "$WITH_HU" -eq 1 ]; then
    "$brew" install python
  fi
}

# Builds uebersetzung/ and downloads the four Argos models. Letter text is not sent.
install_hungarian() {
  local py
  py=$(find_bin python3)
  [ -n "$py" ] || die "Python 3 fehlt. Die ungarische Übersetzung braucht es."
  if [ ! -x "$APP/uebersetzung/bin/python" ]; then
    "$py" -m venv "$APP/uebersetzung"
  fi
  "$APP/uebersetzung/bin/python" -m pip install --upgrade pip
  "$APP/uebersetzung/bin/python" -m pip install argostranslate
  "$APP/uebersetzung/bin/python" - <<'PY'
import argostranslate.package as package
package.update_package_index()
wanted = [("de", "en"), ("en", "de"), ("en", "hu"), ("hu", "en")]
have = {(item.from_code, item.to_code) for item in package.get_installed_packages()}
for src, dst in wanted:
    if (src, dst) in have:
        continue
    if not package.install_package_for_language_pair(src, dst):
        raise SystemExit(f"Modell {src} nach {dst} fehlt")
print("modelle da")
PY
  printf 'Ungarisch ist eingerichtet. Die Modelle liegen in %s\n' "$HOME/.local/share/argos-translate"
}

# Prints one OK or FEHLT line. missing grows when a required program is absent.
missing=0
note() {
  printf '  OK    %s\n' "$1"
}
lack() {
  printf '  FEHLT %s\n' "$1"
  missing=1
}

report() {
  local ruby bin langs
  printf 'Prüfung\n'
  ruby=$(pick_ruby)
  if [ -n "$ruby" ]; then
    note "Ruby $($ruby -e 'print RUBY_VERSION') mit sqlite3"
  else
    lack "Ruby mit dem Paket sqlite3 und webrick"
  fi
  bin=$(find_bin sqlite3)
  if [ -n "$bin" ]; then note "sqlite3 $bin"; else lack "sqlite3"; fi
  if [ -d /Applications/LibreOffice.app ] || [ -n "$(find_bin libreoffice)" ] || [ -n "$(find_bin soffice)" ]; then
    note "LibreOffice"
  else
    lack "LibreOffice"
  fi
  for bin in zip unzip pdftotext pdftoppm catdoc lsof; do
    if [ -n "$(find_bin "$bin")" ]; then note "$bin"; else lack "$bin"; fi
  done
  if [ "$OS" = "Linux" ]; then
    if [ -n "$(find_bin xdg-open)" ]; then note "xdg-open"; else lack "xdg-open"; fi
  fi
  bin=$(tesseract_bin)
  if [ -z "$bin" ]; then
    lack "tesseract"
  else
    langs=$(tesseract_langs "$bin")
    if printf '%s\n' "$langs" | grep -qx deu && printf '%s\n' "$langs" | grep -qx hun; then
      note "tesseract mit Deutsch und Ungarisch ($bin)"
    else
      lack "tesseract-Sprachen deu und hun"
    fi
  fi
  if [ -x "$APP/uebersetzung/bin/python" ] && "$APP/uebersetzung/bin/python" -c 'import argostranslate' >/dev/null 2>&1; then
    note "Ungarische Übersetzung"
  else
    printf '  OHNE  Ungarische Übersetzung. Dafür: %s/install.sh --mit-ungarisch\n' "$APP"
  fi
  if [ -x /opt/google/chrome/chrome ] || [ -n "$(find_bin google-chrome)" ] || [ -n "$(find_bin chromium)" ] \
    || [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]; then
    note "Chrome oder Chromium für ./praxis fenster"
  else
    printf '  OHNE  Chrome oder Chromium. Die Seite geht auch im normalen Browser auf.\n'
  fi
  if [ "$missing" -ne 0 ]; then
    printf 'Es fehlt noch etwas.\n'
    exit 1
  fi
  printf 'Die Programme sind da. Start mit: %s/praxis start\n' "$APP"
}

case "$OS" in
  Linux|Darwin) ;;
  *) die "Dieses Skript kennt Linux und Mac." ;;
esac

if [ "$CHECK_ONLY" -eq 0 ]; then
  case "$OS" in
    Linux) install_linux ;;
    Darwin) install_mac ;;
  esac
  if [ "$WITH_HU" -eq 1 ]; then
    install_hungarian
  fi
fi
report
