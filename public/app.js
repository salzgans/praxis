"use strict";

// One page for the practice chart. Patient text is set with textContent, never as HTML.
// A shortcut is typed in the footer, then Enter. The match is the uppercased text.
// A text block belongs to one rubric. Tab in that rubric's line expands the token before the caret.
// Escape closes the front window. Window positions live in localStorage under
// praxis.fenster. That is a setting of this browser, not part of the chart.
// TEXT is the text kinds. KUERZEL is the list opened by ?. OPEN maps a shortcut to a window id.
// A fee factor is thousandths. An empty factor means 1.

const TEXT = { A: "Anamnese", B: "Befund", D: "Diagnose", DD: "Dauerdiagnose", CAVE: "CAVE", PR: "Procedere", I: "Info", L: "Labor" };
const TEXT_ALL = { A: "Anamnesen", B: "Befunde", D: "Diagnosen", DD: "Dauerdiagnosen", CAVE: "CAVE", PR: "Procedere", I: "Infos", L: "Labortexte" };
const KUERZEL = [
  ["A", "Neue Anamnese"],
  ["A+", "Alle Anamnesen"],
  ["B", "Neuer Befund"],
  ["B+", "Alle Befunde"],
  ["D", "Neue Diagnose"],
  ["D+", "Alle Diagnosen"],
  ["D Kode", "Diese Diagnose aus dem Katalog"],
  ["DD", "Neue Dauerdiagnose"],
  ["DD+", "Alle Dauerdiagnosen"],
  ["DD Kode", "Dieser Kode als Dauerdiagnose"],
  ["DK", "Diagnosenkatalog"],
  ["CAVE", "Neues CAVE, oben rot"],
  ["CAVE+", "Alle CAVE"],
  ["PR", "Neues Procedere"],
  ["PR+", "Alle Procedere"],
  ["I", "Neue Info"],
  ["I+", "Alle Infos"],
  ["L", "Neuer Labortext"],
  ["L+", "Alle Labortexte"],
  ["LB", "Labortabelle"],
  ["P", "Patientenliste"],
  ["NEU", "Neue Akte"],
  ["DA", "Dateien"],
  ["RP", "Rezept"],
  ["M", "Medikamente"],
  ["MP", "Medikationsplan"],
  ["BRIEFE", "Briefe"],
  ["AB", "Abrechnung"],
  ["ZI", "Gebühr an den Patienten"],
  ["ZI Kürzel", "Diese Gebühr mit dem Standardfaktor"],
  ["ZI Kürzel 2,3", "Dieselbe Gebühr mit Faktor"],
  ["ZI Kürzel 13.11.2026", "Diese Gebühr an diesem Tag"],
  ["ST", "Stammdaten"],
  ["PX", "Einstellungen"],
  ["TER", "Terminkalender"],
  ["WZ", "Wartezimmer"],
  ["?", "Diese Liste"]
];
const OPEN = {
  AB: "abrechnung", M: "medikamente", RP: "rezept", DA: "dateien",
  BRIEFE: "briefe", ST: "stammdaten", MP: "medikation", PX: "praxis", TER: "termine", WZ: "wartezimmer"
};
const SPECIES = { mensch: "Mensch", hund: "Hund", pferd: "Pferd", tier: "Tier" };
const TYP = { F: "Fixmedikation", R: "Reservemedikation", S: "symptomatisch" };

const hint = document.getElementById("hint");
const field = document.getElementById("kuerzel");
const sheet = document.getElementById("sheet");
const desk = document.getElementById("desk");

let state = { patient: null, chart: [], practice: {} };
let ready = false;
let editMode = "patient";
let editId = null;
let pickFor = null;
let linking = false;
let medMode = "browse";
let catalog = null;
let selectedInvoice = null;
let billDate = "";
let positionFromBill = false;
let positionForInvoice = null;
let letterTemplate = null;
let addresses = [];
let addressEdit = null;
let currentFile = null;
let laborKatalog = null;
let laborReview = null;
let laborAssign = null;
let eigene = [];
let bausteine = [];
let bausteinEdit = null;
let dxTimer = null;
let planRows = { active: [], stopped: [] };
let medTimer = null;
let z = 10;
let termWeek = null;
let termData = null;
let termMode = "termin";
let termSetup = false;
let termSelected = null;
let termBusy = false;
let termQuiet = false;
let warteRows = [];
let warteSeen = "";
let wartePick = null;
let warteHits = [];
let warteSeq = 0;
let warteTimer = null;
const TERM_COLORS = ["#3d7ab5", "#2f8f6b", "#c47b2b", "#8a4f9e", "#3d8d9e", "#b0892e", "#6b6b6b", "#8a5a44"];
const TERM_DAYS = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"];

// Removes every child. Used instead of assigning HTML.
function clear(node) {
  while (node.firstChild) node.removeChild(node.firstChild);
}

// Creates an element and sets text with textContent. Do not pass untrusted text through HTML.
function el(tag, cls, text) {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text != null) node.textContent = text;
  return node;
}

// Same rule as the server: empty means 1, 2,3 is 2300 thousandths, range 0.001 to 20.
function parseFaktor(raw) {
  const text = String(raw || "").trim().replace(/\s+/g, "").replace(".", ",");
  if (!text) return 1000;
  const match = text.match(/^(\d{1,2})(?:,(\d{1,3}))?$/);
  if (!match) return null;
  const ts = Number(match[1]) * 1000 + Number((match[2] || "").padEnd(3, "0"));
  if (ts < 1 || ts > 20000) return null;
  return ts;
}

// Thousandths to a German decimal without trailing zeros.
function formatFaktor(ts) {
  const whole = Math.floor(ts / 1000);
  const frac = String(ts % 1000).padStart(3, "0").replace(/0+$/, "");
  return frac ? whole + "," + frac : String(whole);
}

// Half-up to the nearest cent. The server stores this amount on the position.
function chargeCents(base, ts) {
  return Math.floor((base * ts + 500) / 1000);
}

// Cents to German money, with a thousands dot and a decimal comma.
function euro(cents) {
  const n = Math.round(Number(cents) || 0);
  const sign = n < 0 ? "-" : "";
  const v = Math.abs(n);
  const whole = String(Math.floor(v / 100)).replace(/\B(?=(\d{3})+(?!\d))/g, ".");
  return sign + whole + "," + String(v % 100).padStart(2, "0");
}

// Today as dd.mm.yyyy.
function todayDE() {
  const d = new Date();
  const p = function (n) { return String(n).padStart(2, "0"); };
  return p(d.getDate()) + "." + p(d.getMonth() + 1) + "." + d.getFullYear();
}

// Family name, given name.
function labelName(p) {
  if (!p) return "";
  return [p.nachname, p.vorname].filter(Boolean).join(", ");
}

// Practice title, given name and family name on one line.
function doctorLine(px) {
  return [px.titel, px.vorname, px.name].filter(Boolean).join(" ");
}

// Street, then postcode and town.
function patientAddress(p) {
  const place = [p.plz, p.wohnort].filter(Boolean).join(" ");
  return [p.strasse, place].filter(Boolean).join(", ");
}

// IBAN in groups of four. Empty stays empty.
function formatIban(raw) {
  const compact = String(raw || "").replace(/\s+/g, "").toUpperCase();
  if (!compact) return "";
  return compact.replace(/(.{4})(?=.)/g, "$1 ");
}

// Name and address, one line each, for the invoice.
function letterLines(p) {
  if (!p) return "";
  const lines = [labelName(p)];
  if (p.strasse) lines.push(p.strasse);
  const place = [p.plz, p.wohnort].filter(Boolean).join(" ");
  if (place) lines.push(place);
  if (p.land) lines.push(p.land);
  return lines.filter(Boolean).join("\n");
}

// True when this page was loaded from this same computer.
function onThisMachine() {
  const host = location.hostname;
  return host === "127.0.0.1" || host === "localhost" || host === "[::1]";
}

// Asks praxis lokal on this computer to fetch the file and open it here.
// False means the local program is not running. A remote computer without it raises.
async function openLocal(href, name) {
  let response;
  try {
    response = await fetch("http://127.0.0.1:8764/oeffnen", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ pfad: href, name: name || "" })
    });
  } catch (e) {
    if (onThisMachine()) return false;
    throw new Error("Auf diesem Rechner läuft praxis lokal nicht.");
  }
  const data = await response.json().catch(function () { return {}; });
  if (!response.ok) throw new Error(data.error || "Die Datei wurde nicht geöffnet.");
  return true;
}

// Opens on this computer. When praxis lokal is absent here, fallback opens through the server.
async function openStored(href, name, fallback) {
  const local = await openLocal(href, name);
  if (local) return true;
  if (!fallback) return false;
  const result = await fallback();
  return !!(result && (result.opened || result.ok));
}

// fetch wrapper. A non-JSON error body becomes an Error. The thrown message is the server's error text.
async function api(method, url, body, headers) {
  const opt = { method: method, headers: Object.assign({}, headers || {}) };
  if (body != null && !(body instanceof Blob)) {
    opt.headers["Content-Type"] = "application/json";
    opt.body = JSON.stringify(body);
  } else if (body) {
    opt.body = body;
  }
  const res = await fetch(url, opt);
  const text = await res.text();
  let data = null;
  if (text) {
    try { data = JSON.parse(text); } catch (e) { data = { error: text }; }
  }
  if (!res.ok) throw new Error((data && data.error) || "Nicht gespeichert");
  return data;
}

// Id of the open chart. Throws when none is open.
function pid() {
  if (!state.patient) throw new Error("Kein Patient geöffnet");
  return state.patient.id;
}

// Raises a window and marks the matching toolbar button.
function front(win) {
  z += 1;
  win.style.zIndex = String(z);
  document.querySelectorAll(".tool").forEach(function (b) {
    b.classList.toggle("on", b.dataset.open === win.id);
  });
}

// Shows a window, raises it, and pulls it back onto the desk.
function openWin(id) {
  const win = document.getElementById(id);
  win.classList.add("show");
  front(win);
  keepInside(win);
  return win;
}

// Hides a window. The chart data stays.
function closeWin(id) {
  document.getElementById(id).classList.remove("show");
}

// Writes the open name into the small headers of the other windows.
function paintWhos() {
  const name = state.patient ? labelName(state.patient) : "";
  const whoIds = ["bill-who", "plan-who", "rx-who", "file-who", "letter-who", "labor-who"];
  Object.keys(TEXT).forEach(function (kind) { whoIds.push("text-who-" + kind); });
  whoIds.forEach(function (id) {
    const node = document.getElementById(id);
    clear(node);
    if (!state.patient) {
      node.textContent = "Kein Patient geöffnet";
      return;
    }
    if (state.patient.nummer) node.appendChild(el("span", "nr", "Nr. " + state.patient.nummer));
    node.appendChild(document.createTextNode(name + " "));
    const em = el("em", null, todayDE());
    if (id === "plan-who" || id === "file-who" || id === "labor-who" || id.indexOf("text-who-") === 0) {
      em.textContent = SPECIES[state.patient.species] || "";
    }
    node.appendChild(em);
  });
  document.getElementById("pos-who").textContent = todayDE();
}

// Chart header. A click on the name opens the master data. A click on a relative opens that chart.
function renderWho() {
  const who = document.getElementById("open-stamm");
  const rel = document.getElementById("rels");
  clear(who);
  clear(rel);
  if (!state.patient) {
    who.textContent = "Kein Patient geöffnet";
    rel.hidden = true;
    paintWhos();
    renderFlags();
    paintInWarte();
    return;
  }
  const p = state.patient;
  if (p.nummer) who.appendChild(el("span", "nr", "Nr. " + p.nummer));
  who.appendChild(document.createTextNode(labelName(p) + " "));
  const bits = [SPECIES[p.species] || p.species];
  if (p.geburtsdatum_anzeige) bits.push("geb. " + p.geburtsdatum_anzeige);
  who.appendChild(el("em", null, bits.join(" · ")));
  const links = p.relations || [];
  rel.hidden = links.length === 0;
  links.forEach(function (r) {
    const a = el("a", null, relationLabel(r));
    a.href = "#";
    a.addEventListener("click", function (ev) {
      ev.preventDefault();
      openPatient(r.to_id);
    });
    rel.appendChild(a);
  });
  paintWhos();
  renderFlags();
  paintInWarte();
}

// One Dauerdiagnose or CAVE for the header: code, then the text on one line.
function flagLine(entry) {
  const code = chartCode(entry);
  const text = diagnosisLine(entry.text);
  if (code && text) return code + "  " + text;
  return code || text || "…";
}

// Puts a comma-separated line into the header. The button opens that list and does not open the master data.
// The title attribute keeps the full line when the button is cut off with an ellipsis.
function fillFlag(node, prefix, rows, kind) {
  clear(node);
  node.hidden = rows.length === 0;
  node.removeAttribute("title");
  if (!rows.length) return;
  const line = rows.map(flagLine).join(", ");
  const shown = prefix ? prefix + "  " + line : line;
  node.title = shown;
  const button = el("button", "item", shown);
  button.type = "button";
  button.addEventListener("click", function () { openKind(kind); });
  node.appendChild(button);
}

// Dauerdiagnoses sit after the personal data, with no rubric word. CAVE sits on the right of the same line, in red.
// An empty flag stays hidden so the header does not grow a blank row.
function renderFlags() {
  const dauer = document.getElementById("dauer");
  const cave = document.getElementById("cave");
  if (!dauer || !cave) return;
  const rows = state.patient ? (state.chart || []) : [];
  fillFlag(dauer, "", rows.filter(isDauer), "DD");
  fillFlag(cave, "CAVE", rows.filter(isCave), "CAVE");
}

// Turns the stored prescription summary into a single readable line.
function prescriptionProse(text) {
  return String(text || "").split(/\n{2,}/).map(function (part) {
    return part.split(/\n/).map(function (line) { return line.trim(); }).filter(Boolean).join(", ");
  }).filter(Boolean).join(" · ");
}

// One fee as code plus text.
function positionPhrase(entry) {
  if (entry.label && entry.text) return entry.label + " " + entry.text;
  return entry.label || entry.text || "";
}

// Several fees of the same day share one chart row labelled Abrechnung. A click opens billing.
function positionBlock(entries) {
  const row = el("div", "entry");
  row.dataset.kind = "ZI";
  row.dataset.tag = entries[0].tag;
  row.dataset.ids = entries.map(function (entry) { return entry.id; }).join(" ");
  row.dataset.id = String(entries[entries.length - 1].id);
  row.appendChild(el("div", "tag", "Abrechnung"));
  const body = el("div", "body linkish", entries.map(positionPhrase).join(" · "));
  body.addEventListener("click", function () { openBilling(); });
  row.appendChild(body);
  return row;
}

// Appends another fee of that day to the shared row.
function extendPositionBlock(row, entry) {
  const ids = row.dataset.ids ? row.dataset.ids.split(" ") : [];
  ids.push(String(entry.id));
  row.dataset.ids = ids.join(" ");
  row.dataset.id = String(entry.id);
  const body = row.querySelector(".body");
  const phrase = positionPhrase(entry);
  body.textContent = body.textContent ? body.textContent + " · " + phrase : phrase;
}

// Text of a contentEditable node, without the trailing whitespace the browser adds.
function entryPlain(node) {
  return node.innerText.replace(/\u00a0/g, " ").replace(/\s+$/, "");
}

// Puts the caret at a character offset in the plain text.
function placeCaret(body, offset) {
  const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
  let left = offset;
  let node = walker.nextNode();
  while (node) {
    if (left <= node.textContent.length) {
      const range = document.createRange();
      range.setStart(node, Math.max(0, left));
      range.collapse(true);
      const sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
      return;
    }
    left -= node.textContent.length;
    node = walker.nextNode();
  }
}

// Replaces the shortcut immediately before the caret with that row's text block.
// The rubric is the row's rubric. A token inside a word is left alone. Text is set as text, not HTML.
function expandBaustein(body, entry) {
  const sel = window.getSelection();
  if (!sel || sel.rangeCount === 0 || !sel.isCollapsed) return false;
  const range = sel.getRangeAt(0);
  if (!body.contains(range.endContainer)) return false;
  const pre = range.cloneRange();
  pre.selectNodeContents(body);
  pre.setEnd(range.endContainer, range.endOffset);
  const before = pre.toString().replace(/\u00a0/g, " ");
  const post = range.cloneRange();
  post.selectNodeContents(body);
  post.setStart(range.endContainer, range.endOffset);
  const after = post.toString().replace(/\u00a0/g, " ");
  if (/^[A-Za-z0-9ÄÖÜäöüß]/.test(after)) return false;
  const match = /(?:^|\s)([A-Za-z0-9]{1,16})$/.exec(before);
  if (!match) return false;
  const code = match[1].toUpperCase();
  const kind = viewKind(entry);
  const row = bausteine.find(function (item) {
    return item.kind === kind && String(item.kuerzel || "").toUpperCase() === code;
  });
  if (!row) return false;
  const next = before.slice(0, before.length - match[1].length) + row.text + after;
  const caret = before.length - match[1].length + row.text.length;
  body.textContent = next;
  placeCaret(body, caret);
  body.dispatchEvent(new FocusEvent("blur"));
  return true;
}

// Saves on blur, and only when the text changed. dataset.saved is the text currently shown,
// so a diagnosis line whose stored newlines were collapsed is not written back until the user edits it.
// Tab expands a text block of this rubric. Any other Tab leaves the field.
function bindEntryBody(body, entry) {
  body.contentEditable = "true";
  body.dataset.entry = String(entry.id);
  body.dataset.saved = entry.text || "";
  body.addEventListener("keydown", function (ev) {
    if (ev.key !== "Tab" || ev.shiftKey || ev.ctrlKey || ev.altKey || ev.metaKey) return;
    if (!expandBaustein(body, entry)) return;
    ev.preventDefault();
  });
  body.addEventListener("blur", function () {
    const text = entryPlain(body);
    if (text === body.dataset.saved) return;
    body.dataset.saved = text;
    (state.chart || []).forEach(function (row) {
      if (row.id === entry.id) row.text = text;
    });
    if (/^\d+$/.test(String(entry.id))) {
      document.querySelectorAll('[data-entry="' + entry.id + '"]').forEach(function (node) {
        if (node === body || entryPlain(node) === text) {
          node.dataset.saved = text;
          return;
        }
        node.dataset.saved = text;
        node.textContent = text;
      });
    }
    if (isDauer(entry) || isCave(entry)) renderFlags();
    api("PATCH", "/api/entries/" + entry.id, { text: text }).catch(function (err) {
      hint.textContent = err.message;
    });
  });
}

// A Dauerdiagnose is kind DD, or an older row with dauer 1.
function isDauer(entry) {
  return !!(entry && (entry.kind === "DD" || entry.dauer === 1 || entry.dauer === true));
}

// CAVE is kind CAVE, or a row whose label is CAVE.
function isCave(entry) {
  return !!(entry && (entry.kind === "CAVE" || String(entry.label || "").toUpperCase() === "CAVE"));
}

// The rubric to display. Dauer and CAVE win over the stored kind. A row labelled Diagnose is a diagnosis.
function viewKind(entry) {
  if (isDauer(entry)) return "DD";
  if (isCave(entry)) return "CAVE";
  if (entry.kind === "D" || entry.label === "Diagnose") return "D";
  return entry.kind;
}

// The blue rubric. A diagnosis shows the word Diagnose, not its code. The code is printed in the line.
function chartTag(entry) {
  if (isDauer(entry)) return "Dauerdiagnose";
  if (isCave(entry)) return "CAVE";
  if (entry.kind === "D" || entry.label === "Diagnose") return "Diagnose";
  return entry.label;
}

// The catalog code of a diagnosis. The plain labels Diagnose and Dauerdiagnose are not codes.
function chartCode(entry) {
  const view = viewKind(entry);
  if (view !== "D" && view !== "DD") return "";
  if (!entry.label || entry.label === "Diagnose" || entry.label === "Dauerdiagnose") return "";
  return entry.label;
}

// Collapses whitespace so code, title and long text fit on one wrapping line.
function diagnosisLine(text) {
  return String(text || "").replace(/\s+/g, " ").trim();
}

// Toggles the Dauer flag on this row.
function dauerButton(entry) {
  const button = el("button", isDauer(entry) ? "dauer on" : "dauer", "Dauer");
  button.type = "button";
  button.title = isDauer(entry) ? "Keine Dauerdiagnose mehr" : "Als Dauerdiagnose kennzeichnen";
  button.addEventListener("click", function () {
    toggleDauer(entry).catch(function (err) { hint.textContent = err.message; });
  });
  return button;
}

// One chart row. Diagnosis text is one line. Text kinds are edited in place. Other kinds open their window on click.
function entryNode(entry, focus) {
  const row = el("div", "entry");
  row.dataset.id = String(entry.id);
  row.dataset.kind = entry.kind;
  const view = viewKind(entry);
  const code = chartCode(entry);
  const tag = el("div", "tag", chartTag(entry));
  if (view === "CAVE") tag.classList.add("cave");
  const shown = entry.kind === "RP" ? prescriptionProse(entry.text) : (entry.text || "");
  const body = el("div", "body");
  let editor = body;
  if (view === "D" || view === "DD") {
    body.classList.add("dxline");
    if (code) body.appendChild(el("span", "dxcode", code));
    editor = el("span", "dxtext", diagnosisLine(shown));
    body.appendChild(editor);
  } else {
    body.textContent = shown;
  }
  const editable = Object.prototype.hasOwnProperty.call(TEXT, entry.kind);
  if (editable) {
    if (TEXT[view]) {
      tag.classList.add("linkish");
      tag.title = "Alle " + TEXT_ALL[view];
      tag.addEventListener("click", function () { openKind(view); });
    }
    bindEntryBody(editor, entry);
    if (view === "D" || view === "DD") editor.dataset.saved = entryPlain(editor);
  } else {
    body.classList.add("linkish");
    body.addEventListener("click", function () { openRef(entry); });
  }
  row.appendChild(tag);
  row.appendChild(body);
  if (view === "D" || view === "DD") row.appendChild(dauerButton(entry));
  if (focus) setTimeout(function () { editor.focus(); }, 0);
  return row;
}

// Prints the day heading when the previous row is from another day.
function ensureDay(anzeige) {
  const days = sheet.querySelectorAll(".day");
  if (days.length && days[days.length - 1].textContent === anzeige) return;
  sheet.appendChild(el("div", "day", anzeige));
}

// Adds a new row at the end and refreshes the header flags. Fees of the same day join one block.
function appendEntry(entry, focus) {
  const empty = sheet.querySelector(".empty");
  if (empty) empty.remove();
  if (entry.kind === "ZI") {
    const have = sheet.querySelector('.entry[data-kind="ZI"][data-tag="' + entry.tag + '"]');
    if (have) {
      extendPositionBlock(have, entry);
      have.scrollIntoView({ block: "nearest" });
      return;
    }
  }
  ensureDay(entry.tag_anzeige);
  const node = entry.kind === "ZI" ? positionBlock([entry]) : entryNode(entry, focus);
  sheet.appendChild(node);
  sheet.scrollTop = sheet.scrollHeight;
  renderFlags();
}

// Redraws the open chart in date order. Fees of one day are one block.
function renderChart() {
  clear(sheet);
  const rows = state.chart || [];
  if (!rows.length) {
    const text = state.patient
      ? "Noch keine Einträge. A, B, D, DD, CAVE, PR, I oder L, dann Enter. DK öffnet den Diagnosenkatalog, ? die Kürzel."
      : "P öffnet die Patientenliste, NEU nimmt jemanden auf.";
    sheet.appendChild(el("div", "empty", text));
    renderOpenKinds();
    return;
  }
  let last = "";
  const blocks = {};
  rows.forEach(function (entry) {
    if (entry.tag !== last) {
      sheet.appendChild(el("div", "day", entry.tag_anzeige));
      last = entry.tag;
    }
    if (entry.kind === "ZI") {
      if (blocks[entry.tag]) extendPositionBlock(blocks[entry.tag], entry);
      else blocks[entry.tag] = sheet.appendChild(positionBlock([entry]));
      return;
    }
    sheet.appendChild(entryNode(entry, false));
  });
  sheet.scrollTop = sheet.scrollHeight;
  renderOpenKinds();
}

// Fills the window that lists every entry of one kind. Blurs an editor inside it first so that edit is saved.
function renderKind(kind) {
  const box = document.getElementById("text-sheet-" + kind);
  if (!box) return;
  const active = document.activeElement;
  if (active && box.contains(active) && active.blur) active.blur();
  clear(box);
  if (!state.patient) {
    box.appendChild(el("div", "empty", "Kein Patient geöffnet"));
    return;
  }
  const rows = (state.chart || []).filter(function (entry) {
    if (kind === "D" || kind === "DD" || kind === "CAVE" || kind === "I") return viewKind(entry) === kind;
    return entry.kind === kind;
  });
  if (!rows.length) {
    box.appendChild(el("div", "empty", "Noch kein Eintrag."));
    return;
  }
  rows.forEach(function (entry) {
    const row = el("div", "entry");
    row.dataset.kind = kind;
    const when = entry.tag_anzeige || "";
    const coded = (kind === "D" || kind === "DD") && entry.label && entry.label !== "Diagnose" && entry.label !== "Dauerdiagnose";
    row.appendChild(el("div", "tag", coded ? when + "  " + entry.label : when));
    const bodyText = kind === "D" || kind === "DD" ? diagnosisLine(entry.text) : (entry.text || "");
    const body = el("div", "body", bodyText);
    bindEntryBody(body, entry);
    if (kind === "D" || kind === "DD") body.dataset.saved = entryPlain(body);
    row.appendChild(body);
    if (kind === "D" || kind === "DD") row.appendChild(dauerButton(entry));
    box.appendChild(row);
  });
}

// Refreshes every kind window that is currently open.
function renderOpenKinds() {
  Object.keys(TEXT).forEach(function (kind) {
    const win = document.getElementById("text-" + kind);
    if (win && win.classList.contains("show")) renderKind(kind);
  });
}

// Opens the list of one text kind.
function openKind(kind) {
  if (!TEXT[kind]) return;
  paintWhos();
  renderKind(kind);
  openWin("text-" + kind);
  const box = document.getElementById("text-sheet-" + kind);
  if (box) box.scrollTop = box.scrollHeight;
}

// Builds the list windows for the text kinds. They are not in the HTML.
function buildKindWindows() {
  Object.keys(TEXT).forEach(function (kind, index) {
    const win = el("section", "win");
    win.id = "text-" + kind;
    win.style.left = (48 + index * 28) + "px";
    win.style.top = (28 + index * 24) + "px";
    win.style.width = "760px";
    win.style.height = "640px";
    const title = el("div", "title");
    title.appendChild(document.createTextNode(TEXT_ALL[kind]));
    const close = el("button", "x", "×");
    close.type = "button";
    close.dataset.close = win.id;
    title.appendChild(close);
    win.appendChild(title);
    const who = el("div", "who");
    who.id = "text-who-" + kind;
    win.appendChild(who);
    const pane = el("div", "sheet");
    pane.id = "text-sheet-" + kind;
    win.appendChild(pane);
    const foot = el("div", "foot");
    const neu = el("button", "act", "Neu");
    neu.type = "button";
    neu.addEventListener("click", function () {
      addText(kind, true).catch(function (err) { hint.textContent = err.message; });
    });
    foot.appendChild(neu);
    const kindHint = kind === "D"
      ? "D+ öffnet dieses Fenster. D und ein Kode übernehmen eine Katalogzeile. Dauer markiert eine Dauerdiagnose."
      : kind === "DD"
      ? "DD+ öffnet dieses Fenster. DD und ein Kode übernehmen eine Katalogzeile als Dauerdiagnose."
      : kind === "CAVE"
      ? "CAVE+ öffnet dieses Fenster. CAVE legt einen Hinweis an, der oben rot steht."
      : kind + "+ öffnet dieses Fenster";
    foot.appendChild(el("span", "hint", kindHint));
    win.appendChild(foot);
    desk.appendChild(win);
  });
}

// Opens the window a non-text chart row points at.
function openRef(entry) {
  if (entry.kind === "LB") openLabor();
  else if (entry.kind === "RP" && entry.ref_id) showPrescription(entry.ref_id);
  else if (entry.kind === "DA") openFiles(entry.ref_id);
  else if (entry.kind === "BRIEF" && entry.ref_id) {
    const file = String(entry.text || "").split("/").pop();
    openStored("/api/letters/" + entry.ref_id + "/datei", file, function () {
      return api("POST", "/api/letters/" + entry.ref_id + "/open");
    }).catch(function (err) { hint.textContent = err.message; });
  } else if (entry.kind === "BRIEF") openLetters();
  else if (entry.kind === "ZI") openBilling();
}

// Trimmed value of an input.
function val(id) {
  return document.getElementById(id).value;
}

// Sets an input when the element exists.
function setVal(id, value) {
  document.getElementById(id).value = value || "";
}

// Master-data fields. The birth date is sent as typed. The server parses it.
function stammPayload() {
  return {
    species: val("st-species"),
    geschlecht: val("st-geschlecht"),
    nachname: val("st-name"),
    vorname: val("st-vor"),
    geburtsdatum: val("st-geb"),
    geburtsort: val("st-gort"),
    wohnort: val("st-wohn"),
    land: val("st-land"),
    plz: val("st-plz"),
    strasse: val("st-str"),
    ausweis: val("st-pass"),
    mutter: val("st-mutter"),
    versicherung: val("st-vers"),
    krankenkasse: val("st-kasse")
  };
}

// Shows or hides the blocks that only make sense once a person exists.
function showStammExtras(show) {
  ["empf-block", "rel-hint", "rel-art-field", "rel-add-field", "rel-list"].forEach(function (id) {
    document.getElementById(id).hidden = !show;
  });
  document.getElementById("stamm-back").hidden = show;
}

// Title of the patient list, which is also used as a person picker.
function setListTitle(text) {
  const title = document.querySelector("#patienten .title");
  const button = title.querySelector("button");
  title.textContent = text;
  if (button) title.appendChild(button);
}

// Picker mode hides the actions that belong to the full patient list.
function setPickChrome(on) {
  setListTitle(on ? "Zur Verknüpfung auswählen" : "Patientenliste");
  const note = document.getElementById("pat-pick");
  if (on && pickFor) {
    note.hidden = false;
    note.textContent = "Beziehung: " + pickFor.art + ". Eine Zeile wählen, oder neu aufnehmen.";
  } else {
    note.hidden = true;
    note.textContent = "";
  }
}

// Splits a search of the form "Family, Given" the same way the server splits a new name.
function splitSearchName(raw) {
  const text = (raw || "").trim();
  if (!text) return { nachname: "", vorname: "" };
  if (text.indexOf(",") >= 0) {
    const parts = text.split(",");
    return {
      nachname: parts.shift().trim().slice(0, 30),
      vorname: parts.join(",").trim().slice(0, 30)
    };
  }
  const words = text.split(/\s+/);
  if (words.length >= 2) {
    return {
      vorname: words.slice(0, -1).join(" ").slice(0, 30),
      nachname: words[words.length - 1].slice(0, 30)
    };
  }
  return { nachname: text.slice(0, 30), vorname: "" };
}

// Text of one relationship in the header and in the master data.
function relationLabel(r) {
  const bits = [r.art, labelName(r)];
  if (r.species && r.species !== "mensch") bits.push(SPECIES[r.species] || r.species);
  if (r.geburtsdatum_anzeige) bits.push("geb. " + r.geburtsdatum_anzeige);
  if (r.wohnort) bits.push(r.wohnort);
  return bits.join(" · ");
}

// Fills the master-data form from a person.
function fillStamm(p) {
  setVal("st-species", p.species || "mensch");
  setVal("st-geschlecht", p.geschlecht === "w" || p.geschlecht === "m" || p.geschlecht === "d" ? p.geschlecht : "");
  setVal("st-name", p.nachname);
  setVal("st-vor", p.vorname);
  setVal("st-geb", p.geburtsdatum_anzeige);
  setVal("st-gort", p.geburtsort);
  setVal("st-wohn", p.wohnort);
  setVal("st-land", p.land);
  setVal("st-plz", p.plz);
  setVal("st-str", p.strasse);
  setVal("st-pass", p.ausweis);
  setVal("st-mutter", p.mutter);
  setVal("st-vers", p.versicherung);
  setVal("st-kasse", p.krankenkasse);
  const empf = p.empfaenger ? labelName(p.empfaenger) : "";
  setVal("st-empf", empf);
  renderRelList(p.relations || []);
}

// Lists relationships inside the master-data window.
function renderRelList(rows) {
  const box = document.getElementById("rel-list");
  clear(box);
  rows.forEach(function (r) {
    const line = el("div", "rowline");
    line.appendChild(el("span", null, relationLabel(r)));
    const btn = el("button", "act tiny", "Lösen");
    btn.type = "button";
    btn.addEventListener("click", function () { dropRelation(r.id); });
    line.appendChild(btn);
    box.appendChild(line);
  });
}

// Opens the master data of the open chart.
function editCurrent() {
  if (!state.patient) {
    openPatients();
    return;
  }
  editMode = "patient";
  editId = state.patient.id;
  document.getElementById("stamm-banner").hidden = true;
  showStammExtras(true);
  document.getElementById("stamm-delete").hidden = false;
  fillStamm(state.patient);
  document.getElementById("stamm-note").textContent = "";
  openWin("stammdaten");
}

// Opens the master data of a chosen person.
function editPerson(person, banner) {
  editMode = "person";
  editId = person.id;
  const note = document.getElementById("stamm-banner");
  note.hidden = false;
  note.textContent = banner;
  showStammExtras(false);
  document.getElementById("stamm-delete").hidden = true;
  fillStamm(person);
  openWin("stammdaten");
}

// Empty form for a new chart. The server assigns the next number.
function editNew() {
  pickFor = null;
  setPickChrome(false);
  editMode = "new";
  editId = null;
  const note = document.getElementById("stamm-banner");
  note.hidden = false;
  note.textContent = "Neue Aufnahme. Speichern öffnet die Akte.";
  showStammExtras(false);
  document.getElementById("stamm-delete").hidden = true;
  fillStamm({ species: "mensch" });
  document.getElementById("stamm-note").textContent = "";
  openWin("stammdaten");
  document.getElementById("st-name").focus();
}

// Empty form for a person who is being linked. Saving it must not switch the open chart.
function editNewForLink() {
  if (!pickFor) {
    editNew();
    return;
  }
  editMode = "link";
  editId = null;
  const note = document.getElementById("stamm-banner");
  note.hidden = false;
  note.textContent = "Neue Aufnahme für „" + pickFor.art + "“. Speichern verknüpft. Die Akte bleibt offen.";
  showStammExtras(false);
  document.getElementById("stamm-delete").hidden = true;
  const names = splitSearchName(val("pat-search"));
  fillStamm({ species: "mensch", nachname: names.nachname, vorname: names.vorname });
  document.getElementById("stamm-note").textContent = "";
  openWin("stammdaten");
  document.getElementById("st-name").focus();
}

// Creates or updates a person. A person created while linking is posted with remember false.
async function saveStamm() {
  const note = document.getElementById("stamm-note");
  try {
    if (editMode === "new") {
      const created = await api("POST", "/api/patients", stammPayload());
      note.textContent = "Gespeichert";
      await openPatient(created.id);
      editMode = "patient";
      editId = created.id;
      document.getElementById("stamm-banner").hidden = true;
      showStammExtras(true);
      document.getElementById("stamm-delete").hidden = false;
      fillStamm(state.patient);
      return;
    }
    if (editMode === "link") {
      const link = pickFor;
      if (!link) {
        note.textContent = "Keine Verknüpfung offen.";
        return;
      }
      if (!link.createdId) {
        const created = await api("POST", "/api/patients", Object.assign({ remember: false }, stammPayload()));
        link.createdId = created.id;
      }
      const linked = await api("POST", "/api/patients/" + link.fromId + "/relations", {
        art: link.art,
        to_id: link.createdId
      });
      pickFor = null;
      setPickChrome(false);
      closeWin("patienten");
      state.patient = linked;
      renderWho();
      renderChart();
      editMode = "patient";
      editId = linked.id;
      document.getElementById("stamm-banner").hidden = true;
      showStammExtras(true);
      document.getElementById("stamm-delete").hidden = false;
      fillStamm(linked);
      openWin("stammdaten");
      note.textContent = "Neu aufgenommen und verknüpft.";
      return;
    }
    const person = await api("PATCH", "/api/patients/" + editId, stammPayload());
    note.textContent = "Gespeichert";
    if (editMode === "patient") {
      state.patient = person;
      renderWho();
      fillStamm(person);
    }
  } catch (err) {
    note.textContent = err.message;
  }
}

// Sets the invoice recipient from the name field. An empty field clears it.
async function takeRecipient() {
  try {
    const person = await api("POST", "/api/patients/" + pid() + "/recipient", { name: val("st-empf") });
    state.patient = person;
    fillStamm(person);
    renderWho();
    document.getElementById("stamm-note").textContent = val("st-empf")
      ? "Der Empfänger hat eigene Stammdaten."
      : "Die Rechnung geht an den Patienten.";
  } catch (err) {
    document.getElementById("stamm-note").textContent = err.message;
  }
}

// Opens the recipient's master data.
async function openRecipient() {
  if (!state.patient || !state.patient.empfaenger) {
    document.getElementById("stamm-note").textContent = "Zuerst aufnehmen.";
    return;
  }
  const person = await api("GET", "/api/patients/" + state.patient.empfaenger.id);
  editPerson(person, "Rechnungsempfänger. Die Akte bleibt unverändert.");
}

// Patient list as a picker for a relationship or a recipient.
function openPicker() {
  const art = val("rel-art").trim();
  const note = document.getElementById("stamm-note");
  if (!state.patient) return;
  if (!art) {
    note.textContent = "Zuerst die Art der Beziehung eintragen.";
    document.getElementById("rel-art").focus();
    return;
  }
  pickFor = { art: art, fromId: state.patient.id };
  setPickChrome(true);
  openWin("patienten");
  drawPatients(val("pat-search")).then(function () {
    document.getElementById("pat-search").focus();
  }).catch(function (err) {
    note.textContent = err.message;
  });
}

// Stores a relationship to a person chosen from the list.
async function linkChosen(toId) {
  const link = pickFor;
  if (!link || linking) return;
  linking = true;
  const note = document.getElementById("stamm-note");
  try {
    const result = await api("POST", "/api/patients/" + link.fromId + "/relations", {
      art: link.art,
      to_id: toId
    });
    pickFor = null;
    setPickChrome(false);
    closeWin("patienten");
    state.patient = result;
    renderWho();
    fillStamm(result);
    openWin("stammdaten");
    note.textContent = "Verknüpft.";
  } catch (err) {
    note.textContent = err.message;
    hint.textContent = err.message;
  } finally {
    linking = false;
  }
}

// Removes one relationship.
async function dropRelation(id) {
  await api("DELETE", "/api/relations/" + id);
  const person = await api("GET", "/api/patients/" + state.patient.id);
  state.patient = person;
  renderWho();
  fillStamm(person);
}

// Deletes the open chart after a confirmation in the form.
async function deleteCurrent() {
  const person = state.patient;
  if (!person || editMode !== "patient") return;
  const nr = person.nummer ? "Nr. " + person.nummer + " " : "";
  const question = nr + labelName(person) + " löschen? Die Akte wird entfernt. Die Nummer wird nicht wieder vergeben.";
  if (!window.confirm(question)) return;
  try {
    state = await api("DELETE", "/api/patients/" + person.id);
    editMode = "patient";
    editId = state.patient ? state.patient.id : null;
    closeWin("stammdaten");
    renderWho();
    renderChart();
    if (state.patient) fillStamm(state.patient);
    if (document.getElementById("patienten").classList.contains("show")) {
      drawPatients(val("pat-search")).catch(function () {});
    }
    hint.textContent = "Gelöscht";
  } catch (err) {
    document.getElementById("stamm-note").textContent = err.message;
  }
}

// Loads one chart and redraws the page.
async function openPatient(id) {
  state = await api("POST", "/api/patients/" + id + "/open");
  editMode = "patient";
  editId = state.patient.id;
  renderWho();
  renderChart();
  openWin("akte");
  if (document.getElementById("patienten").classList.contains("show")) {
    drawPatients(val("pat-search")).catch(function () {});
  }
  if (document.getElementById("rezept").classList.contains("show")) {
    clear(document.getElementById("rx-lines"));
    drawRxPlan().catch(function () {});
  }
}

// Opens the patient list in search mode.
async function openPatients() {
  pickFor = null;
  setPickChrome(false);
  openWin("patienten");
  await drawPatients(val("pat-search"));
  document.getElementById("pat-search").focus();
}

let patSeq = 0;
let patTimer = null;

// Renders the search result. A click opens the chart, or picks the person when a picker is active.
async function drawPatients(q) {
  const seq = ++patSeq;
  const rows = await api("GET", "/api/patients?q=" + encodeURIComponent(q || ""));
  if (seq !== patSeq) return;
  const list = document.getElementById("pat-list");
  const count = document.getElementById("pat-count");
  clear(list);
  const searching = !!(q && String(q).trim());
  const n = rows.length;
  if (searching) count.textContent = n === 1 ? "1 Treffer" : n + " Treffer";
  else count.textContent = n === 1 ? "1 Patient" : n + " Patienten";
  if (!n) {
    list.appendChild(el("p", "hint", searching ? "Niemand gefunden." : "Noch niemand aufgenommen."));
    return;
  }
  const table = el("table", "plan");
  const head = document.createElement("thead");
  const hr = document.createElement("tr");
  ["Nr.", "Name", "Geburtsdatum", "Ort", "Spezies"].forEach(function (label) {
    hr.appendChild(el("th", null, label));
  });
  head.appendChild(hr);
  table.appendChild(head);
  const body = document.createElement("tbody");
  rows.forEach(function (p) {
    const tr = document.createElement("tr");
    if (state.patient && state.patient.id === p.id) tr.className = "on";
    const place = p.wohnort || p.geburtsort || "";
    tr.appendChild(el("td", "nr", p.nummer != null ? String(p.nummer) : ""));
    tr.appendChild(el("td", null, labelName(p)));
    tr.appendChild(el("td", null, p.geburtsdatum_anzeige || ""));
    tr.appendChild(el("td", null, place));
    tr.appendChild(el("td", null, SPECIES[p.species] || p.species || ""));
    tr.addEventListener("click", function () {
      if (pickFor) linkChosen(p.id);
      else openPatient(p.id);
    });
    body.appendChild(tr);
  });
  table.appendChild(body);
  list.appendChild(table);
}

// Fills the practice form, including one input per phone number.
function fillPracticeForm() {
  const px = state.practice || {};
  setVal("px-titel", px.titel);
  setVal("px-fach", px.fach);
  setVal("px-name", px.name);
  setVal("px-vor", px.vorname);
  setVal("px-nr", px.arztnummer);
  setVal("px-adr", px.adresse);
  setVal("px-iban", formatIban(px.iban));
  setVal("px-bic", px.bic);
  const box = document.getElementById("px-tels");
  clear(box);
  const phones = (px.telefone && px.telefone.length) ? px.telefone : [""];
  phones.forEach(addPhone);
  const img = document.getElementById("px-sign-preview");
  if (px.signature) {
    img.hidden = false;
    img.src = "/api/practice/signature?v=" + (px.signature_mtime || "");
  } else {
    img.hidden = true;
    img.removeAttribute("src");
  }
}

// Adds a phone input.
function addPhone(value) {
  const input = document.createElement("input");
  input.setAttribute("aria-label", "Telefon");
  input.value = value || "";
  document.getElementById("px-tels").appendChild(input);
  return input;
}

// Writes the practice identity. The signature is uploaded separately.
async function savePractice() {
  if (!ready) return;
  const telefone = Array.prototype.map.call(document.querySelectorAll("#px-tels input"), function (input) {
    return input.value.trim();
  }).filter(Boolean);
  state.practice = await api("PUT", "/api/practice", {
    titel: val("px-titel"),
    fach: val("px-fach"),
    name: val("px-name"),
    vorname: val("px-vor"),
    arztnummer: val("px-nr"),
    adresse: val("px-adr"),
    telefone: telefone,
    iban: val("px-iban"),
    bic: val("px-bic")
  });
  setVal("px-iban", formatIban(state.practice.iban));
  setVal("px-bic", state.practice.bic);
  document.getElementById("px-note").textContent = "Gespeichert";
}

// Shows one settings pane. The window itself does not need an open chart.
function showSettings(which) {
  ["praxis", "adressen", "bausteine", "gebuehren", "vorlagen"].forEach(function (id) {
    document.getElementById("set-" + id).hidden = id !== which;
  });
  document.querySelectorAll("#praxis .set-nav button").forEach(function (button) {
    button.classList.toggle("on", button.dataset.set === which);
  });
}

// Opens Einstellungen. Praxis, Adressen, Bausteine, Gebühren and Vorlagen live here, away from the chart.
async function openEinstellungen(which) {
  const pane = which || "praxis";
  fillPracticeForm();
  showSettings(pane);
  openWin("praxis");
  if (pane === "adressen") await loadAddressBook();
  if (pane === "bausteine") await loadBausteine();
  if (pane === "gebuehren") await loadSettingsFees();
  if (pane === "vorlagen") await drawSettingsTemplates();
}

// The fee catalog for editing. A click does not charge a patient.
function drawSettingsFees(q) {
  const list = document.getElementById("set-fee-list");
  const note = document.getElementById("set-fee-note");
  clear(list);
  const needle = (q || "").trim().toLowerCase();
  const rows = (catalog || []).filter(function (row) {
    if (!needle) return true;
    return row.code.toLowerCase().indexOf(needle) >= 0 || row.text.toLowerCase().indexOf(needle) >= 0;
  });
  if (!rows.length) {
    list.appendChild(el("p", "hint", needle ? "Nichts gefunden." : "Noch keine Gebühr."));
    return;
  }
  rows.forEach(function (row) {
    const line = el("div", "fee-row");
    const code = el("span", "code", row.code);
    code.title = row.code;
    const text = document.createElement("input");
    text.className = "text";
    text.value = row.text;
    text.maxLength = 200;
    text.setAttribute("aria-label", "Bezeichnung");
    const betrag = document.createElement("input");
    betrag.className = "betrag";
    betrag.value = euro(row.betrag);
    betrag.setAttribute("aria-label", "Einfachsatz");
    const save = el("button", "act tiny", "Speichern");
    save.type = "button";
    save.addEventListener("click", function () {
      api("PATCH", "/api/catalog", { code: row.code, text: text.value, betrag: betrag.value }).then(function (updated) {
        const index = (catalog || []).findIndex(function (item) {
          return item.code.toLowerCase() === updated.code.toLowerCase();
        });
        if (index >= 0) catalog[index] = updated;
        note.textContent = "Gespeichert.";
        drawCatalog(val("pos-search"));
      }).catch(function (err) {
        note.textContent = err.message;
      });
    });
    const remove = el("button", "act tiny", "Entfernen");
    remove.type = "button";
    remove.addEventListener("click", function () {
      api("DELETE", "/api/catalog?code=" + encodeURIComponent(row.code)).then(function () {
        catalog = (catalog || []).filter(function (item) {
          return item.code.toLowerCase() !== row.code.toLowerCase();
        });
        note.textContent = "Aus dem Katalog genommen.";
        drawSettingsFees(val("set-fee-search"));
        drawCatalog(val("pos-search"));
      }).catch(function (err) {
        note.textContent = err.message;
      });
    });
    line.appendChild(code);
    line.appendChild(text);
    line.appendChild(betrag);
    line.appendChild(save);
    line.appendChild(remove);
    list.appendChild(line);
  });
}

function fillStandardFaktor() {
  setVal("set-faktor", standardFaktorText());
}

async function loadSettingsFees() {
  const px = await api("GET", "/api/practice");
  state.practice = Object.assign({}, state.practice || {}, px);
  fillStandardFaktor();
  catalog = await api("GET", "/api/catalog");
  drawSettingsFees(val("set-fee-search"));
}

function standardFaktorText() {
  return String((state.practice && state.practice.standardfaktor) || "").trim();
}

// Empty uses the standard factor. A typed value is used for this charge only.
function chargeFaktorTs() {
  const raw = document.getElementById("pos-faktor").value.trim();
  if (raw) return parseFaktor(raw);
  const standard = standardFaktorText();
  if (standard) return parseFaktor(standard);
  return 1000;
}

// Letter templates can be opened. The invoice wording is edited here. Referrals wait.
async function drawSettingsTemplates() {
  const box = document.getElementById("set-vorlagen-list");
  clear(box);
  const px = await api("GET", "/api/practice");
  state.practice = Object.assign({}, state.practice || {}, px);
  const names = await api("GET", "/api/templates");
  box.appendChild(el("h2", null, "Briefe"));
  if (!names.length) {
    box.appendChild(el("p", "hint", "Noch keine Briefvorlage."));
  }
  names.forEach(function (name) {
    const line = el("div", "rowline");
    line.appendChild(el("span", null, name));
    const open = el("button", "act tiny", "Öffnen");
    open.type = "button";
    open.addEventListener("click", function () {
      const note = document.getElementById("set-vorlagen-note");
      openStored("/api/templates/" + encodeURIComponent(name) + "/datei", name + ".odt", function () {
        return api("POST", "/api/templates/open", { name: name });
      }).then(function (opened) {
        if (note) note.textContent = opened ? "In LibreOffice geöffnet." : "Gespeichert.";
      }).catch(function (err) {
        if (note) note.textContent = err.message;
      });
    });
    line.appendChild(open);
    box.appendChild(line);
  });
  const note = el("p", "hint", "Öffnen ändert die Briefvorlage. Der nächste Brief benutzt die geänderte Datei.");
  note.id = "set-vorlagen-note";
  box.appendChild(note);
  box.appendChild(el("h2", null, "Rechnungen"));
  const area = document.createElement("textarea");
  area.id = "set-rechnung-text";
  area.maxLength = 800;
  area.value = state.practice.rechnung_vorlage || "";
  area.setAttribute("aria-label", "Rechnungstext");
  box.appendChild(area);
  const save = el("button", "act", "Speichern");
  save.type = "button";
  const invoiceNote = el("p", "hint", "Variablen: {Anrede} folgt dem Geschlecht. Weiblich wird zu „Sehr geehrte Frau …“, männlich zu „Sehr geehrter Herr …“. Sonst steht „Guten Tag“. {Nachname} und {Vorname} sind die des Rechnungsempfängers. Leer speichern stellt den vorgegebenen Text wieder her.");
  invoiceNote.id = "set-rechnung-note";
  save.addEventListener("click", function () {
    api("PUT", "/api/practice/rechnung", { text: area.value }).then(function (fresh) {
      state.practice = Object.assign({}, state.practice || {}, fresh);
      area.value = fresh.rechnung_vorlage || "";
      invoiceNote.textContent = fresh.rechnungstext
        ? "Gespeichert. Dieser Text steht auf der Rechnung."
        : "Der vorgegebene Text steht auf der Rechnung.";
    }).catch(function (err) {
      invoiceNote.textContent = err.message;
    });
  });
  box.appendChild(save);
  box.appendChild(invoiceNote);
  headEditor(box, "Rechnungskopf", "rechnungskopf", "Rechnungskopf", "Zeilen über dem Adressfenster. Platzhalter: {{ARZT}} {{FACH}} {{ARZTNUMMER}} {{ADRESSE}} {{TELEFON}} {{TITEL}} {{VORNAME}} {{NAME}} {{DATUM}}. Eine leere Zeile fällt weg. Mehr als etwa fünf Zeilen schneidet der Fensterumschlag ab. Leer speichern stellt den vorgegebenen Kopf wieder her. Positionen, Summe und Gruß bleiben.");
  headEditor(box, "Rezeptkopf", "rezeptkopf", "Rezeptkopf", "Zeilen links oben auf dem Privatrezept. Dieselben Platzhalter. Rechts bleiben das Wort Privatrezept, das Datum und bei mehreren Seiten die Blattzahl. Arzneimittel, Unterschrift und Stempel bleiben. Der Stempel kommt aus den Praxisdaten. Leer speichern stellt den vorgegebenen Kopf wieder her.");
  box.appendChild(el("h2", null, "Überweisungen"));
  box.appendChild(el("p", "hint", "Eine Datei Überweisung.odt im Ordner vorlagen erscheint oben bei den Briefen und lässt sich dort öffnen."));
}

// One letterhead editor. field is rechnungskopf or rezeptkopf. Empty storage prints the built-in lines.
function headEditor(box, title, field, label, hint) {
  box.appendChild(el("h2", null, title));
  const area = document.createElement("textarea");
  area.id = "set-" + field;
  area.maxLength = 400;
  area.value = (state.practice && state.practice[field + "_vorlage"]) || "";
  area.setAttribute("aria-label", label);
  box.appendChild(area);
  const save = el("button", "act", "Speichern");
  save.type = "button";
  const note = el("p", "hint", hint);
  save.addEventListener("click", function () {
    api("PUT", "/api/practice/" + field, { text: area.value }).then(function (fresh) {
      state.practice = Object.assign({}, state.practice || {}, fresh);
      area.value = fresh[field + "_vorlage"] || "";
      note.textContent = fresh[field]
        ? "Gespeichert. Dieser Kopf steht auf dem Papier."
        : "Der vorgegebene Kopf steht auf dem Papier.";
    }).catch(function (err) {
      note.textContent = err.message;
    });
  });
  box.appendChild(save);
  box.appendChild(note);
}

// Practice fields a letterhead may name. An empty value drops a line that holds only that placeholder.
function headValues(px, datum) {
  const nummer = String((px && px.arztnummer) || "").trim();
  return {
    ARZT: doctorLine(px),
    TITEL: String((px && px.titel) || "").trim(),
    VORNAME: String((px && px.vorname) || "").trim(),
    NAME: String((px && px.name) || "").trim(),
    FACH: String((px && px.fach) || "").trim(),
    ADRESSE: String((px && px.adresse) || "").trim(),
    TELEFON: ((px && px.telefone) || []).filter(Boolean).join(" · "),
    ARZTNUMMER: nummer ? "Arztnummer " + nummer : "",
    DATUM: datum || ""
  };
}

// Fills {{ARZT}} and the other head placeholders. Blank lines are left out.
function fillHead(template, px, datum) {
  const values = headValues(px, datum);
  const text = String(template || "").replace(/\{\{(ARZT|TITEL|VORNAME|NAME|FACH|ADRESSE|TELEFON|ARZTNUMMER|DATUM)\}\}/g, function (_match, key) {
    return values[key] || "";
  });
  return text.split("\n").map(function (line) { return line.trim(); }).filter(Boolean).join("\n");
}

// Invoice letterhead. The built-in lines omit the specialty so the address window stays clear.
function invoiceHead(px, datum) {
  const raw = (px && px.rechnungskopf_vorlage) || "{{ARZT}}\n{{ARZTNUMMER}}\n{{ADRESSE}}\n{{TELEFON}}";
  return el("div", "letterhead", fillHead(raw, px, datum) || "Praxisdaten erscheinen hier.");
}

// Heading block of the intake list. The specialty stays off this list.
function intakeHead(px) {
  const lines = [];
  const person = doctorLine(px);
  if (person) lines.push(person);
  if (px.arztnummer) lines.push("Arztnummer " + px.arztnummer);
  if (px.adresse) lines.push(px.adresse);
  if (px.telefone && px.telefone.length) lines.push(px.telefone.join(" · "));
  return el("div", "letterhead", lines.length ? lines.join("\n") : "Praxisdaten erscheinen hier.");
}

// Prescription letterhead. The built-in lines put the specialty directly under the name.
function rxLetterhead(px, datum) {
  const raw = (px && px.rezeptkopf_vorlage) || "{{ARZT}}\n{{FACH}}\n{{ARZTNUMMER}}\n{{ADRESSE}}\n{{TELEFON}}";
  return el("div", "letterhead", fillHead(raw, px, datum) || "Praxisdaten erscheinen hier.");
}

// Signature image for a printed letter or prescription, or nothing when none is stored.
function signBlock(px) {
  const box = el("div", "rx-sign");
  if (px.signature) {
    const img = document.createElement("img");
    img.alt = "";
    img.src = "/api/practice/signature?v=" + (px.signature_mtime || "");
    box.appendChild(img);
  }
  const who = doctorLine(px);
  box.appendChild(el("div", "line", who ? "Unterschrift " + who : "Unterschrift"));
  return box;
}

// Practice lines printed at the foot of a prescription.
function stampBlock(px) {
  const lines = [];
  const person = doctorLine(px);
  if (person) lines.push(person);
  if (px.fach) lines.push(px.fach);
  if (px.arztnummer) lines.push("Arztnummer " + px.arztnummer);
  String(px.adresse || "").split(/\n/).forEach(function (line) {
    if (line.trim()) lines.push(line.trim());
  });
  (px.telefone || []).forEach(function (phone) {
    if (String(phone).trim()) lines.push(String(phone).trim());
  });
  if (!lines.length) return null;
  const box = el("div", "rx-stamp");
  lines.forEach(function (line, i) {
    box.appendChild(i === 0 ? el("strong", null, line) : el("div", null, line));
  });
  return box;
}

// Opens the billing window and loads open positions and unpaid invoices.
async function openBilling() {
  openWin("abrechnung");
  if (!state.patient) return;
  await refreshBilling();
}

// Scrolls the matching chart row into view.
function revealEntry(id) {
  const node = sheet.querySelector('[data-id="' + id + '"]')
    || sheet.querySelector('.entry[data-ids~="' + id + '"]');
  if (node) node.scrollIntoView({ block: "nearest" });
}

// Reloads the billing lists.
async function refreshBilling() {
  const current = document.getElementById("bill-date");
  if (current) billDate = current.value;
  const data = await api("GET", "/api/patients/" + pid() + "/billing");
  const pad = document.getElementById("bill-pad");
  clear(pad);
  pad.appendChild(el("h2", null, "Offene Positionen"));
  const bar = el("div", "inline");
  const date = document.createElement("input");
  date.id = "bill-date";
  date.placeholder = "tt.mm.jjjj";
  date.value = billDate || todayDE();
  date.style.width = "120px";
  date.setAttribute("aria-label", "Konsultationsdatum");
  date.addEventListener("pointerdown", function (ev) { ev.stopPropagation(); });
  const add = el("button", "act", "Position hinzufügen");
  add.type = "button";
  add.addEventListener("click", function () {
    const note = document.getElementById("bill-note");
    if (!date.value.trim()) {
      if (note) note.textContent = "Zuerst das Konsultationsdatum eintragen.";
      date.focus();
      return;
    }
    billDate = date.value.trim();
    positionFromBill = true;
    positionForInvoice = null;
    showCatalog().catch(function (err) { hint.textContent = err.message; });
  });
  bar.appendChild(date);
  bar.appendChild(add);
  pad.appendChild(bar);
  pad.appendChild(el("p", "hint", "Das Datum ist der Tag der Leistung. Es lässt sich danach noch ändern."));
  if (!data.open.length) {
    pad.appendChild(el("p", "hint", "Keine offenen Positionen."));
  } else {
    let sum = 0;
    data.open.forEach(function (row) {
      const line = el("div", "fee-row");
      const date = document.createElement("input");
      date.className = "datum";
      date.value = row.tag_anzeige || "";
      date.setAttribute("aria-label", "Behandlungsdatum");
      date.addEventListener("pointerdown", function (ev) { ev.stopPropagation(); });
      const save = el("button", "act tiny", "Speichern");
      save.type = "button";
      save.addEventListener("click", function () {
        api("PATCH", "/api/patients/" + pid() + "/positions/" + row.id, { datum: date.value }).then(function (fresh) {
          placeEntry(fresh.entry);
          refreshBilling();
        }).catch(function (err) {
          const note = document.getElementById("bill-note");
          if (note) note.textContent = err.message;
        });
      });
      line.appendChild(date);
      line.appendChild(el("span", "code", row.code));
      line.appendChild(el("span", "what", row.text));
      if (row.faktor && row.faktor !== "1") line.appendChild(el("span", null, "× " + row.faktor));
      line.appendChild(el("span", null, euro(row.betrag)));
      line.appendChild(save);
      pad.appendChild(line);
      sum += row.betrag;
    });
    pad.appendChild(el("div", "sum", "Summe " + euro(sum)));
  }
  const bill = el("button", "act primary", "Rechnung drucken");
  bill.type = "button";
  bill.addEventListener("click", makeInvoice);
  pad.appendChild(bill);
  pad.appendChild(el("h2", null, "Rechnungen"));
  if (!data.invoices.length) {
    pad.appendChild(el("p", "hint", "Keine Rechnung."));
    selectedInvoice = null;
  }
  data.invoices.forEach(function (inv) {
    const line = el("div", "rowline");
    if (inv.id === selectedInvoice) line.classList.add("on");
    let stand = inv.bezahlt ? "bezahlt" : "offen";
    if (inv.mahnung_anzeige) stand += " · Mahnung " + inv.mahnung_anzeige;
    line.appendChild(el("span", null, inv.nummer + " · " + (inv.paper_anzeige || inv.datum_anzeige)));
    line.appendChild(el("span", null, euro(inv.betrag) + " · " + stand));
    line.addEventListener("click", function () {
      selectedInvoice = inv.id;
      showInvoice(inv.id);
      refreshBilling();
    });
    pad.appendChild(line);
  });
  const actions = el("div", "gap");
  actions.style.marginTop = "12px";
  const mahnen = el("button", "act", "Mahnung");
  mahnen.type = "button";
  mahnen.addEventListener("click", remindInvoice);
  const bezahlt = el("button", "act", "Bezahlt");
  bezahlt.type = "button";
  bezahlt.addEventListener("click", payInvoice);
  actions.appendChild(mahnen);
  actions.appendChild(bezahlt);
  pad.appendChild(actions);
  pad.appendChild(el("p", "hint", ""));
  pad.lastChild.id = "bill-note";
  pad.lastChild.style.marginTop = "14px";
}

// Turns the open positions into an invoice and shows it.
async function makeInvoice() {
  const note = document.getElementById("bill-note");
  try {
    const inv = await api("POST", "/api/patients/" + pid() + "/invoices");
    selectedInvoice = inv.id;
    await refreshBilling();
    renderInvoice(inv);
    openWin("rechnung");
  } catch (err) {
    if (note) note.textContent = err.message;
    else hint.textContent = err.message;
  }
}

// Loads one invoice and opens the print view.
async function showInvoice(id) {
  const inv = await api("GET", "/api/invoices/" + id);
  renderInvoice(inv);
  openWin("rechnung");
}

// Weiblich and männlich take the German adjective. Divers and an empty value stay "Guten Tag".
function salutation(person) {
  const nach = String((person && person.nachname) || "").trim();
  const sex = String((person && person.geschlecht) || "").trim();
  if (sex === "w") return nach ? "Sehr geehrte Frau " + nach : "Sehr geehrte Frau";
  if (sex === "m") return nach ? "Sehr geehrter Herr " + nach : "Sehr geehrter Herr";
  return "Guten Tag";
}

// One day, or the span from the earliest treatment day to the latest.
function treatmentLabel(lines) {
  const rows = (lines || []).filter(function (row) { return row.tag; });
  if (!rows.length) return "";
  rows.sort(function (a, b) { return a.tag < b.tag ? -1 : a.tag > b.tag ? 1 : 0; });
  const from = rows[0].tag_anzeige || "";
  const to = rows[rows.length - 1].tag_anzeige || "";
  if (rows[0].tag === rows[rows.length - 1].tag) return "Behandlung am " + from;
  return "Behandlung vom " + from + " bis " + to;
}

// Replaces {Anrede}, {Nachname} and {Vorname}. The person is the invoice recipient.
function fillInvoiceText(text, person) {
  const values = {
    anrede: salutation(person),
    nachname: String((person && person.nachname) || "").trim(),
    vorname: String((person && person.vorname) || "").trim()
  };
  return String(text || "").replace(/\{(Anrede|Nachname|Vorname)\}/gi, function (_match, key) {
    return values[key.toLowerCase()] || "";
  });
}

// Greeting on a normal invoice. A reminder keeps the salutation and its own sentence.
function invoiceGreeting(inv) {
  const person = inv.empfaenger || inv.patient || {};
  if (inv.mahnung) {
    const raw = "{Anrede},\n\nzu meiner Rechnung " + inv.nummer + " vom " + (inv.paper_anzeige || inv.datum_anzeige) + " ist der Betrag noch offen. Ich bitte Sie, ihn in den nächsten Tagen zu überweisen.";
    return fillInvoiceText(raw, person);
  }
  const px = inv.practice || {};
  const raw = px.rechnung_vorlage || "{Anrede},\n\nvielen Dank für Ihren Besuch. Für die erbrachten Leistungen stelle ich Ihnen die folgenden Positionen in Rechnung.";
  return fillInvoiceText(raw, person);
}

// Bank lines, or nothing when no IBAN is stored.
function bankBlock(px) {
  const iban = formatIban(px && px.iban);
  if (!iban) return null;
  const lines = ["Ich bitte Sie, den Betrag auf das folgende Konto zu überweisen.", ""];
  const who = doctorLine(px);
  if (who) lines.push(who);
  lines.push("IBAN " + iban);
  const bic = String((px && px.bic) || "").replace(/\s+/g, "").toUpperCase();
  if (bic) lines.push("BIC " + bic);
  return el("p", "inv-bank", lines.join("\n"));
}

// Draws the invoice. The paper shows the service text, never the fee code.
function renderInvoice(inv) {
  const pad = document.getElementById("invoice-pad");
  clear(pad);
  const px = inv.practice || {};
  const page = el("div", "inv-page");
  page.appendChild(invoiceHead(px, mahnung ? (inv.mahnung_anzeige || "") : (inv.paper_anzeige || inv.datum_anzeige || "")));
  const mahnung = !!inv.mahnung;
  const to = inv.empfaenger || inv.patient;
  const row = el("div", "inv-row");
  const addr = el("div", "inv-address");
  addr.appendChild(el("div", "inv-return", doctorLine(px)));
  addr.appendChild(el("div", "rx-muted no-print", "Rechnungsempfänger"));
  addr.appendChild(el("div", "inv-who", letterLines(to)));
  const info = el("div", "inv-info");
  info.appendChild(el("div", "inv-date", mahnung ? (inv.mahnung_anzeige || "") : (inv.paper_anzeige || inv.datum_anzeige || "")));
  if (mahnung) info.appendChild(el("div", null, "Mahnung"));
  if (inv.patient && to && to.id !== inv.patient.id) {
    info.appendChild(el("div", "hint", "Patient: " + labelName(inv.patient)));
  }
  row.appendChild(addr);
  row.appendChild(info);
  page.appendChild(row);
  const body = el("div", "inv-body");
  body.appendChild(el("div", "doc-title", mahnung ? "Mahnung zur Rechnung " + inv.nummer : "Rechnung " + inv.nummer));
  body.appendChild(el("p", "inv-hello", invoiceGreeting(inv)));
  const span = treatmentLabel(inv.lines);
  if (span) body.appendChild(el("p", "inv-span", span));
  const table = el("table", "inv");
  const head = document.createElement("tr");
  head.appendChild(el("th", null, "Datum"));
  head.appendChild(el("th", null, "Leistung"));
  head.appendChild(el("th", "num", "Betrag"));
  table.appendChild(head);
  let sum = 0;
  (inv.lines || []).forEach(function (row) {
    const tr = document.createElement("tr");
    tr.appendChild(el("td", null, row.tag_anzeige || ""));
    const service = el("td");
    service.appendChild(document.createTextNode(row.text || ""));
    if (row.faktor && row.faktor !== "1") {
      service.appendChild(el("div", "inv-faktor", "Faktor " + row.faktor));
    }
    tr.appendChild(service);
    tr.appendChild(el("td", "num", euro(row.betrag) + " €"));
    table.appendChild(tr);
    sum += row.betrag;
  });
  body.appendChild(table);
  body.appendChild(el("div", "sum", "Summe " + euro(sum) + " €"));
  const bank = bankBlock(px);
  if (bank) body.appendChild(bank);
  const close = el("div", "inv-close");
  close.appendChild(el("p", null, "Mit freundlichen Grüßen"));
  if (px.signature) close.appendChild(signBlock(px));
  else {
    const signed = doctorLine(px);
    if (signed) close.appendChild(el("p", null, signed));
  }
  body.appendChild(close);
  page.appendChild(body);
  [["oben", "Falzmarke"], ["mitte", "Lochmarke"], ["unten", "Falzmarke"]].forEach(function (mark) {
    const fold = el("div", "inv-fold " + mark[0]);
    fold.setAttribute("aria-hidden", "true");
    page.appendChild(fold);
  });
  pad.appendChild(page);
  const tools = el("div", "no-print");
  tools.appendChild(el("h2", null, "Ändern"));
  (inv.lines || []).forEach(function (row) {
    const line = el("div", "fee-row");
    line.appendChild(el("span", "code", row.code));
    const date = document.createElement("input");
    date.className = "datum";
    date.value = row.tag_anzeige || "";
    date.setAttribute("aria-label", "Behandlungsdatum");
    const faktor = document.createElement("input");
    faktor.className = "betrag";
    faktor.value = row.faktor || "1";
    faktor.setAttribute("aria-label", "Faktor");
    const save = el("button", "act tiny", "Speichern");
    save.type = "button";
    save.addEventListener("click", function () {
      api("PATCH", "/api/invoices/" + inv.id + "/positions/" + row.id, { faktor: faktor.value, datum: date.value }).then(function (fresh) {
        if (fresh.entry && state.patient && fresh.patient && state.patient.id === fresh.patient.id) placeEntry(fresh.entry);
        renderInvoice(fresh);
      }).catch(function (err) {
        const note = document.getElementById("invoice-note");
        if (note) note.textContent = err.message;
      });
    });
    const off = el("button", "act tiny", "Herausnehmen");
    off.type = "button";
    off.addEventListener("click", function () {
      api("POST", "/api/invoices/" + inv.id + "/positions/" + row.id + "/loesen").then(function (fresh) {
        renderInvoice(fresh);
        if (document.getElementById("abrechnung").classList.contains("show")) refreshBilling();
      }).catch(function (err) {
        const note = document.getElementById("invoice-note");
        if (note) note.textContent = err.message;
      });
    });
    line.appendChild(date);
    line.appendChild(faktor);
    line.appendChild(save);
    line.appendChild(off);
    tools.appendChild(line);
  });
  const add = el("button", "act", "Position hinzufügen");
  add.type = "button";
  add.addEventListener("click", function () {
    positionForInvoice = inv.id;
    positionFromBill = false;
    showCatalog().catch(function (err) {
      const note = document.getElementById("invoice-note");
      if (note) note.textContent = err.message;
    });
  });
  tools.appendChild(add);
  let printed = "Drucken setzt das Datum beim ersten Mal. Ein weiterer Druck behält es. Papier DIN A4, im Dialog Rand keine und ohne Kopfzeile des Browsers, Maßstab 100. Das Adressfeld liegt dann im Fenster.";
  if (!formatIban(px.iban)) printed += " IBAN und BIC stehen in den Stammdaten unter Praxis.";
  const note = el("p", "hint", printed);
  note.id = "invoice-note";
  tools.appendChild(note);
  pad.appendChild(tools);
  const print = el("button", "act primary no-print", "Drucken");
  print.type = "button";
  print.addEventListener("click", function () {
    api("POST", "/api/invoices/" + inv.id + "/druck").then(function (fresh) {
      renderInvoice(fresh);
      printWindow("rechnung");
    }).catch(function (err) {
      const line = document.getElementById("invoice-note");
      if (line) line.textContent = err.message;
    });
  });
  pad.appendChild(print);
}

// Marks the invoice reminded as of today.
async function remindInvoice() {
  if (!selectedInvoice) {
    const note = document.getElementById("bill-note");
    if (note) note.textContent = "Zuerst eine Rechnung auswählen.";
    return;
  }
  const inv = await api("POST", "/api/invoices/" + selectedInvoice + "/mahnung");
  await refreshBilling();
  renderInvoice(inv);
  openWin("rechnung");
}

// Marks the invoice paid as of today.
async function payInvoice() {
  if (!selectedInvoice) {
    const note = document.getElementById("bill-note");
    if (note) note.textContent = "Zuerst eine Rechnung auswählen.";
    return;
  }
  await api("POST", "/api/invoices/" + selectedInvoice + "/bezahlt");
  selectedInvoice = null;
  await refreshBilling();
  const note = document.getElementById("bill-note");
  if (note) note.textContent = "Als bezahlt geführt.";
}

const DOSE_LABELS = ["morgens", "mittags", "abends", "nachts"];

// Splits a dose written as morning-noon-evening-night.
function doseParts(value) {
  const text = value == null ? "" : String(value).trim();
  if (!text) return ["1", "0", "0", "0"];
  const bits = text.split("-");
  if (bits.length === 1) return [bits[0], "0", "0", "0"];
  while (bits.length < 4) bits.push("0");
  if (bits.length > 4) return bits.slice(0, 3).concat([bits.slice(3).join("-")]);
  return bits.slice(0, 4);
}

// Four inputs for that dose.
function doseEditor(value, withLabels) {
  const wrap = el("span", "dose-edit");
  doseParts(value).forEach(function (part, i) {
    const slot = withLabels ? el("label") : el("span");
    if (withLabels) slot.appendChild(document.createTextNode(DOSE_LABELS[i]));
    const input = document.createElement("input");
    input.className = "dose-part";
    input.value = part;
    input.maxLength = 8;
    input.setAttribute("aria-label", DOSE_LABELS[i]);
    input.title = DOSE_LABELS[i];
    input.addEventListener("pointerdown", function (ev) { ev.stopPropagation(); });
    slot.addEventListener("pointerdown", function (ev) { ev.stopPropagation(); });
    slot.appendChild(input);
    wrap.appendChild(slot);
  });
  return wrap;
}

// Fills a dose editor.
function setDose(node, value) {
  const inputs = node.querySelectorAll(".dose-part");
  doseParts(value).forEach(function (part, i) {
    if (inputs[i]) inputs[i].value = part;
  });
}

// Reads a dose editor back into one string.
function readDose(node) {
  const parts = Array.prototype.map.call(node.querySelectorAll(".dose-part"), function (input) {
    return input.value.trim() || "0";
  });
  return parts.join("-").slice(0, 40);
}

// Focuses the first empty dose field, or the first field.
function focusDose(node) {
  const input = node.querySelector(".dose-part");
  if (!input) return;
  input.focus();
  input.select();
}

// A dose editor wired into one medication row.
function doseCell(row) {
  const cell = document.createElement("td");
  const editor = doseEditor(row.dosis, false);
  editor.querySelectorAll(".dose-part").forEach(function (input) {
    input.addEventListener("change", function () {
      api("PATCH", "/api/plan/" + row.id, { dosis: readDose(editor) }).catch(function (err) {
        hint.textContent = err.message;
      });
    });
  });
  cell.appendChild(editor);
  return cell;
}

// Opens the medication plan.
async function openPlan() {
  openWin("medikation");
  if (!state.patient) return;
  planRows = await api("GET", "/api/patients/" + pid() + "/plan");
  renderPlan();
}

// Draws active and stopped medication.
function renderPlan() {
  const pad = document.getElementById("plan-pad");
  clear(pad);
  const draft = el("div");
  draft.id = "plan-draft";
  draft.hidden = true;
  draft.appendChild(el("div", null, ""));
  draft.firstChild.id = "plan-artikel";
  draft.firstChild.style.fontWeight = "650";
  const line = el("div", "inline");
  const typ = document.createElement("select");
  typ.id = "plan-typ";
  ["F", "R", "S"].forEach(function (key) {
    const opt = el("option", null, key + "  " + TYP[key]);
    opt.value = key;
    typ.appendChild(opt);
  });
  const dosis = doseEditor("1-0-0-0", true);
  dosis.id = "plan-dose";
  const start = document.createElement("input");
  start.id = "plan-start";
  start.placeholder = "tt.mm.jjjj";
  start.style.width = "120px";
  const instr = document.createElement("input");
  instr.id = "plan-instr";
  instr.placeholder = "Anwendungsinstruktion";
  const grund = document.createElement("input");
  grund.id = "plan-grund";
  grund.placeholder = "Anwendungsgrund";
  const save = el("button", "act primary", "Übernehmen");
  save.type = "button";
  save.addEventListener("click", savePlan);
  [typ, dosis, start, instr, grund, save].forEach(function (node) { line.appendChild(node); });
  draft.appendChild(line);
  pad.appendChild(draft);
  pad.appendChild(planTable(planRows.active, true));
  pad.appendChild(el("p", "hint", "F Fixmedikation · R Reservemedikation · S symptomatisch. Dosis: morgens, mittags, abends, nachts."));
  const add = el("button", "act", "Hinzufügen");
  add.type = "button";
  add.addEventListener("click", function () {
    medMode = "plan";
    openMeds();
  });
  const list = el("button", "act primary", "Einnahmeliste");
  list.type = "button";
  list.style.marginLeft = "8px";
  list.addEventListener("click", openIntake);
  pad.appendChild(add);
  pad.appendChild(list);
  const stop = el("div", "inline");
  stop.id = "stop-box";
  stop.hidden = true;
  const stopDate = document.createElement("input");
  stopDate.id = "stop-date";
  stopDate.placeholder = "tt.mm.jjjj";
  const stopGrund = document.createElement("input");
  stopGrund.id = "stop-grund";
  stopGrund.placeholder = "Grund";
  const stopDo = el("button", "act", "Stoppen");
  stopDo.type = "button";
  stopDo.addEventListener("click", doStop);
  stop.appendChild(stopDate);
  stop.appendChild(stopGrund);
  stop.appendChild(stopDo);
  pad.appendChild(stop);
  if (planRows.stopped.length) {
    pad.appendChild(el("h2", null, "Beendet"));
    const table = el("table", "plan");
    const head = document.createElement("tr");
    ["Artikel", "Dosis", "Von", "Bis", "Grund"].forEach(function (name) {
      head.appendChild(el("th", null, name));
    });
    const thead = document.createElement("thead");
    thead.appendChild(head);
    table.appendChild(thead);
    const body = document.createElement("tbody");
    planRows.stopped.forEach(function (row) {
      const tr = document.createElement("tr");
      tr.appendChild(el("td", null, row.artikel));
      tr.appendChild(el("td", "dose", row.dosis));
      tr.appendChild(el("td", "date", row.start_anzeige));
      tr.appendChild(el("td", "date", row.stop_anzeige));
      tr.appendChild(el("td", null, row.stop_grund));
      body.appendChild(tr);
    });
    table.appendChild(body);
    pad.appendChild(table);
  }
}

// One medication table. withStop adds the control that ends a line.
function planTable(rows, withStop) {
  const table = el("table", "plan");
  const head = document.createElement("tr");
  ["Typ", "Artikel", "Dosis", "Startdatum", "Anwendungsinstruktion", "Anwendungsgrund", ""].forEach(function (name) {
    head.appendChild(el("th", null, name));
  });
  const thead = document.createElement("thead");
  thead.appendChild(head);
  table.appendChild(thead);
  const body = document.createElement("tbody");
  rows.forEach(function (row) {
    const tr = document.createElement("tr");
    const typ = el("td", "typ", row.typ);
    typ.title = TYP[row.typ] || "";
    tr.appendChild(typ);
    tr.appendChild(el("td", null, row.artikel));
    tr.appendChild(doseCell(row));
    tr.appendChild(el("td", "date", row.start_anzeige));
    tr.appendChild(el("td", null, row.instruktion));
    tr.appendChild(el("td", null, row.grund));
    const cell = document.createElement("td");
    if (withStop) {
      const btn = el("button", "act tiny", "Stoppen");
      btn.type = "button";
      btn.addEventListener("click", function () {
        document.getElementById("stop-box").hidden = false;
        document.getElementById("stop-box").dataset.id = String(row.id);
        document.getElementById("stop-date").value = todayDE();
        document.getElementById("stop-grund").value = "";
        document.getElementById("stop-grund").focus();
      });
      cell.appendChild(btn);
    }
    tr.appendChild(cell);
    body.appendChild(tr);
  });
  table.appendChild(body);
  return table;
}

// Starts a new medication line from a chosen product, or from a blank row.
function showDraft(med) {
  openWin("medikation");
  if (!document.getElementById("plan-draft")) renderPlan();
  const box = document.getElementById("plan-draft");
  box.hidden = false;
  box.dataset.medicine = med.id ? String(med.id) : "";
  document.getElementById("plan-artikel").textContent = med.name;
  const dose = document.getElementById("plan-dose");
  setDose(dose, "1-0-0-0");
  document.getElementById("plan-start").value = todayDE();
  document.getElementById("plan-instr").value = "";
  document.getElementById("plan-grund").value = "";
  focusDose(dose);
}

// Stores the draft line.
async function savePlan() {
  const box = document.getElementById("plan-draft");
  planRows = await api("POST", "/api/patients/" + pid() + "/plan", {
    typ: document.getElementById("plan-typ").value,
    medicine_id: box.dataset.medicine || null,
    artikel: document.getElementById("plan-artikel").textContent,
    dosis: readDose(document.getElementById("plan-dose")),
    start: document.getElementById("plan-start").value,
    instruktion: document.getElementById("plan-instr").value,
    grund: document.getElementById("plan-grund").value
  });
  renderPlan();
}

// Stops the selected medication line.
async function doStop() {
  const id = document.getElementById("stop-box").dataset.id;
  planRows = await api("POST", "/api/plan/" + id + "/stop", {
    stop: document.getElementById("stop-date").value,
    grund: document.getElementById("stop-grund").value
  });
  renderPlan();
}

// Opens the intake list for printing.
async function openIntake() {
  if (!state.patient) return;
  await savePractice();
  planRows = await api("GET", "/api/patients/" + pid() + "/plan");
  const pad = document.getElementById("intake-pad");
  clear(pad);
  pad.appendChild(intakeHead(state.practice));
  pad.appendChild(el("div", "doc-title", "Einnahmeliste"));
  const who = el("div", "who");
  who.style.border = "0";
  who.style.padding = "0 0 8px";
  who.appendChild(document.createTextNode(labelName(state.patient) + " "));
  if (state.patient.geburtsdatum_anzeige) who.appendChild(el("em", null, "geb. " + state.patient.geburtsdatum_anzeige));
  pad.appendChild(who);
  const table = el("table", "plan");
  const head = document.createElement("tr");
  ["Medikament", "Einnahme", "Von bis und mit", "Anwendungsinstruktion", "Anwendungsgrund"].forEach(function (name) {
    head.appendChild(el("th", null, name));
  });
  const thead = document.createElement("thead");
  thead.appendChild(head);
  table.appendChild(thead);
  const body = document.createElement("tbody");
  planRows.active.forEach(function (row) {
    const tr = document.createElement("tr");
    tr.appendChild(el("td", null, row.artikel));
    tr.appendChild(el("td", "dose", row.dosis));
    tr.appendChild(el("td", "date", row.start_anzeige ? "ab " + row.start_anzeige : ""));
    tr.appendChild(el("td", null, row.instruktion));
    tr.appendChild(el("td", null, row.grund));
    body.appendChild(tr);
  });
  table.appendChild(body);
  pad.appendChild(table);
  const print = el("button", "act primary no-print", "Drucken");
  print.type = "button";
  print.style.marginTop = "16px";
  print.addEventListener("click", function () { printWindow("einnahme"); });
  pad.appendChild(print);
  openWin("einnahme");
}

// Opens the medicine search.
function openMeds() {
  const note = document.getElementById("med-mode");
  if (medMode === "plan") note.textContent = "Übernehmen in die Medikation.";
  else if (medMode === "rx") note.textContent = "Auf das Rezept.";
  else note.textContent = "Suchen. Für Plan oder Rezept von dort aus wählen.";
  openWin("medikamente");
  document.getElementById("med-search").focus();
}

// Renders the medicine search.
async function drawMeds(q) {
  const list = document.getElementById("med-list");
  clear(list);
  if (q.trim().length < 2) {
    list.appendChild(el("p", "hint", "Mindestens zwei Buchstaben."));
    return;
  }
  const rows = await api("GET", "/api/medicines?q=" + encodeURIComponent(q.trim()));
  if (!rows.length) {
    list.appendChild(el("p", "hint", "Nichts gefunden."));
    return;
  }
  rows.forEach(function (med) {
    const b = el("button", "pick", med.zulassung ? med.name + "   " + med.zulassung : med.name);
    b.type = "button";
    b.addEventListener("click", function () { chooseMed(med); });
    list.appendChild(b);
  });
}

// Takes a medicine into the plan draft or into the prescription, depending on medMode.
function chooseMed(med) {
  if (medMode === "plan") {
    showDraft(med);
    return;
  }
  if (medMode === "rx") {
    addRxLine(med.name);
    openWin("rezept");
    return;
  }
  hint.textContent = med.name;
}

// Opens the prescription window.
async function openRezept() {
  openWin("rezept");
  await drawRxPlan();
}

// Lists active medication so a line can be copied onto the prescription.
async function drawRxPlan() {
  const box = document.getElementById("rx-plan");
  clear(box);
  box.appendChild(el("p", "hint", "Medikation. Markieren übernimmt das Medikament mit der Dosierung."));
  if (!state.patient) return;
  planRows = await api("GET", "/api/patients/" + pid() + "/plan");
  const active = planRows.active || [];
  if (!active.length) {
    box.appendChild(el("p", "hint", "Keine laufende Medikation."));
    return;
  }
  active.forEach(function (row) {
    const line = el("label", "rx-mark");
    const mark = document.createElement("input");
    mark.type = "checkbox";
    mark.dataset.plan = String(row.id);
    mark.addEventListener("pointerdown", function (ev) { ev.stopPropagation(); });
    mark.checked = !!document.querySelector('#rx-lines .rx-edit[data-plan="' + row.id + '"]');
    mark.addEventListener("change", function () {
      if (mark.checked) addPlanToRx(row);
      else removePlanFromRx(row.id);
    });
    line.appendChild(mark);
    line.appendChild(el("span", null, row.dosis ? row.artikel + "   " + row.dosis : row.artikel));
    box.appendChild(line);
  });
}

// Copies one plan line onto the prescription.
function addPlanToRx(row) {
  if (document.querySelector('#rx-lines .rx-edit[data-plan="' + row.id + '"]')) return;
  addRxLine(row.artikel, { planId: row.id, dosis: row.dosis, anweisung: row.instruktion || "" });
}

// Removes a copied plan line from the draft prescription.
function removePlanFromRx(id) {
  const node = document.querySelector('#rx-lines .rx-edit[data-plan="' + id + '"]');
  if (node) node.remove();
}

// Adds a blank or prefilled prescription line.
function addRxLine(name, extra) {
  extra = extra || {};
  const box = document.getElementById("rx-lines");
  const row = el("div", "rx-edit");
  row.dataset.artikel = name;
  if (extra.planId) row.dataset.plan = String(extra.planId);
  const head = el("div", "rowline");
  head.appendChild(el("span", null, name));
  const remove = el("button", "act tiny", "Entfernen");
  remove.type = "button";
  remove.addEventListener("click", function () {
    const planId = row.dataset.plan;
    row.remove();
    if (planId) {
      const mark = document.querySelector('#rx-plan input[data-plan="' + planId + '"]');
      if (mark) mark.checked = false;
    }
  });
  head.appendChild(remove);
  row.appendChild(head);
  const fields = el("div", "inline");
  const menge = document.createElement("input");
  menge.className = "menge";
  menge.placeholder = "Menge OP";
  menge.style.width = "110px";
  const dosis = doseEditor("1-0-0-0", true);
  dosis.className = "dosis dose-edit";
  const anw = document.createElement("input");
  anw.className = "anw";
  anw.placeholder = "Gebrauchsanweisung";
  anw.style.width = "280px";
  if (extra.anweisung) anw.value = extra.anweisung;
  fields.appendChild(menge);
  fields.appendChild(dosis);
  fields.appendChild(anw);
  row.appendChild(fields);
  box.appendChild(row);
  if (extra.dosis) setDose(dosis, extra.dosis);
  if (!extra.planId) focusDose(dosis);
}

// Reads the draft lines. An empty article is skipped.
function readRxLines() {
  return Array.prototype.map.call(document.querySelectorAll("#rx-lines .rx-edit"), function (row) {
    return {
      artikel: row.dataset.artikel,
      menge: row.querySelector(".menge").value.trim(),
      dosis: readDose(row.querySelector(".dosis")),
      anweisung: row.querySelector(".anw").value.trim()
    };
  });
}

// Stores the prescription and opens the print view.
async function makePrescription() {
  const lines = readRxLines();
  try {
    await savePractice();
    const result = await api("POST", "/api/patients/" + pid() + "/prescriptions", { lines: lines });
    appendEntry(result.entry, false);
    clear(document.getElementById("rx-lines"));
    await drawRxPlan();
    await showPrescription(result.id);
  } catch (err) {
    document.getElementById("rx-note").textContent = err.message;
  }
}

// Loads one prescription and opens the print view.
async function showPrescription(id) {
  const rx = await api("GET", "/api/prescriptions/" + id);
  renderPrescription(rx);
  openWin("privatrezept");
}

// Street and place of a prescription, without the name. The name is its own line.
function rxAddress(p) {
  if (!p) return "";
  const place = [p.plz, p.wohnort].filter(Boolean).join(" ");
  return [p.strasse, place].filter(Boolean).join("\n");
}

// Draws the private prescription. One A4 page holds at most six medicines.
// The practice block at the foot is the stamp. Empty quantity and dose lines are left out.
function renderPrescription(rx) {
  const pad = document.getElementById("rx-sheet");
  clear(pad);
  const px = rx.practice || {};
  const patient = rx.patient || {};
  const pages = [];
  for (let i = 0; i < rx.lines.length; i += 6) pages.push(rx.lines.slice(i, i + 6));
  let number = 0;
  pages.forEach(function (lines, pageIndex) {
    const page = el("div", "rx-page");
    const head = el("div", "rx-head");
    head.appendChild(rxLetterhead(px, rx.datum_anzeige || ""));
    const side = el("div", "rx-side");
    side.appendChild(el("div", "rx-kicker", "Privatrezept"));
    if (rx.datum_anzeige) side.appendChild(el("div", "rx-date", rx.datum_anzeige));
    if (pages.length > 1) side.appendChild(el("div", "rx-muted", "Blatt " + (pageIndex + 1)));
    head.appendChild(side);
    page.appendChild(head);
    const who = el("div", "rx-who-block");
    who.appendChild(el("div", "rx-label", "Patient"));
    who.appendChild(el("div", "rx-name", labelName(patient)));
    const species = patient.species && patient.species !== "mensch" ? SPECIES[patient.species] : "";
    if (species) who.appendChild(el("div", null, species));
    const adr = rxAddress(patient);
    if (adr) who.appendChild(el("div", "rx-address", adr));
    if (patient.geburtsdatum_anzeige) who.appendChild(el("div", null, "geb. " + patient.geburtsdatum_anzeige));
    page.appendChild(who);
    const body = el("div", "rx-body");
    body.appendChild(el("div", "rx-rp", "Rp."));
    lines.forEach(function (line) {
      number += 1;
      const item = el("div", "rx-item");
      item.appendChild(el("strong", null, number + ".  " + (line.artikel || "")));
      if (line.menge) item.appendChild(el("div", null, line.menge + " OP"));
      const use = [];
      if (line.dosis) use.push("S. " + line.dosis);
      if (line.anweisung) use.push(line.anweisung);
      if (use.length) item.appendChild(el("div", "rx-use", use.join("\n")));
      body.appendChild(item);
    });
    page.appendChild(body);
    const foot = el("div", "rx-foot");
    foot.appendChild(signBlock(px));
    const stamp = stampBlock(px);
    if (stamp) foot.appendChild(stamp);
    page.appendChild(foot);
    pad.appendChild(page);
  });
  pad.appendChild(el("p", "hint no-print", "Papier DIN A4. Im Dialog Rand auf keine stellen, die Kopfzeile des Browsers aus und den Maßstab auf 100."));
  const print = el("button", "act primary no-print", "Drucken");
  print.type = "button";
  print.id = "do-print-rx";
  print.addEventListener("click", function () { printWindow("privatrezept"); });
  pad.appendChild(print);
}

// ISO date to dd.mm.yyyy. An empty value stays empty.
function isoDateDE(value) {
  const match = String(value || "").match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (!match) return "";
  return match[3] + "." + match[2] + "." + match[1];
}

// Finds a catalog parameter by name or alias.
function labParamByText(text) {
  const q = String(text || "").trim().toLowerCase();
  if (!q || !laborKatalog) return null;
  return (laborKatalog.parameter || []).find(function (param) {
    if (param.name.toLowerCase() === q) return true;
    return (param.alias || []).some(function (alias) { return String(alias).toLowerCase() === q; });
  }) || null;
}

// One labelled input in the manual lab form.
function labField(id, label, type, value) {
  const wrap = el("div", "field");
  const lab = el("label", null, label);
  lab.htmlFor = id;
  const input = document.createElement("input");
  input.id = id;
  input.type = type;
  input.value = value || "";
  input.autocomplete = "off";
  wrap.appendChild(lab);
  wrap.appendChild(input);
  return wrap;
}

// Inserts a chart row returned by the server and redraws the open lists.
function rememberEntry(entry) {
  if (!entry) return;
  state.chart = (state.chart || []).concat([entry]).sort(function (a, b) {
    if (a.tag !== b.tag) return a.tag < b.tag ? -1 : 1;
    return (a.id || 0) - (b.id || 0);
  });
  renderChart();
}

// Replaces one chart row in place. The file window stays as it is.
function replaceChartEntry(entry) {
  if (!entry) return;
  const rows = state.chart || [];
  const index = rows.findIndex(function (row) { return row.id === entry.id; });
  if (index >= 0) rows[index] = entry;
  else rows.push(entry);
  state.chart = rows;
  renderChart();
}

// Opens the lab sheet.
async function openLabor() {
  openWin("labor");
  const tools = document.getElementById("labor-tools");
  const box = document.getElementById("labor-sheet");
  clear(tools);
  clear(box);
  if (!state.patient) {
    box.appendChild(el("p", "empty", "Kein Patient geöffnet"));
    return;
  }
  const pack = await Promise.all([
    api("GET", "/api/patients/" + pid() + "/labor"),
    api("GET", "/api/labor/parameter")
  ]);
  const data = pack[0];
  laborKatalog = pack[1];
  drawLaborTools();
  box.appendChild(el("p", "hint", "Links die Parameter, nach Gruppen. Jede Spalte ist ein Abnahmedatum, bei Laborbüchern das Analysedatum. Unter dem Ergebnis steht der Normwert. Eine Zeile mit ≈ ist derselbe Wert in der Einheit der Parameterdatei."));
  if (laborReview) drawLaborReview(box);
  if (!data.groups || !data.groups.length) {
    box.appendChild(el("p", "empty", "Keine Laborwerte."));
    return;
  }
  const table = document.createElement("table");
  table.className = "lab";
  const head = document.createElement("thead");
  const headRow = document.createElement("tr");
  headRow.appendChild(el("th", null, "Parameter"));
  (data.dates || []).forEach(function (date) { headRow.appendChild(el("th", null, date.anzeige)); });
  head.appendChild(headRow);
  table.appendChild(head);
  const body = document.createElement("tbody");
  data.groups.forEach(function (group) {
    const banner = document.createElement("tr");
    banner.className = "lab-group";
    const title = el("th", null, group.name);
    title.colSpan = (data.dates || []).length + 1;
    banner.appendChild(title);
    body.appendChild(banner);
    (group.rows || []).forEach(function (row) {
      const tr = document.createElement("tr");
      const th = document.createElement("th");
      th.appendChild(el("div", null, row.name));
      if (!row.parameter_id) {
        const assign = el("button", "tiny", "Zuordnen");
        assign.type = "button";
        assign.addEventListener("click", function () {
          laborAssign = { name: row.name };
          openLabor().catch(function (err) { hint.textContent = err.message; });
        });
        th.appendChild(assign);
      }
      tr.appendChild(th);
      (data.dates || []).forEach(function (date) {
        const td = document.createElement("td");
        const cell = row.cells[date.tag];
        if (cell) {
          (cell.teile || []).forEach(function (part) {
            td.appendChild(el("div", part.flag ? "wert flag" : "wert", part.text));
            if (part.umgerechnet) td.appendChild(el("div", "umger", part.umgerechnet));
          });
          if (cell.norm) td.appendChild(el("div", "norm", cell.norm));
        }
        tr.appendChild(td);
      });
      body.appendChild(tr);
    });
  });
  table.appendChild(body);
  box.appendChild(table);
}

// Manual entry, file reading, and the assignment form.
function drawLaborTools() {
  const tools = document.getElementById("labor-tools");
  clear(tools);
  const form = el("div", "lab-form");
  form.appendChild(labField("lab-date", "Abnahmedatum", "text", todayDE()));
  const nameField = labField("lab-name", "Parameter", "text", "");
  nameField.classList.add("grow");
  const list = document.createElement("datalist");
  list.id = "lab-param-list";
  (laborKatalog.parameter || []).forEach(function (param) {
    const opt = document.createElement("option");
    opt.value = param.name;
    list.appendChild(opt);
  });
  nameField.querySelector("input").setAttribute("list", "lab-param-list");
  nameField.querySelector("input").addEventListener("change", function () {
    const param = labParamByText(this.value);
    if (param && param.einheit) document.getElementById("lab-unit").value = param.einheit;
  });
  form.appendChild(nameField);
  form.appendChild(list);
  form.appendChild(labField("lab-wert", "Ergebnis", "text", ""));
  form.appendChild(labField("lab-unit", "Einheit", "text", ""));
  form.appendChild(labField("lab-norm", "Normwert", "text", ""));
  const flagWrap = el("label", "field");
  flagWrap.style.width = "auto";
  flagWrap.style.flexDirection = "row";
  flagWrap.style.alignItems = "center";
  flagWrap.style.gap = "6px";
  flagWrap.style.height = "30px";
  const flag = document.createElement("input");
  flag.type = "checkbox";
  flag.id = "lab-flag";
  flagWrap.appendChild(flag);
  flagWrap.appendChild(document.createTextNode("auffällig"));
  form.appendChild(flagWrap);
  const save = el("button", "act primary", "Eintragen");
  save.type = "button";
  save.addEventListener("click", function () {
    saveLabManual().catch(function (err) { hint.textContent = err.message; });
  });
  const read = el("button", "act", "Befund lesen");
  read.type = "button";
  read.addEventListener("click", function () { document.getElementById("labor-file").click(); });
  form.appendChild(save);
  form.appendChild(read);
  tools.appendChild(form);
  if (laborAssign) drawLaborAssign(tools);
}

// Form that maps an unknown name onto a catalog parameter.
function drawLaborAssign(tools) {
  const box = el("div", "lab-assign");
  box.appendChild(el("p", "hint", laborAssign.name + " zuordnen. Die Zuordnung wird in parameter/eigene.json gespeichert."));
  box.appendChild(labField("lab-as-name", "Anzeigename", "text", laborAssign.name));
  const groupWrap = el("div", "field");
  const groupLabel = el("label", null, "Gruppe");
  groupLabel.htmlFor = "lab-as-group";
  const group = document.createElement("select");
  group.id = "lab-as-group";
  (laborKatalog.gruppen || []).forEach(function (item) {
    const opt = document.createElement("option");
    opt.value = item.id;
    opt.textContent = item.name;
    group.appendChild(opt);
  });
  groupWrap.appendChild(groupLabel);
  groupWrap.appendChild(group);
  box.appendChild(groupWrap);
  const existWrap = el("div", "field grow");
  const existLabel = el("label", null, "Vorhandener Parameter");
  existLabel.htmlFor = "lab-as-exist";
  const exist = document.createElement("select");
  exist.id = "lab-as-exist";
  const none = document.createElement("option");
  none.value = "";
  none.textContent = "Neu anlegen";
  exist.appendChild(none);
  (laborKatalog.parameter || []).forEach(function (param) {
    const opt = document.createElement("option");
    opt.value = param.id;
    opt.textContent = param.name;
    exist.appendChild(opt);
  });
  exist.addEventListener("change", function () {
    const param = (laborKatalog.parameter || []).find(function (item) { return item.id === exist.value; });
    if (!param) return;
    document.getElementById("lab-as-name").value = param.name;
    document.getElementById("lab-as-group").value = param.gruppe;
    document.getElementById("lab-as-unit").value = param.einheit || "";
  });
  existWrap.appendChild(existLabel);
  existWrap.appendChild(exist);
  box.appendChild(existWrap);
  box.appendChild(labField("lab-as-unit", "Einheit", "text", ""));
  box.appendChild(labField("lab-as-von", "Aus Einheit", "text", ""));
  box.appendChild(labField("lab-as-faktor", "mal Faktor", "text", ""));
  const save = el("button", "act primary", "Zuordnung speichern");
  save.type = "button";
  save.addEventListener("click", function () {
    saveLabAssign().catch(function (err) { hint.textContent = err.message; });
  });
  const cancel = el("button", "act", "Abbrechen");
  cancel.type = "button";
  cancel.addEventListener("click", function () {
    laborAssign = null;
    openLabor().catch(function (err) { hint.textContent = err.message; });
  });
  box.appendChild(save);
  box.appendChild(cancel);
  tools.appendChild(box);
}

// Stores that mapping in parameter/eigene.json.
async function saveLabAssign() {
  const body = {
    name: document.getElementById("lab-as-name").value.trim(),
    gruppe: document.getElementById("lab-as-group").value,
    einheit: document.getElementById("lab-as-unit").value.trim(),
    alias: [laborAssign.name],
    ziel_id: document.getElementById("lab-as-exist").value,
    von: document.getElementById("lab-as-von").value.trim(),
    faktor: document.getElementById("lab-as-faktor").value.trim()
  };
  laborKatalog = await api("POST", "/api/labor/parameter", body);
  laborAssign = null;
  hint.textContent = "Zuordnung gespeichert";
  await openLabor();
}

// Stores values typed by hand. The server writes them only from this confirmed post.
async function saveLabManual() {
  const name = document.getElementById("lab-name").value.trim();
  const wert = document.getElementById("lab-wert").value.trim();
  if (!name || !wert) throw new Error("Parameter und Ergebnis fehlen");
  const data = await api("POST", "/api/patients/" + pid() + "/labor", {
    tag: document.getElementById("lab-date").value.trim(),
    zeilen: [{
      name: name,
      wert: wert,
      einheit: document.getElementById("lab-unit").value.trim(),
      norm: document.getElementById("lab-norm").value.trim(),
      flag: document.getElementById("lab-flag").checked ? "+" : ""
    }]
  });
  rememberEntry(data.eintrag);
  hint.textContent = data.gespeichert + (data.gespeichert === 1 ? " Wert eingetragen" : " Werte eingetragen");
  await openLabor();
}

// Shows rows read from a file. Nothing is stored until Übernehmen.
function drawLaborReview(box) {
  const review = laborReview;
  box.appendChild(el("p", "hint", review.hinweis || ""));
  box.appendChild(labField("lab-read-date", "Abnahmedatum", "text", review.tag_anzeige || todayDE()));
  if (review.auszug) box.appendChild(el("p", "doc", review.auszug));
  const table = document.createElement("table");
  table.className = "lab-lines";
  table.id = "lab-read-rows";
  const head = document.createElement("tr");
  ["", "Parameter", "Ergebnis", "Einheit", "Norm", "Gruppe"].forEach(function (label) {
    head.appendChild(el("th", null, label));
  });
  table.appendChild(head);
  (review.zeilen || []).forEach(function (row) {
    const tr = document.createElement("tr");
    const pick = document.createElement("td");
    const check = document.createElement("input");
    check.type = "checkbox";
    check.checked = true;
    check.className = "lab-take";
    pick.appendChild(check);
    tr.appendChild(pick);
    tr.appendChild(cellInput("name", row.name, row.zeile));
    tr.appendChild(cellInput("wert", row.wert));
    tr.appendChild(cellInput("einheit", row.einheit));
    tr.appendChild(cellInput("norm", row.norm));
    tr.appendChild(el("td", null, row.gruppe_name || ""));
    tr.dataset.flag = row.flag || "";
    table.appendChild(tr);
  });
  box.appendChild(table);
  const bar = el("div", "gap");
  const take = el("button", "act primary", "Übernehmen");
  take.type = "button";
  take.addEventListener("click", function () {
    saveLabReview().catch(function (err) { hint.textContent = err.message; });
  });
  const drop = el("button", "act", "Verwerfen");
  drop.type = "button";
  drop.addEventListener("click", function () {
    laborReview = null;
    openLabor().catch(function (err) { hint.textContent = err.message; });
  });
  bar.appendChild(take);
  bar.appendChild(drop);
  box.appendChild(bar);
}

// One editable cell of the review.
function cellInput(kind, value, title) {
  const td = document.createElement("td");
  const input = document.createElement("input");
  input.value = value || "";
  input.dataset.kind = kind;
  if (title) input.title = title;
  td.appendChild(input);
  return td;
}

// Posts the reviewed rows. Verwerfen never calls this.
async function saveLabReview() {
  const tag = document.getElementById("lab-read-date").value.trim();
  const rows = [];
  document.querySelectorAll("#lab-read-rows tr").forEach(function (tr) {
    const check = tr.querySelector(".lab-take");
    if (!check || !check.checked) return;
    const vals = {};
    tr.querySelectorAll("input[data-kind]").forEach(function (input) {
      vals[input.dataset.kind] = input.value.trim();
    });
    if (!vals.name || !vals.wert) return;
    vals.flag = tr.dataset.flag || "";
    rows.push(vals);
  });
  if (!rows.length) throw new Error("Keine Zeile ausgewählt");
  const data = await api("POST", "/api/patients/" + pid() + "/labor", { tag: tag, zeilen: rows });
  laborReview = null;
  rememberEntry(data.eintrag);
  hint.textContent = data.gespeichert + (data.gespeichert === 1 ? " Wert eingetragen" : " Werte eingetragen");
  await openLabor();
}

// Asks the server to read a file that is already in the chart. The result is a proposal.
async function readStoredLab(id) {
  laborReview = await api("POST", "/api/patients/" + pid() + "/labor/lesen", { file_id: id });
  hint.textContent = "Befund gelesen";
  await openLabor();
}

// Sends a file for reading before it has been stored. The result is a proposal.
async function readLabUpload(file) {
  const result = await api("POST", "/api/patients/" + pid() + "/files", file, {
    "X-Filename": file.name,
    "Content-Type": file.type || "application/octet-stream"
  });
  appendEntry(result.entry, false);
  await readStoredLab(result.file.id);
}

// Opens the file list of the open chart.
async function openFiles(selectId) {
  openWin("dateien");
  if (!state.patient) return;
  const rows = await api("GET", "/api/patients/" + pid() + "/files");
  const list = document.getElementById("file-items");
  clear(list);
  rows.forEach(function (file) {
    const when = isoDateDE(file.created);
    const b = el("button", "pick", when ? file.name + "  " + when : file.name);
    b.type = "button";
    b.dataset.id = String(file.id);
    if (selectId && file.id === selectId) b.classList.add("on");
    b.addEventListener("click", function () {
      selectFile(file, b).catch(function (err) { hint.textContent = err.message; });
    });
    list.appendChild(b);
  });
  const view = document.getElementById("file-view");
  clear(view);
  view.appendChild(el("p", "hint", "Das Original bleibt gespeichert. Auf Deutsch schreibt die Übersetzung darunter."));
  if (selectId) {
    const found = rows.find(function (file) { return file.id === selectId; });
    if (found) selectFile(found, list.querySelector(".on")).catch(function (err) { hint.textContent = err.message; });
  }
}

// Selects a file and loads its preview.
async function selectFile(file, button) {
  currentFile = file;
  document.querySelectorAll("#file-items .pick").forEach(function (b) { b.classList.remove("on"); });
  if (button) button.classList.add("on");
  const view = document.getElementById("file-view");
  clear(view);
  const doc = el("div", "doc");
  const note = el("p", "hint", "Die Datei wird im zugehörigen Programm geöffnet.");
  note.id = "file-open-note";
  doc.appendChild(note);
  const asLab = el("button", "act", "Als Laborbefund lesen");
  asLab.type = "button";
  asLab.addEventListener("click", function () {
    readStoredLab(file.id).catch(function (err) { hint.textContent = err.message; });
  });
  doc.appendChild(asLab);
  view.appendChild(doc);
  const label = el("div", "field");
  const lab = el("label", null, "Deutsch");
  lab.htmlFor = "file-de";
  const area = document.createElement("textarea");
  area.id = "file-de";
  area.value = file.translation || "";
  area.addEventListener("blur", saveTranslation);
  label.appendChild(lab);
  label.appendChild(area);
  view.appendChild(label);
  const deBtn = el("button", "act", "Auf Deutsch");
  deBtn.type = "button";
  deBtn.addEventListener("click", function () {
    deBtn.disabled = true;
    translateFile().catch(function (err) {
      const note = document.getElementById("file-open-note");
      if (note) note.textContent = err.message;
    }).finally(function () { deBtn.disabled = false; });
  });
  view.appendChild(deBtn);
  const into = el("button", "act primary", "In die Akte");
  into.type = "button";
  into.addEventListener("click", translationToChart);
  view.appendChild(into);
  try {
    const opened = await openStored("/api/files/" + file.id + "/raw", file.name, function () {
      return api("POST", "/api/files/" + file.id + "/open");
    });
    if (currentFile !== file) return;
    note.textContent = opened ? "Geöffnet im zugehörigen Programm." : "Kein Programm hat die Datei geöffnet.";
    if (!opened) showFilePreview(doc, file);
  } catch (err) {
    if (currentFile !== file) return;
    note.textContent = err.message;
    showFilePreview(doc, file);
  }
}

// Shows the file, or the reading, inside the window.
function showFilePreview(doc, file) {
  if (file.mime && file.mime.indexOf("image/") === 0 && file.mime !== "image/x-pcx") {
    const img = document.createElement("img");
    img.alt = "";
    img.src = "/api/files/" + file.id + "/raw";
    doc.appendChild(img);
  } else if (file.mime === "application/pdf") {
    const frame = document.createElement("iframe");
    frame.title = file.name;
    frame.src = "/api/files/" + file.id + "/raw";
    doc.appendChild(frame);
  }
  const link = el("a", "open-file", file.mime && file.mime.indexOf("image/") === 0 ? "Bild öffnen" : "Datei öffnen");
  link.href = "/api/files/" + file.id + "/raw";
  link.target = "_blank";
  link.rel = "noopener";
  doc.appendChild(link);
}

// Saves the reading on the file. It does not copy it into the chart.
async function saveTranslation() {
  if (!currentFile) return;
  const text = document.getElementById("file-de").value;
  const result = await api("PATCH", "/api/files/" + currentFile.id, { translation: text });
  currentFile = result.file;
  if (result.entry) replaceChartEntry(result.entry);
}

// Reads the selected letter and stores the German draft under the file name.
async function translateFile() {
  if (!currentFile) return;
  const id = currentFile.id;
  const note = document.getElementById("file-open-note");
  if (note) note.textContent = "Übersetze…";
  const result = await api("POST", "/api/files/" + id + "/deutsch");
  if (!currentFile || currentFile.id !== id) return;
  currentFile = result.file;
  const area = document.getElementById("file-de");
  if (area) area.value = currentFile.translation || "";
  if (result.entry) replaceChartEntry(result.entry);
  if (note) note.textContent = "Deutsch steht unter dem Original. Bitte gegenlesen.";
}

// Copies the reading into a Befund for today.
async function translationToChart() {
  if (!currentFile) return;
  const text = document.getElementById("file-de").value;
  const result = await api("PATCH", "/api/files/" + currentFile.id, { translation: text, into_chart: true });
  currentFile = result.file;
  if (result.chart) {
    state.chart = result.chart;
    renderChart();
  }
  hint.textContent = "In die Akte übernommen";
}

// Uploads a file into the open chart.
async function uploadFile(file) {
  const result = await api("POST", "/api/patients/" + pid() + "/files", file, {
    "X-Filename": file.name,
    "Content-Type": file.type || "application/octet-stream"
  });
  appendEntry(result.entry, false);
  await openFiles(result.file.id);
}

// Opens the letter window. The recipient list is the address book plus the open chart.
async function openLetters() {
  openWin("briefe");
  paintLetterPicks();
  try {
    addresses = await api("GET", "/api/adressen");
  } catch (err) {
    addresses = addresses || [];
  }
  paintLetterAddresses();
  if (!state.patient) return;
  const names = await api("GET", "/api/templates");
  const list = document.getElementById("letter-list");
  clear(list);
  names.forEach(function (name) {
    const b = el("button", "pick", name);
    b.type = "button";
    if (name === letterTemplate) b.classList.add("on");
    b.addEventListener("click", function () {
      letterTemplate = name;
      document.querySelectorAll("#letter-list .pick").forEach(function (btn) { btn.classList.remove("on"); });
      b.classList.add("on");
      if (!val("letter-betreff")) setVal("letter-betreff", name);
    });
    list.appendChild(b);
  });
  if (!letterTemplate && names.length) letterTemplate = names[0];
  paintLetterPicks();
}

const LETTER_KINDS = { A: 1, B: 1, D: 1, DD: 1, CAVE: 1, PR: 1, I: 1, L: 1 };

// Chart rows that can be copied into a letter. Empty rows are left out.
function letterPieces() {
  const out = [];
  (state.chart || []).forEach(function (entry) {
    const view = viewKind(entry);
    if (!LETTER_KINDS[entry.kind] && !LETTER_KINDS[view]) return;
    const raw = (view === "D" || view === "DD") ? diagnosisLine(entry.text || "") : (entry.text || "");
    const text = String(raw).trim();
    if (!text) return;
    out.push({
      id: entry.id,
      title: (entry.tag_anzeige || "") + "  " + (entry.label || chartTag(entry)),
      text: text
    });
  });
  return out;
}

function paintLetterPicks() {
  const box = document.getElementById("letter-picks");
  if (!box) return;
  clear(box);
  const pieces = letterPieces();
  if (!pieces.length) {
    box.appendChild(el("p", "hint", state.patient
      ? "In der offenen Kartei steht kein Text, den ein Brief übernehmen kann."
      : "Keine Akte geöffnet."));
    return;
  }
  pieces.forEach(function (piece) {
    const row = el("div", "letter-row");
    const boxIn = document.createElement("input");
    boxIn.type = "checkbox";
    boxIn.value = String(piece.id);
    boxIn.dataset.text = piece.title + "\n" + piece.text;
    const span = el("span");
    span.appendChild(el("b", "", piece.title));
    span.appendChild(document.createTextNode("\n" + piece.text));
    row.appendChild(boxIn);
    row.appendChild(span);
    box.appendChild(row);
  });
}

// Appends the ticked chart rows to the letter. A second click appends again.
function takeLetterPieces() {
  const area = document.getElementById("letter-text");
  const blocks = [];
  document.querySelectorAll("#letter-picks input:checked").forEach(function (box) {
    blocks.push(box.dataset.text || "");
  });
  if (!blocks.length) {
    document.getElementById("letter-note").textContent = "Zuerst Zeilen ankreuzen.";
    return;
  }
  const add = blocks.join("\n\n");
  area.value = area.value.trim() ? area.value.replace(/\s+$/, "") + "\n\n" + add : add;
}

// Fills the chosen template. LibreOffice opens on this computer.
async function writeLetter() {
  const note = document.getElementById("letter-note");
  try {
    await savePractice();
    const payload = {
      vorlage: letterTemplate,
      betreff: val("letter-betreff"),
      text: val("letter-text"),
      ungarisch: document.getElementById("letter-hu").checked
    };
    const empf = val("letter-adresse");
    if (empf) payload.adresse_id = Number(empf);
    const result = await api("POST", "/api/patients/" + pid() + "/letters", payload);
    appendEntry(result.entry, false);
    const file = result.name || String(result.path || "").split("/").pop();
    const opened = await openStored(result.holen || ("/api/letters/" + result.id + "/datei"), file, function () {
      return api("POST", "/api/letters/" + result.id + "/open");
    });
    note.textContent = (opened ? "In LibreOffice geöffnet. " : "Gespeichert. ") + file;
    setVal("letter-text", "");
  } catch (err) {
    note.textContent = err.message;
  }
}

// Loads the address book. Search filters the list on this page. The letter menu keeps every row.
async function loadAddressBook() {
  addresses = await api("GET", "/api/adressen");
  drawAddresses();
  paintLetterAddresses();
}

function foldAddress(value) {
  return String(value || "").toLowerCase()
    .replace(/ä/g, "ae").replace(/ö/g, "oe").replace(/ü/g, "ue").replace(/ß/g, "ss");
}

function addressLines(row) {
  const lines = [];
  if (row.anrede) lines.push(row.anrede);
  if (row.name) lines.push(row.name);
  if (row.zusatz) lines.push(row.zusatz);
  if (row.strasse) lines.push(row.strasse);
  const place = [row.plz, row.ort].filter(Boolean).join(" ");
  if (place) lines.push(place);
  return lines.join("\n");
}

function drawAddresses() {
  const list = document.getElementById("adr-list");
  if (!list) return;
  clear(list);
  const needle = foldAddress(val("adr-search"));
  const rows = addresses.filter(function (row) {
    if (!needle) return true;
    const blob = foldAddress([row.art_label, row.anrede, row.name, row.zusatz, row.strasse, row.plz, row.ort, row.telefon, row.notiz].join(" "));
    return blob.indexOf(needle) >= 0;
  });
  if (!rows.length) {
    list.appendChild(el("p", "hint", needle ? "Nichts gefunden." : "Noch keine Adresse."));
    return;
  }
  rows.forEach(function (row) {
    const button = el("button", "pick wrap");
    button.type = "button";
    if (addressEdit === row.id) button.classList.add("on");
    button.appendChild(el("b", "", row.name));
    const place = [row.art_label || "Sonstige", row.ort].filter(Boolean).join(" · ");
    if (place) button.appendChild(el("span", "hint", place));
    button.addEventListener("click", function () { fillAddressForm(row); });
    list.appendChild(button);
  });
}

function clearAddressForm() {
  addressEdit = null;
  setVal("adr-art", "arzt");
  ["adr-anrede", "adr-name", "adr-zusatz", "adr-strasse", "adr-plz", "adr-ort", "adr-telefon", "adr-notiz"].forEach(function (id) {
    setVal(id, "");
  });
  document.getElementById("adr-heading").textContent = "Neue Adresse";
  document.getElementById("adr-save").textContent = "Aufnehmen";
  document.getElementById("adr-delete").hidden = true;
  drawAddresses();
}

function fillAddressForm(row) {
  addressEdit = row.id;
  setVal("adr-art", row.art || "sonst");
  setVal("adr-anrede", row.anrede || "");
  setVal("adr-name", row.name || "");
  setVal("adr-zusatz", row.zusatz || "");
  setVal("adr-strasse", row.strasse || "");
  setVal("adr-plz", row.plz || "");
  setVal("adr-ort", row.ort || "");
  setVal("adr-telefon", row.telefon || "");
  setVal("adr-notiz", row.notiz || "");
  document.getElementById("adr-heading").textContent = "Adresse ändern";
  document.getElementById("adr-save").textContent = "Speichern";
  document.getElementById("adr-delete").hidden = false;
  drawAddresses();
}

function addressPayload() {
  return {
    art: val("adr-art"),
    anrede: val("adr-anrede"),
    name: val("adr-name"),
    zusatz: val("adr-zusatz"),
    strasse: val("adr-strasse"),
    plz: val("adr-plz"),
    ort: val("adr-ort"),
    telefon: val("adr-telefon"),
    notiz: val("adr-notiz")
  };
}

async function saveAddress() {
  const note = document.getElementById("adr-note");
  const saved = addressEdit
    ? await api("PATCH", "/api/adressen/" + addressEdit, addressPayload())
    : await api("POST", "/api/adressen", addressPayload());
  note.textContent = "Gespeichert.";
  await loadAddressBook();
  fillAddressForm(saved);
}

async function deleteAddress() {
  if (!addressEdit) return;
  await api("DELETE", "/api/adressen/" + addressEdit);
  clearAddressForm();
  document.getElementById("adr-note").textContent = "Entfernt. Geschriebene Briefe bleiben.";
  await loadAddressBook();
}

function paintLetterAddresses() {
  const select = document.getElementById("letter-adresse");
  if (!select) return;
  const keep = select.value;
  clear(select);
  const patient = document.createElement("option");
  patient.value = "";
  patient.textContent = "Patient";
  select.appendChild(patient);
  addresses.forEach(function (row) {
    const opt = document.createElement("option");
    opt.value = String(row.id);
    opt.textContent = [row.art_label || "Sonstige", row.name, row.ort].filter(Boolean).join(" · ");
    select.appendChild(opt);
  });
  const still = Array.prototype.some.call(select.options, function (opt) { return opt.value === keep; });
  select.value = still ? keep : "";
  showLetterAddress();
}

function showLetterAddress() {
  const note = document.getElementById("letter-adresse-note");
  const select = document.getElementById("letter-adresse");
  if (!note || !select) return;
  if (!select.value) {
    note.textContent = "Der Brief geht an die Anschrift in der Akte.";
    return;
  }
  const row = addresses.find(function (item) { return String(item.id) === select.value; });
  if (!row) {
    note.textContent = "Adresse nicht gefunden.";
    return;
  }
  note.textContent = addressLines(row) + "\nName und Geburtsdatum des Patienten stehen rechts.";
}

// Reads a visit file from erfassen.html. The open chart stays as it is.
async function importBesuche(file) {
  const raw = await file.text();
  let data;
  try {
    data = JSON.parse(raw);
  } catch (err) {
    throw new Error("Die Datei ist kein gültiger Besuch.");
  }
  const result = await api("POST", "/api/besuche", data);
  const offen = (result.offen || []).length;
  const note = document.getElementById("pat-count");
  if (note) {
    let line = result.uebernommen + " übernommen, " + result.neu + " neu";
    if (offen === 1) line += ". " + result.offen[0].grund;
    else if (offen) line += ", " + offen + " offen";
    note.textContent = line;
  }
}

// Opens the fee catalog.
async function showCatalog() {
  if (!catalog) catalog = await api("GET", "/api/catalog");
  drawCatalog(val("pos-search"));
  openWin("positionen");
  const who = document.getElementById("pos-who");
  const datum = document.getElementById("pos-datum");
  if (positionFromBill) {
    const bill = (document.getElementById("bill-date") || {}).value || billDate;
    datum.value = String(bill || "").trim() || todayDE();
  } else if (!datum.value.trim()) {
    datum.value = todayDE();
  }
  who.textContent = datum.value.trim();
  document.getElementById("pos-search").focus();
}

// Renders the fee search. The amount shown is the simple fee.
function drawCatalog(q) {
  const list = document.getElementById("pos-list");
  const note = document.getElementById("pos-faktor-note");
  clear(list);
  const rawFaktor = document.getElementById("pos-faktor").value.trim();
  const ts = chargeFaktorTs();
  if (ts == null) {
    note.textContent = "Faktor zwischen 0,001 und 20, zum Beispiel 2,3.";
    return;
  }
  if (!rawFaktor) {
    const standard = standardFaktorText();
    note.textContent = standard
      ? "Leer übernimmt den Standardfaktor " + standard + "."
      : "Leer bedeutet Faktor 1.";
  } else {
    note.textContent = ts === 1000
      ? "Faktor 1 übernimmt den Katalogbetrag."
      : "Faktor " + formatFaktor(ts) + ". Der Betrag ist der einfache Satz mal Faktor.";
  }
  const needle = (q || "").trim().toLowerCase();
  (catalog || []).filter(function (row) {
    if (!needle) return true;
    return row.code.toLowerCase().indexOf(needle) >= 0 || row.text.toLowerCase().indexOf(needle) >= 0;
  }).forEach(function (row) {
    const charge = chargeCents(row.betrag, ts);
    const price = ts === 1000
      ? euro(row.betrag)
      : euro(row.betrag) + " × " + formatFaktor(ts) + " = " + euro(charge);
    const b = el("button", "pick", row.code + "   " + row.text + "   " + price);
    b.type = "button";
    b.dataset.code = row.code;
    b.dataset.charge = String(charge);
    b.addEventListener("click", function () {
      postPosition(row.code).catch(function (err) {
        hint.textContent = err.message;
        const noteBill = document.getElementById("bill-note");
        if (noteBill) noteBill.textContent = err.message;
      });
    });
    list.appendChild(b);
  });
}

// Puts a chart row into date order and redraws. A fee for an earlier day does not stay at the bottom.
function placeEntry(entry) {
  if (!entry) return;
  const rows = (state.chart || []).filter(function (row) { return row.id !== entry.id; });
  rows.push(entry);
  rows.sort(function (a, b) {
    if (a.tag !== b.tag) return a.tag < b.tag ? -1 : 1;
    return (a.id || 0) - (b.id || 0);
  });
  state.chart = rows;
  renderChart();
  revealEntry(entry.id);
}

// Adds a catalog fee to the open chart. An unknown code is not created.
async function postPosition(code, faktorText, datumText) {
  const body = { code: code };
  if (faktorText != null) {
    if (String(faktorText).trim()) body.faktor = String(faktorText).trim();
  } else {
    const raw = document.getElementById("pos-faktor").value.trim();
    if (raw) {
      if (parseFaktor(raw) == null) {
        document.getElementById("pos-faktor-note").textContent = "Faktor zwischen 0,001 und 20, zum Beispiel 2,3.";
        document.getElementById("pos-faktor").focus();
        return null;
      }
      body.faktor = raw;
    }
  }
  if (datumText) body.datum = String(datumText).trim();
  else if (faktorText == null) {
    const field = document.getElementById("pos-datum");
    if (field && field.value.trim()) body.datum = field.value.trim();
  }
  if (positionForInvoice) {
    const invoiceId = positionForInvoice;
    positionForInvoice = null;
    positionFromBill = false;
    const inv = await api("POST", "/api/invoices/" + invoiceId + "/positionen", body);
    closeWin("positionen");
    renderInvoice(inv);
    openWin("rechnung");
    if (inv.entry && state.patient && inv.patient && state.patient.id === inv.patient.id) placeEntry(inv.entry);
    return inv;
  }
  if (!body.datum && positionFromBill) {
    const input = document.getElementById("bill-date");
    body.datum = (input ? input.value : billDate).trim();
  }
  const entry = await api("POST", "/api/patients/" + pid() + "/positions", body);
  positionFromBill = false;
  closeWin("positionen");
  placeEntry(entry);
  if (document.getElementById("abrechnung").classList.contains("show")) await refreshBilling();
  hint.textContent = entry.label + "  " + entry.text;
  return entry;
}

// Posts a new text row of the given kind for today.
async function addText(kind, focusKind, label, text) {
  const body = { kind: kind, text: text || "" };
  if (label) body.label = label;
  const entry = await api("POST", "/api/patients/" + pid() + "/entries", body);
  state.chart = (state.chart || []).concat([entry]);
  const win = document.getElementById("text-" + kind);
  const kindOpen = !!(win && win.classList.contains("show"));
  appendEntry(entry, !focusKind);
  if (kindOpen) {
    renderKind(kind);
    const box = document.getElementById("text-sheet-" + kind);
    if (box) box.scrollTop = box.scrollHeight;
    if (focusKind && /^\d+$/.test(String(entry.id))) {
      const node = document.querySelector('#text-sheet-' + kind + ' .body[data-entry="' + entry.id + '"]');
      if (node) node.focus();
    }
  }
  hint.textContent = label || TEXT[kind];
}

// Draws the shortcut list and the form for an own shortcut.
function drawKuerzel() {
  const list = document.getElementById("kuerzel-list");
  clear(list);
  const table = el("table");
  KUERZEL.forEach(function (pair) {
    const tr = document.createElement("tr");
    tr.appendChild(el("td", "code", pair[0]));
    tr.appendChild(el("td", null, pair[1]));
    table.appendChild(tr);
  });
  list.appendChild(table);
  if (bausteine.length) {
    list.appendChild(el("h2", null, "Textbausteine"));
    const blocks = el("table");
    bausteine.forEach(function (row) {
      const tr = document.createElement("tr");
      tr.appendChild(el("td", "code", bausteinCommand(row)));
      tr.appendChild(el("td", null, (TEXT[row.kind] || row.kind) + ": " + row.text));
      blocks.appendChild(tr);
    });
    list.appendChild(blocks);
  }
  const own = document.getElementById("kuerzel-eigene");
  clear(own);
  if (!eigene.length) {
    own.appendChild(el("p", "hint", "Noch kein eigenes Kürzel."));
    return;
  }
  eigene.forEach(function (row) {
    const line = el("div", "rowline");
    line.appendChild(el("span", null, row.code + "  " + row.label));
    const button = el("button", "act tiny", "Entfernen");
    button.type = "button";
    button.addEventListener("click", function () {
      api("DELETE", "/api/kuerzel/" + encodeURIComponent(row.code)).then(function (data) {
        eigene = data.kuerzel || [];
        drawKuerzel();
      }).catch(function (err) {
        document.getElementById("kuerzel-note").textContent = err.message;
      });
    });
    line.appendChild(button);
    own.appendChild(line);
  });
}

// Loads own shortcuts from the server.
async function loadKuerzel() {
  const data = await api("GET", "/api/kuerzel");
  eigene = data.kuerzel || [];
}

// Opens the shortcut window. The footer field keeps the id kuerzel. This window is kuerzelliste.
async function openKuerzel() {
  await loadKuerzel();
  await loadBausteine();
  drawKuerzel();
  openWin("kuerzelliste");
}

// The command shown in the shortcut list. A unique code is typed alone.
// Diagnose and Dauerdiagnose keep D and DD for the catalog, so those blocks are named without that prefix.
function bausteinCommand(row) {
  const same = bausteine.filter(function (item) {
    return String(item.kuerzel || "").toUpperCase() === String(row.kuerzel || "").toUpperCase();
  });
  if (same.length > 1 && row.kind !== "D" && row.kind !== "DD") return row.kind + " " + row.kuerzel;
  return row.kuerzel;
}

// Loads the practice text blocks. The footer and Tab use this list.
async function loadBausteine() {
  const data = await api("GET", "/api/bausteine");
  bausteine = Array.isArray(data) ? data : [];
  if (document.getElementById("bau-list")) drawBausteine();
}

function drawBausteine() {
  const list = document.getElementById("bau-list");
  if (!list) return;
  clear(list);
  const needle = foldAddress(val("bau-search"));
  const rows = bausteine.filter(function (row) {
    if (!needle) return true;
    const blob = foldAddress([TEXT[row.kind], row.kuerzel, row.text].join(" "));
    return blob.indexOf(needle) >= 0;
  });
  if (!rows.length) {
    list.appendChild(el("p", "hint", needle ? "Nichts gefunden." : "Noch kein Textbaustein."));
    return;
  }
  rows.forEach(function (row) {
    const button = el("button", "pick wrap");
    button.type = "button";
    if (bausteinEdit === row.id) button.classList.add("on");
    button.appendChild(el("b", "", row.kuerzel));
    button.appendChild(el("span", "hint", TEXT[row.kind] || row.kind));
    button.appendChild(el("span", "hint", row.text));
    button.addEventListener("click", function () { fillBausteinForm(row); });
    list.appendChild(button);
  });
}

function clearBausteinForm() {
  bausteinEdit = null;
  setVal("bau-kind", "A");
  setVal("bau-code", "");
  setVal("bau-text", "");
  document.getElementById("bau-heading").textContent = "Neuer Textbaustein";
  document.getElementById("bau-save").textContent = "Aufnehmen";
  document.getElementById("bau-delete").hidden = true;
  drawBausteine();
}

function fillBausteinForm(row) {
  bausteinEdit = row.id;
  setVal("bau-kind", row.kind || "A");
  setVal("bau-code", row.kuerzel || "");
  setVal("bau-text", row.text || "");
  document.getElementById("bau-heading").textContent = "Textbaustein ändern";
  document.getElementById("bau-save").textContent = "Speichern";
  document.getElementById("bau-delete").hidden = false;
  drawBausteine();
}

async function saveBaustein() {
  const payload = {
    kind: val("bau-kind"),
    kuerzel: val("bau-code"),
    text: val("bau-text")
  };
  const saved = bausteinEdit
    ? await api("PATCH", "/api/bausteine/" + bausteinEdit, payload)
    : await api("POST", "/api/bausteine", payload);
  document.getElementById("bau-note").textContent = "Gespeichert.";
  await loadBausteine();
  const row = bausteine.find(function (item) { return item.id === saved.id; }) || saved;
  fillBausteinForm(row);
  if (document.getElementById("kuerzelliste").classList.contains("show")) drawKuerzel();
}

async function deleteBaustein() {
  if (!bausteinEdit) return;
  await api("DELETE", "/api/bausteine/" + bausteinEdit);
  clearBausteinForm();
  document.getElementById("bau-note").textContent = "Entfernt. Geschriebene Einträge bleiben.";
  await loadBausteine();
  if (document.getElementById("kuerzelliste").classList.contains("show")) drawKuerzel();
}

// Writes the block in the form into the open chart. The shortcut list is not required for this button.
async function useBaustein() {
  const text = val("bau-text").trim();
  if (!text) throw new Error("Text fehlt.");
  if (!state.patient) throw new Error("Zuerst eine Akte öffnen.");
  await addText(val("bau-kind"), false, null, text);
  document.getElementById("bau-note").textContent = "In die Akte geschrieben.";
}

// Finds every block whose shortcut is this whole command.
function bausteineNamed(code) {
  const up = String(code || "").toUpperCase();
  return bausteine.filter(function (row) { return String(row.kuerzel || "").toUpperCase() === up; });
}

// Inserts one stored block. A missing block writes nothing.
async function insertBaustein(kind, code) {
  const row = bausteine.find(function (item) {
    return item.kind === kind && String(item.kuerzel || "").toUpperCase() === String(code || "").toUpperCase();
  });
  if (!row) {
    hint.textContent = "Kein Textbaustein " + code + " in der Rubrik " + (TEXT[kind] || kind) + ".";
    return;
  }
  await addText(kind, false, null, row.text);
  hint.textContent = (TEXT[kind] || kind) + "  " + row.kuerzel;
}

// Same shortcut in two rubrics. The footer asks for the rubric and writes nothing.
function bausteinClash(rows) {
  const names = rows.map(function (row) { return TEXT[row.kind] || row.kind; });
  let msg = "Das Kürzel steht in mehreren Rubriken: " + names.join(", ") + ".";
  const prefixed = rows.filter(function (row) { return row.kind !== "D" && row.kind !== "DD"; });
  if (prefixed.length) {
    msg += " Die Rubrik davor setzen, zum Beispiel " + prefixed[0].kind + " " + prefixed[0].kuerzel + ".";
  }
  if (rows.some(function (row) { return row.kind === "D" || row.kind === "DD"; })) {
    msg += " Bei Diagnose und Dauerdiagnose das Kürzel in der Zeile mit Tab einsetzen oder in den Einstellungen auf In die Akte.";
  }
  return msg;
}

// Draws the diagnosis search and the form for an own row.
function drawDiagnosen(rows) {
  const list = document.getElementById("dx-list");
  clear(list);
  if (!rows.length) {
    const q = val("dx-search").trim();
    const note = q.length === 1 ? "Mindestens zwei Zeichen." : (q ? "Nichts gefunden." : "Noch keine eigene Diagnose. Oben suchen, zum Beispiel einen ICD-Code.");
    list.appendChild(el("p", "hint", note));
    return;
  }
  rows.forEach(function (row) {
    const line = el("div", "rowline");
    const button = el("button", "pick wrap");
    button.type = "button";
    button.appendChild(document.createTextNode(row.code + "   " + row.kurz));
    if (row.lang) {
      const sub = el("span", "hint", row.lang);
      button.appendChild(sub);
    }
    button.addEventListener("click", function () {
      postDiagnose(row.code).catch(function (err) {
        document.getElementById("dx-note").textContent = err.message;
      });
    });
    line.appendChild(button);
    if (row.quelle === "eigen") {
      const remove = el("button", "act tiny", "Entfernen");
      remove.type = "button";
      remove.addEventListener("click", function () {
        api("DELETE", "/api/diagnosen?code=" + encodeURIComponent(row.code)).then(function () {
          return loadDiagnosen(val("dx-search"));
        }).catch(function (err) {
          document.getElementById("dx-note").textContent = err.message;
        });
      });
      line.appendChild(remove);
    }
    list.appendChild(line);
  });
}

// Runs the diagnosis search.
async function loadDiagnosen(query) {
  const data = await api("GET", "/api/diagnosen?q=" + encodeURIComponent(query || ""));
  drawDiagnosen(data.diagnosen || []);
}

// Opens the diagnosis catalog.
async function openDiagnosen() {
  openWin("diagnosen");
  await loadDiagnosen(val("dx-search"));
  document.getElementById("dx-search").focus();
}

// Flips the Dauer flag. The server keeps the code and rewrites a plain Dauerdiagnose label when clearing it.
async function toggleDauer(entry) {
  const data = await api("PATCH", "/api/entries/" + entry.id, { dauer: !isDauer(entry) });
  const rows = state.chart || [];
  const index = rows.findIndex(function (row) { return row.id === entry.id; });
  if (index >= 0) rows[index] = data;
  const top = sheet.scrollTop;
  renderWho();
  renderChart();
  sheet.scrollTop = top;
  hint.textContent = data.dauer ? "Dauerdiagnose" : "Diagnose";
}

// Copies one catalog row into the chart. The second argument asks for a Dauerdiagnose.
async function postDiagnose(code, dauer) {
  const entry = await api("POST", "/api/patients/" + pid() + "/diagnosen", { code: code, dauer: !!dauer });
  state.chart = (state.chart || []).concat([entry]);
  const kind = dauer ? "DD" : "D";
  const win = document.getElementById("text-" + kind);
  appendEntry(entry, false);
  if (win && win.classList.contains("show")) renderKind(kind);
  hint.textContent = (dauer ? "Dauerdiagnose " : "Diagnose ") + entry.label;
  const note = document.getElementById("dx-note");
  if (note) note.textContent = "ICD-10-GM 2026, BfArM, Stand 12.09.2025. D und der Kode schreiben die Zeile in die Akte. Eine eigene Zeile gilt vor demselben Kode.";
  return entry;
}

// Footer command. The comparison is the uppercased text, so DD CODE is handled before D CODE.
// A trailing plus opens the list of that kind. An own shortcut inserts an Info. ? opens this list.
async function run(raw) {
  const up = raw.trim().toUpperCase();
  field.value = "";
  if (!up) return;
  try {
    if (up === "?") {
      hint.textContent = "Kürzel";
      await openKuerzel();
      return;
    }
    const gathered = up.match(/^([A-Z]+)\+$/);
    if (gathered && TEXT[gathered[1]]) {
      hint.textContent = "Alle " + TEXT_ALL[gathered[1]];
      openKind(gathered[1]);
      return;
    }
    if (TEXT[up]) {
      await addText(up);
      return;
    }
    if (up === "AB") { hint.textContent = "Abrechnung"; await openBilling(); return; }
    if (up === "M") { hint.textContent = "Medikamente"; medMode = "browse"; openMeds(); return; }
    if (up === "RP") { hint.textContent = "Rezept"; await openRezept(); return; }
    if (up === "DA") { hint.textContent = "Dateien"; await openFiles(); return; }
    if (up === "LB") { hint.textContent = "Labor"; await openLabor(); return; }
    if (up === "BRIEFE") { hint.textContent = "Briefe"; await openLetters(); return; }
    if (up === "ST") { hint.textContent = "Stammdaten"; editCurrent(); return; }
    if (up === "MP") { hint.textContent = "Medikation"; await openPlan(); return; }
    if (up === "PX") { hint.textContent = "Einstellungen"; await openEinstellungen("praxis"); return; }
    if (up === "TER") { hint.textContent = "Termine"; await openTermine(); return; }
    if (up === "WZ") { hint.textContent = "Wartezimmer"; await openWarte(); return; }
    if (up === "P") { hint.textContent = "Patienten"; await openPatients(); return; }
    if (up === "NEU") { hint.textContent = "Neu aufnehmen"; editNew(); return; }
    if (up === "ZI") {
      positionFromBill = false;
      positionForInvoice = null;
      hint.textContent = "Abrechnungsposition";
      await showCatalog();
      return;
    }
    if (up === "DK") {
      hint.textContent = "Diagnosen";
      await openDiagnosen();
      return;
    }
    if (up.indexOf("DD ") === 0) {
      await postDiagnose(up.replace(/^DD\s+/, ""), true);
      return;
    }
    if (up.indexOf("D ") === 0) {
      await postDiagnose(up.replace(/^D\s+/, ""), false);
      return;
    }
    if (up.indexOf("ZI ") === 0) {
      positionFromBill = false;
      positionForInvoice = null;
      const rest = up.replace(/^ZI\s+/, "").trim();
      const parts = rest.split(/\s+/);
      let datum = "";
      if (parts.length >= 2 && /^\d{1,2}\.\d{1,2}\.\d{4}$/.test(parts[parts.length - 1])) datum = parts.pop();
      let code = parts.join(" ");
      let faktor = "";
      if (parts.length >= 2 && parseFaktor(parts[parts.length - 1]) != null) {
        faktor = parts.pop();
        code = parts.join(" ");
      }
      await postPosition(code, faktor, datum);
      return;
    }
    const prefixed = up.match(/^(A|B|CAVE|PR|I|L)\s+([A-Z0-9]{1,16})$/);
    if (prefixed) {
      await insertBaustein(prefixed[1], prefixed[2]);
      return;
    }
    const named = bausteineNamed(up);
    if (named.length === 1) {
      await insertBaustein(named[0].kind, named[0].kuerzel);
      return;
    }
    if (named.length > 1) {
      hint.textContent = bausteinClash(named);
      return;
    }
    const own = eigene.find(function (row) { return row.code === up; });
    if (own) {
      await addText("I", false, own.label);
      return;
    }
    hint.textContent = "Unbekanntes Kürzel. ? zeigt die Liste.";
  } catch (err) {
    hint.textContent = err.message;
  }
}

// Prints one window. The print style hides the others.
function printWindow(id) {
  document.querySelectorAll(".win").forEach(function (win) { win.classList.remove("print-on"); });
  document.getElementById(id).classList.add("print-on");
  window.print();
}

// Monday of the week that contains this local date. The practice week starts on Monday.
function mondayOf(date) {
  const day = new Date(date.getFullYear(), date.getMonth(), date.getDate());
  const shift = day.getDay() === 0 ? -6 : 1 - day.getDay();
  day.setDate(day.getDate() + shift);
  return day;
}

function isoFromDate(date) {
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return date.getFullYear() + "-" + month + "-" + day;
}

function clockMin(value) {
  const match = /^(\d{1,2}):(\d{2})$/.exec(String(value || ""));
  if (!match) return null;
  const hour = Number(match[1]);
  const minute = Number(match[2]);
  if (hour > 23 || minute > 59) return null;
  return hour * 60 + minute;
}

function formatClock(minutes) {
  const hour = Math.floor(minutes / 60);
  const minute = minutes % 60;
  return String(hour).padStart(2, "0") + ":" + String(minute).padStart(2, "0");
}

// TER opens the week even when no chart is open. Booking uses the open chart and does not switch it.
async function openTermine() {
  if (!termWeek) termWeek = mondayOf(new Date());
  if (!state.patient) termMode = "block";
  termSetup = false;
  const setup = document.getElementById("term-setup");
  if (setup) setup.textContent = "Einrichten";
  openWin("termine");
  await loadTermine();
}

async function loadTermine() {
  const status = document.getElementById("term-status");
  const from = isoFromDate(termWeek);
  const end = new Date(termWeek.getTime());
  end.setDate(end.getDate() + 6);
  const to = isoFromDate(end);
  try {
    termData = await api("GET", "/api/termine?von=" + encodeURIComponent(from) + "&bis=" + encodeURIComponent(to));
  } catch (err) {
    if (status) status.textContent = err.message;
    return;
  }
  document.getElementById("term-week").textContent = isoDateDE(from) + " – " + isoDateDE(to);
  const raster = document.getElementById("term-raster");
  termQuiet = true;
  raster.value = String(termData.raster || 10);
  termQuiet = false;
  fillUrlaubChoices();
  markTermMode();
  paintTermine();
}

function markTermMode() {
  const book = document.getElementById("term-book");
  const block = document.getElementById("term-block");
  const open = !!(state.patient);
  book.disabled = !open;
  if (!open) termMode = "block";
  book.classList.toggle("on", open && termMode === "termin");
  block.classList.toggle("on", termMode === "block");
}

function fillUrlaubChoices() {
  const select = document.getElementById("term-url-res");
  const previous = select.value || "alle";
  clear(select);
  const all = el("option", "", "Alle Ressourcen");
  all.value = "alle";
  select.appendChild(all);
  (termData.ressourcen || []).forEach(function (res) {
    const option = el("option", "", res.name);
    option.value = String(res.id);
    select.appendChild(option);
  });
  select.value = previous;
  if (select.value !== previous) select.value = "alle";
}

function termStatus(text) {
  const node = document.getElementById("term-status");
  if (node) node.textContent = text;
}

function visibleResources() {
  const rows = termData && termData.ressourcen ? termData.ressourcen : [];
  const used = {};
  (termData.termine || []).forEach(function (item) {
    if (item.ressource_id) used[item.ressource_id] = true;
  });
  return rows.filter(function (res) { return res.aktiv || used[res.id]; });
}

function termScale(resources) {
  let start = null;
  let end = null;
  resources.forEach(function (res) {
    (res.zeiten || []).forEach(function (span) {
      const von = clockMin(span.von);
      const bis = clockMin(span.bis);
      if (von == null || bis == null) return;
      if (start == null || von < start) start = von;
      if (end == null || bis > end) end = bis;
    });
  });
  if (start == null || end == null || end <= start) return [8 * 60, 18 * 60];
  return [start, end];
}

function termClashes(items) {
  const marked = {};
  const timed = items.filter(function (item) { return item.patient_id && !item.ganztaegig && item.von && item.bis; });
  for (let i = 0; i < timed.length; i += 1) {
    for (let j = i + 1; j < timed.length; j += 1) {
      const left = timed[i];
      const right = timed[j];
      if (left.patient_id !== right.patient_id || left.ressource_id === right.ressource_id) continue;
      if (left.tag !== right.tag) continue;
      const a0 = clockMin(left.von);
      const a1 = clockMin(left.bis);
      const b0 = clockMin(right.von);
      const b1 = clockMin(right.bis);
      if (a0 == null || b0 == null) continue;
      if (a0 < b1 && b0 < a1) {
        marked[left.id] = true;
        marked[right.id] = true;
      }
    }
  }
  return marked;
}

function terminCaption(item) {
  if (item.ganztaegig) return item.notiz || "Geschlossen";
  if (item.name) return item.name;
  return item.notiz || "Block";
}

function paintTermine() {
  const sheet = document.getElementById("term-sheet");
  clear(sheet);
  markTerminSelection();
  paintWarteOnWeek(sheet);
  if (termSetup) {
    paintTermSetup(sheet);
    return;
  }
  const resources = visibleResources();
  if (!resources.length) {
    sheet.appendChild(el("p", "empty", "Zuerst unter Einrichten eine Ressource und ihre Zeiten anlegen."));
    return;
  }
  const withoutHours = resources.filter(function (res) { return !(res.zeiten || []).length; });
  if (withoutHours.length) {
    const names = withoutHours.map(function (res) { return res.name; }).join(", ");
    sheet.appendChild(el("p", "empty", names + (withoutHours.length === 1 ? " hat" : " haben") + " noch keine Öffnungszeiten. Unter Einrichten Anfang und Ende eintragen und Speichern. Ohne Zeiten bleibt die Woche geschlossen."));
  }
  const raster = termData.raster || 10;
  const scale = termScale(resources);
  const scale0 = scale[0];
  const scale1 = scale[1];
  const slotPx = 16;
  const height = Math.max(160, ((scale1 - scale0) / raster) * slotPx);
  const clashes = termClashes(termData.termine || []);
  const board = el("div", "term-board");
  board.style.minWidth = (52 + 7 * Math.max(resources.length, 1) * 36) + "px";
  const legend = el("div", "term-legend");
  resources.forEach(function (res, index) {
    const key = el("span", "term-key");
    const swatch = el("i", "term-sw");
    swatch.style.background = TERM_COLORS[index % TERM_COLORS.length];
    key.appendChild(swatch);
    key.appendChild(document.createTextNode(res.name));
    legend.appendChild(key);
  });
  board.appendChild(legend);
  const head = el("div", "term-head");
  head.appendChild(el("div", "term-gutter"));
  const body = el("div", "term-body");
  const gutter = el("div", "term-gutter");
  gutter.style.height = height + "px";
  for (let minute = Math.ceil(scale0 / 60) * 60; minute <= scale1; minute += 60) {
    const mark = el("div", "term-hour", formatClock(minute));
    mark.style.top = ((minute - scale0) / (scale1 - scale0) * height) + "px";
    gutter.appendChild(mark);
  }
  body.appendChild(gutter);
  for (let offset = 0; offset < 7; offset += 1) {
    const day = new Date(termWeek.getTime());
    day.setDate(day.getDate() + offset);
    const iso = isoFromDate(day);
    const headCell = el("div", "term-dayhead");
    headCell.appendChild(el("div", "term-dayname", TERM_DAYS[offset] + " " + isoDateDE(iso).slice(0, 6)));
    const names = el("div", "term-lanes");
    const column = el("div", "term-day");
    column.style.height = height + "px";
    resources.forEach(function (res, index) {
      const color = TERM_COLORS[index % TERM_COLORS.length];
      const title = el("div", "term-lanename", res.name);
      title.style.borderTopColor = color;
      title.title = res.name;
      names.appendChild(title);
      column.appendChild(termLane(res, iso, color, scale0, scale1, height, clashes));
    });
    headCell.appendChild(names);
    head.appendChild(headCell);
    body.appendChild(column);
  }
  board.appendChild(head);
  board.appendChild(body);
  sheet.appendChild(board);
}

function termLane(res, iso, color, scale0, scale1, height, clashes) {
  const lane = el("div", "term-lane");
  const span = scale1 - scale0;
  (res.zeiten || []).forEach(function (hours) {
    const weekday = ((new Date(iso + "T12:00:00").getDay() + 6) % 7) + 1;
    if (Number(hours.wochentag) !== weekday) return;
    const von = clockMin(hours.von);
    const bis = clockMin(hours.bis);
    if (von == null || bis == null || bis <= von) return;
    const open = el("div", "term-open");
    open.style.top = ((von - scale0) / span * 100) + "%";
    open.style.height = ((bis - von) / span * 100) + "%";
    lane.appendChild(open);
  });
  for (let minute = Math.ceil(scale0 / 60) * 60; minute < scale1; minute += 60) {
    const line = el("div", "term-line");
    line.style.top = ((minute - scale0) / span * 100) + "%";
    lane.appendChild(line);
  }
  (termData.termine || []).forEach(function (item) {
    if (item.tag > iso || item.bis_tag < iso) return;
    if (!item.alle && item.ressource_id !== res.id) return;
    const node = el("div", "term-item");
    let top = 0;
    let high = 100;
    if (item.ganztaegig) {
      node.classList.add("shut");
    } else {
      const von = clockMin(item.von);
      const bis = clockMin(item.bis);
      if (von == null || bis == null) return;
      top = (von - scale0) / span * 100;
      high = (bis - von) / span * 100;
      node.classList.add(item.patient_id ? "apt" : "block");
      if (item.patient_id) node.style.background = color + "33";
    }
    node.style.top = top + "%";
    node.style.height = Math.max(high, 0) + "%";
    const here = (warteRows || []).some(function (row) { return row.termin_id === item.id; });
    if (clashes[item.id]) node.classList.add("clash");
    if (here) node.classList.add("da");
    if (termSelected === item.id) node.classList.add("on");
    const caption = terminCaption(item);
    const when = item.ganztaegig ? "ganzer Tag" : (item.von + "–" + item.bis);
    let extra = "";
    if (clashes[item.id]) extra += ", zur selben Zeit auch woanders";
    if (here) extra += ", da";
    node.title = caption + ", " + when + extra;
    if (high / 100 * height >= 14) node.textContent = caption;
    node.addEventListener("click", function (ev) {
      ev.stopPropagation();
      termSelected = item.id;
      termStatus(node.title);
      paintTermine();
    });
    lane.appendChild(node);
  });
  lane.addEventListener("click", function (ev) {
    if (ev.target.closest(".term-item")) return;
    const rect = lane.getBoundingClientRect();
    if (!rect.height) return;
    const ratio = (ev.clientY - rect.top) / rect.height;
    const minute = scale0 + ratio * span;
    const start = Math.floor(minute / (termData.raster || 10)) * (termData.raster || 10);
    bookSlot(res, iso, start);
  });
  return lane;
}

async function bookSlot(res, iso, start) {
  if (termBusy) return;
  const raster = termData.raster || 10;
  const dauer = parseInt(document.getElementById("term-dauer").value, 10);
  if (!dauer || dauer < raster || dauer % raster !== 0) {
    termStatus("Die Dauer folgt dem Raster.");
    return;
  }
  if (start < 0 || start + dauer > 24 * 60) {
    termStatus("Das Ende liegt nach Mitternacht.");
    return;
  }
  if (termMode === "termin" && !state.patient) {
    termStatus("Ohne Akte lässt sich nur blocken.");
    return;
  }
  const body = {
    ressource_id: res.id,
    tag: iso,
    von: formatClock(start),
    bis: formatClock(start + dauer)
  };
  if (termMode === "termin") body.patient_id = state.patient.id;
  termBusy = true;
  try {
    await api("POST", "/api/termine", body);
    termSelected = null;
    termStatus(termMode === "termin" ? "Termin gelegt." : "Geblockt.");
    await loadTermine();
  } catch (err) {
    termStatus(err.message);
  } finally {
    termBusy = false;
  }
}

async function addUrlaub() {
  if (termBusy) return;
  const choice = document.getElementById("term-url-res").value || "alle";
  const body = {
    ganztaegig: true,
    tag: document.getElementById("term-url-von").value,
    bis_tag: document.getElementById("term-url-bis").value,
    notiz: document.getElementById("term-url-note").value.trim() || "Urlaub",
    alle: choice === "alle"
  };
  if (choice !== "alle") body.ressource_id = Number(choice);
  termBusy = true;
  try {
    await api("POST", "/api/termine", body);
    termSelected = null;
    termStatus("Geblockt.");
    await loadTermine();
  } catch (err) {
    termStatus(err.message);
  } finally {
    termBusy = false;
  }
}

function paintTermSetup(sheet) {
  const pad = el("div", "pad");
  const add = el("div", "term-add");
  const name = document.createElement("input");
  name.className = "term-time";
  name.style.width = "220px";
  name.maxLength = 80;
  name.placeholder = "Neue Ressource";
  name.setAttribute("aria-label", "Neue Ressource");
  const addButton = el("button", "act", "Anlegen");
  addButton.type = "button";
  addButton.addEventListener("click", function () { createRessource(name.value); });
  add.appendChild(name);
  add.appendChild(addButton);
  pad.appendChild(add);
  pad.appendChild(el("p", "term-note", "Jede Ressource hat eigene Zeiten. Ein Tag kann zwei Abschnitte haben, dazwischen liegt die Pause. Anfang und Ende liegen auf dem Raster."));
  (termData.ressourcen || []).forEach(function (res) { pad.appendChild(ressourceEditor(res)); });
  sheet.appendChild(pad);
}

function timeField(value) {
  const input = document.createElement("input");
  input.className = "term-time";
  input.placeholder = "08:00";
  input.value = value || "";
  input.setAttribute("aria-label", "Uhrzeit");
  return input;
}

function ressourceEditor(res) {
  const box = el("div", "term-res");
  const head = el("div", "term-res-head");
  const name = document.createElement("input");
  name.className = "term-time";
  name.style.width = "220px";
  name.maxLength = 80;
  name.value = res.name;
  const active = document.createElement("input");
  active.type = "checkbox";
  active.checked = !!res.aktiv;
  const label = el("label", "term-check");
  label.appendChild(active);
  label.appendChild(document.createTextNode(" aktiv"));
  const save = el("button", "act primary", "Speichern");
  save.type = "button";
  const remove = el("button", "act", "Entfernen");
  remove.type = "button";
  head.appendChild(name);
  head.appendChild(label);
  head.appendChild(save);
  head.appendChild(remove);
  box.appendChild(head);
  const days = [];
  TERM_DAYS.forEach(function (caption, index) {
    const weekday = index + 1;
    const spans = (res.zeiten || []).filter(function (row) { return Number(row.wochentag) === weekday; });
    const row = el("div", "term-dayrow");
    row.appendChild(el("span", "term-dow", caption));
    const fields = [
      timeField(spans[0] && spans[0].von),
      timeField(spans[0] && spans[0].bis),
      timeField(spans[1] && spans[1].von),
      timeField(spans[1] && spans[1].bis)
    ];
    row.appendChild(fields[0]);
    row.appendChild(document.createTextNode("–"));
    row.appendChild(fields[1]);
    row.appendChild(fields[2]);
    row.appendChild(document.createTextNode("–"));
    row.appendChild(fields[3]);
    days.push({ weekday: weekday, fields: fields });
    box.appendChild(row);
  });
  save.addEventListener("click", function () {
    const zeiten = [];
    days.forEach(function (day) {
      const values = day.fields.map(function (field) { return field.value.trim(); });
      if (values[0] || values[1]) zeiten.push({ wochentag: day.weekday, von: values[0], bis: values[1] });
      if (values[2] || values[3]) zeiten.push({ wochentag: day.weekday, von: values[2], bis: values[3] });
    });
    saveRessource(res.id, name.value, active.checked, zeiten);
  });
  remove.addEventListener("click", function () { removeRessource(res.id); });
  return box;
}

async function createRessource(name) {
  try {
    await api("POST", "/api/ressourcen", { name: name });
    termSetup = true;
    termStatus("Angelegt.");
    await loadTermine();
  } catch (err) {
    termStatus(err.message);
  }
}

async function saveRessource(id, name, aktiv, zeiten) {
  try {
    await api("PATCH", "/api/ressourcen/" + id, { name: name, aktiv: aktiv, zeiten: zeiten });
    termSetup = true;
    termStatus("Gespeichert.");
    await loadTermine();
  } catch (err) {
    termStatus(err.message);
  }
}

async function removeRessource(id) {
  try {
    await api("DELETE", "/api/ressourcen/" + id);
    termSetup = true;
    termStatus("Entfernt.");
    await loadTermine();
  } catch (err) {
    termStatus(err.message);
  }
}

// Shows Aufheben, and Anwesend when the selected block belongs to a patient.
function markTerminSelection() {
  const drop = document.getElementById("term-drop");
  const arrive = document.getElementById("term-arrive");
  const item = selectedTermin();
  if (drop) drop.hidden = !item;
  if (!arrive) return;
  const can = !!(item && item.patient_id && !item.ganztaegig);
  arrive.hidden = !can;
  if (!can) return;
  const here = (warteRows || []).find(function (row) { return row.patient_id === item.patient_id && row.termin_id === item.id; });
  arrive.disabled = !!here;
  arrive.textContent = here ? "Ist da" : "Anwesend";
}

function selectedTermin() {
  if (!termData || !termSelected) return null;
  return (termData.termine || []).find(function (row) { return row.id === termSelected; }) || null;
}

// The call order, above the week. Someone without an appointment is marked. A click opens that chart.
function paintWarteOnWeek(sheet) {
  if (!(warteRows || []).length) return;
  const line = el("div", "term-wait");
  line.appendChild(el("span", "term-waitlabel", "Warteliste"));
  warteRows.forEach(function (row, index) {
    const person = el("span", "term-waitperson");
    const up = el("button", "act tiny term-waitmove", "Hoch");
    up.type = "button";
    up.disabled = index === 0;
    up.addEventListener("click", function () { moveWarte(row.id, "hoch"); });
    const down = el("button", "act tiny term-waitmove", "Runter");
    down.type = "button";
    down.disabled = index === warteRows.length - 1;
    down.addEventListener("click", function () { moveWarte(row.id, "runter"); });
    const label = row.warteliste ? row.name + " (ohne Termin)" : row.name;
    const btn = el("button", "term-waitname", label);
    btn.type = "button";
    btn.title = "Akte öffnen";
    btn.addEventListener("click", function () {
      openPatient(row.patient_id).catch(function (err) { hint.textContent = err.message; });
    });
    person.appendChild(up);
    person.appendChild(btn);
    person.appendChild(down);
    line.appendChild(person);
  });
  sheet.appendChild(line);
}

function warteSig(rows) {
  return (rows || []).map(function (row) {
    return row.id + ":" + (row.termin_id || 0) + ":" + row.gekommen + ":" + (row.reihe || 0);
  }).join("|");
}

function warteQueryOk(text) {
  if (/^\d+$/.test(text)) return true;
  return text.length >= 2;
}

// The strip is always visible. A name opens the chart. × only leaves the room.
function paintWarteStrip() {
  const box = document.getElementById("warte-names");
  if (!box) return;
  clear(box);
  if (!warteRows.length) {
    box.appendChild(el("span", "warte-empty", "Niemand da"));
    paintInWarte();
    return;
  }
  warteRows.forEach(function (row) {
    const chip = el("span", row.warteliste ? "warte-chip wait" : "warte-chip");
    const name = el("button", "warte-name", row.name);
    name.type = "button";
    name.title = row.warteliste ? "Warteliste, Akte öffnen" : ((row.termin || "Termin") + ", Akte öffnen");
    name.addEventListener("click", function () {
      openPatient(row.patient_id).catch(function (err) { hint.textContent = err.message; });
    });
    const gone = el("button", "warte-x", "×");
    gone.type = "button";
    gone.title = "Gegangen";
    gone.setAttribute("aria-label", "Gegangen");
    gone.addEventListener("click", function (ev) {
      ev.stopPropagation();
      leaveWarte(row.id);
    });
    chip.appendChild(name);
    chip.appendChild(gone);
    box.appendChild(chip);
  });
  paintInWarte();
}

// In WZ follows the open chart. It adds that chart and does not open another one.
function paintInWarte() {
  const btn = document.getElementById("warte-add");
  if (!btn) return;
  const open = state.patient;
  const already = !!(open && (warteRows || []).some(function (row) { return row.patient_id === open.id; }));
  btn.disabled = !open || already;
  btn.textContent = already ? "Im WZ" : "In WZ";
  if (!open) btn.title = "Zuerst eine Akte aufrufen.";
  else if (already) btn.title = "Ist schon im Wartezimmer.";
  else btn.title = "Den aufgerufenen Patienten ans Ende der Warteliste setzen.";
}

// The same people, inside the WZ window. Gegangen does not delete the appointment.
function paintWarteHere() {
  const box = document.getElementById("warte-here");
  if (!box) return;
  clear(box);
  if (!warteRows.length) {
    box.appendChild(el("p", "hint", "Niemand da."));
    return;
  }
  warteRows.forEach(function (row, index) {
    const line = el("div", "rowline");
    const text = el("div", "");
    const open = el("button", "warte-openchart", row.name);
    open.type = "button";
    open.title = "Akte öffnen";
    open.addEventListener("click", function () {
      openPatient(row.patient_id).catch(function (err) { hint.textContent = err.message; });
    });
    const head = el("div", "");
    head.appendChild(el("span", "warte-pos", String(row.reihe || index + 1)));
    head.appendChild(open);
    text.appendChild(head);
    const where = row.warteliste ? "ohne Termin" : (row.termin || "Termin");
    text.appendChild(el("div", "term-note", where + "  " + row.gekommen));
    const moves = el("span", "warte-moves");
    const up = el("button", "act tiny", "Hoch");
    up.type = "button";
    up.disabled = index === 0;
    up.addEventListener("click", function () { moveWarte(row.id, "hoch"); });
    const down = el("button", "act tiny", "Runter");
    down.type = "button";
    down.disabled = index === warteRows.length - 1;
    down.addEventListener("click", function () { moveWarte(row.id, "runter"); });
    moves.appendChild(up);
    moves.appendChild(down);
    const gone = el("button", "act tiny", "Gegangen");
    gone.type = "button";
    gone.addEventListener("click", function () { leaveWarte(row.id); });
    line.appendChild(text);
    line.appendChild(moves);
    line.appendChild(gone);
    box.appendChild(line);
  });
}

function paintWarteHits() {
  const hits = document.getElementById("warte-hits");
  if (!hits) return;
  clear(hits);
  const shown = warteHits.slice(0, 30);
  shown.forEach(function (person) {
    const line = el("button", "rowline warte-hit");
    line.type = "button";
    if (wartePick && wartePick.id === person.id) line.classList.add("on");
    const nr = person.nummer != null ? String(person.nummer) : "";
    line.textContent = [nr, labelName(person), person.geburtsdatum_anzeige || ""].filter(Boolean).join("   ");
    line.addEventListener("click", function () {
      wartePick = person;
      paintWarteHits();
      loadAngebot().catch(function (err) {
        document.getElementById("warte-note").textContent = err.message;
      });
    });
    hits.appendChild(line);
  });
  if (warteHits.length > shown.length) hits.appendChild(el("p", "hint", "Mehr eingrenzen."));
}

// Search does not create a chart and does not open one. Two letters, or a chart number.
async function searchWarte(q) {
  const seq = ++warteSeq;
  const note = document.getElementById("warte-note");
  const text = String(q || "").trim();
  if (!warteQueryOk(text)) {
    warteHits = [];
    paintWarteHits();
    if (text) note.textContent = "Mindestens zwei Buchstaben oder eine Nummer.";
    return;
  }
  let rows;
  try {
    rows = await api("GET", "/api/patients?q=" + encodeURIComponent(text));
  } catch (err) {
    if (seq !== warteSeq) return;
    note.textContent = err.message;
    return;
  }
  if (seq !== warteSeq) return;
  warteHits = rows || [];
  paintWarteHits();
  if (!warteHits.length) note.textContent = "Zuerst aufnehmen.";
  else if (warteHits.length === 1) note.textContent = "1 Treffer. Auswählen, die Akte bleibt.";
  else note.textContent = warteHits.length + " Treffer. Auswählen, die Akte bleibt.";
}

// Today's appointments and the next free stretches. The duration follows the practice raster.
async function loadAngebot() {
  if (!wartePick) return;
  const dauer = document.getElementById("warte-dauer").value;
  const data = await api("GET", "/api/wartezimmer/angebot?patient_id=" + encodeURIComponent(wartePick.id) + "&dauer=" + encodeURIComponent(dauer));
  paintAngebot(data);
}

function paintAngebot(data) {
  const offer = document.getElementById("warte-offer");
  const chosen = document.getElementById("warte-chosen");
  const appts = document.getElementById("warte-appointments");
  const free = document.getElementById("warte-free");
  const note = document.getElementById("warte-note");
  offer.hidden = false;
  chosen.textContent = data.name + (data.nummer != null ? "   Nr. " + data.nummer : "");
  clear(appts);
  clear(free);
  if (!(data.termine || []).length) {
    appts.appendChild(el("p", "hint", "Heute kein Termin."));
  } else {
    appts.appendChild(el("p", "hint", "Heutige Termine"));
    data.termine.forEach(function (termin) {
      const line = el("div", "inline");
      const label = [termin.ressource, termin.von && termin.bis ? termin.von + "–" + termin.bis : ""].filter(Boolean).join(" ");
      line.appendChild(el("span", "", label));
      const btn = el("button", "act tiny", "Zuweisen");
      btn.type = "button";
      btn.addEventListener("click", function () {
        seat({ patient_id: data.patient_id, termin_id: termin.id }).catch(function (err) { note.textContent = err.message; });
      });
      line.appendChild(btn);
      appts.appendChild(line);
    });
  }
  if (!(data.frei || []).length) {
    free.appendChild(el("p", "hint", "Zeitnah nichts frei."));
  } else {
    free.appendChild(el("p", "hint", "Frei"));
    data.frei.forEach(function (slot) {
      const line = el("div", "inline");
      line.appendChild(el("span", "", slot.ressource + " " + slot.von + "–" + slot.bis));
      const btn = el("button", "act tiny", "Belegen");
      btn.type = "button";
      btn.addEventListener("click", function () {
        seat({
          patient_id: data.patient_id,
          ressource_id: slot.ressource_id,
          tag: slot.tag,
          von: slot.von,
          bis: slot.bis
        }).catch(function (err) { note.textContent = err.message; });
      });
      line.appendChild(btn);
      free.appendChild(line);
    });
  }
  const already = (warteRows || []).some(function (row) { return row.patient_id === data.patient_id; });
  if (already) note.textContent = "Ist schon da. Eine neue Zuordnung bleibt bei derselben Ankunft.";
  else if ((data.termine || []).length) note.textContent = "Termin zuweisen, einen freien belegen, oder auf die Warteliste.";
  else if ((data.frei || []).length) note.textContent = "Einen freien Termin belegen, oder auf die Warteliste.";
  else note.textContent = "Nichts frei. Auf die Warteliste setzen.";
}

// Seats the chosen chart. Does not open it.
async function seat(body) {
  const data = await api("POST", "/api/wartezimmer", body);
  await applyWarte(data.anwesend || [], true);
  const note = document.getElementById("warte-note");
  if (note) note.textContent = "Im Wartezimmer.";
}

async function moveWarte(id, direction) {
  try {
    const data = await api("PATCH", "/api/wartezimmer/" + id, { richtung: direction });
    await applyWarte(data.anwesend || [], false);
  } catch (err) {
    const note = document.getElementById("warte-note");
    if (note && document.getElementById("wartezimmer").classList.contains("show")) note.textContent = err.message;
    const status = document.getElementById("term-status");
    if (status && document.getElementById("termine").classList.contains("show")) status.textContent = err.message;
    else hint.textContent = err.message;
  }
}

async function leaveWarte(id) {
  try {
    const data = await api("DELETE", "/api/wartezimmer/" + id);
    await applyWarte(data.anwesend || [], true);
  } catch (err) {
    const note = document.getElementById("warte-note");
    if (note) note.textContent = err.message;
  }
}

// Draws the strip and, when the week is open, reloads it so a new booking shows up.
async function applyWarte(rows, forceWeek) {
  const sig = warteSig(rows);
  const changed = sig !== warteSeen;
  warteRows = rows;
  warteSeen = sig;
  paintWarteStrip();
  const wz = document.getElementById("wartezimmer");
  if (wz && wz.classList.contains("show")) paintWarteHere();
  if ((changed || forceWeek) && termData && !termSetup) {
    const win = document.getElementById("termine");
    const sheet = document.getElementById("term-sheet");
    if (win && sheet && win.classList.contains("show")) {
      const top = sheet.scrollTop;
      await loadTermine();
      sheet.scrollTop = top;
    }
  }
}

// Polls only the waiting room, never the open chart.
async function refreshWarte() {
  try {
    const rows = await api("GET", "/api/wartezimmer");
    await applyWarte(rows || [], false);
  } catch (err) {
    return;
  }
}

// WZ opens the seating window. An open chart is already chosen. A search hit does not switch the chart.
async function openWarte() {
  openWin("wartezimmer");
  paintWarteHere();
  if (state.patient) {
    wartePick = state.patient;
    try {
      await loadAngebot();
    } catch (err) {
      document.getElementById("warte-note").textContent = err.message;
    }
  }
  const search = document.getElementById("warte-search");
  if (search) search.focus();
  await refreshWarte();
}

// Puts the open chart at the end of the queue. Does not open that chart again and does not replace someone already seated.
async function addOpenToWarte() {
  if (!state.patient) {
    hint.textContent = "Zuerst eine Akte aufrufen.";
    return;
  }
  const already = (warteRows || []).some(function (row) { return row.patient_id === state.patient.id; });
  if (already) {
    hint.textContent = "Ist schon im Wartezimmer.";
    return;
  }
  await seat({ patient_id: state.patient.id, nur_hinzufuegen: true });
  hint.textContent = "Im Wartezimmer.";
}

function bindWarte() {
  const search = document.getElementById("warte-search");
  let timer = null;
  search.addEventListener("input", function (ev) {
    const q = ev.target.value;
    clearTimeout(timer);
    timer = setTimeout(function () {
      searchWarte(q).catch(function (err) {
        document.getElementById("warte-note").textContent = err.message;
      });
    }, 200);
  });
  document.getElementById("warte-dauer").addEventListener("change", function () {
    if (!wartePick) return;
    loadAngebot().catch(function (err) {
      document.getElementById("warte-note").textContent = err.message;
    });
  });
  document.getElementById("warte-list").addEventListener("click", function () {
    if (!wartePick) return;
    seat({ patient_id: wartePick.id }).catch(function (err) {
      document.getElementById("warte-note").textContent = err.message;
    });
  });
  document.getElementById("warte-open").addEventListener("click", function () {
    openWarte().catch(function (err) { hint.textContent = err.message; });
  });
  document.getElementById("warte-add").addEventListener("click", function () {
    addOpenToWarte().catch(function (err) { hint.textContent = err.message; });
  });
}

function bindTermine() {
  document.getElementById("term-prev").addEventListener("click", function () {
    termWeek.setDate(termWeek.getDate() - 7);
    loadTermine();
  });
  document.getElementById("term-next").addEventListener("click", function () {
    termWeek.setDate(termWeek.getDate() + 7);
    loadTermine();
  });
  document.getElementById("term-today").addEventListener("click", function () {
    termWeek = mondayOf(new Date());
    loadTermine();
  });
  document.getElementById("term-book").addEventListener("click", function () {
    if (!state.patient) {
      termStatus("Ohne Akte lässt sich nur blocken.");
      return;
    }
    termMode = "termin";
    markTermMode();
  });
  document.getElementById("term-block").addEventListener("click", function () {
    termMode = "block";
    markTermMode();
  });
  document.getElementById("term-setup").addEventListener("click", function () {
    termSetup = !termSetup;
    this.textContent = termSetup ? "Zur Woche" : "Einrichten";
    if (termData) paintTermine();
  });
  document.getElementById("term-raster").addEventListener("change", function () {
    if (termQuiet) return;
    const minutes = Number(this.value);
    api("POST", "/api/termine/raster", { minuten: minutes }).then(function () {
      termStatus("Raster " + minutes + " Minuten.");
      return loadTermine();
    }).catch(function (err) { termStatus(err.message); });
  });
  document.getElementById("term-url-add").addEventListener("click", addUrlaub);
  document.getElementById("term-arrive").addEventListener("click", function () {
    const item = selectedTermin();
    if (!item || !item.patient_id || termBusy) return;
    termBusy = true;
    seat({ patient_id: item.patient_id, termin_id: item.id }).then(function () {
      termStatus("Anwesend.");
    }).catch(function (err) {
      termStatus(err.message);
    }).then(function () { termBusy = false; });
  });
  document.getElementById("term-drop").addEventListener("click", function () {
    if (!termSelected || termBusy) return;
    termBusy = true;
    api("DELETE", "/api/termine/" + termSelected).then(function () {
      termSelected = null;
      termStatus("Aufgehoben.");
      return loadTermine();
    }).catch(function (err) {
      termStatus(err.message);
    }).then(function () { termBusy = false; });
  });
}

document.getElementById("cmd").addEventListener("submit", function (ev) {
  ev.preventDefault();
  run(field.value);
});

// The open window with the highest z-index.
function topWin() {
  let best = null;
  let bestZ = -1;
  document.querySelectorAll(".win.show").forEach(function (win) {
    const rank = Number(win.style.zIndex);
    const zed = isFinite(rank) ? rank : 0;
    if (!best || zed >= bestZ) {
      best = win;
      bestZ = zed;
    }
  });
  return best;
}

document.addEventListener("keydown", function (ev) {
  if (ev.key !== "Escape") return;
  const win = topWin();
  if (!win) return;
  ev.preventDefault();
  const active = document.activeElement;
  if (active && active.blur && win.contains(active)) active.blur();
  closeWin(win.id);
  if (win.id === "akte") field.value = "";
  else if (document.getElementById("akte").classList.contains("show")) field.focus();
});

document.querySelectorAll(".tool").forEach(function (b) {
  b.addEventListener("click", function () { run(b.dataset.open === "akte" ? "" : shortcutFor(b.dataset.open)); if (b.dataset.open === "akte") openWin("akte"); });
});

// Toolbar button to the footer command that opens the same window.
function shortcutFor(id) {
  const map = {
    patienten: "P", abrechnung: "AB", medikamente: "M", medikation: "MP", rezept: "RP",
    dateien: "DA", briefe: "BRIEFE", praxis: "PX", labor: "LB", termine: "TER"
  };
  return map[id] || "";
}

buildKindWindows();

document.querySelectorAll("[data-close]").forEach(function (b) {
  b.addEventListener("click", function (ev) {
    ev.stopPropagation();
    closeWin(b.dataset.close);
  });
});

const LAYOUT_KEY = "praxis.fenster";
const MIN_W = 320;
const MIN_H = 200;

// Window positions from localStorage. A broken value is an empty map.
function readLayout() {
  try {
    const data = JSON.parse(localStorage.getItem(LAYOUT_KEY) || "{}");
    return data && typeof data === "object" ? data : {};
  } catch (e) {
    return {};
  }
}

// Stores one window's place under praxis.fenster. This is a browser setting, not part of the chart.
function saveLayout(win) {
  const all = readLayout();
  all[win.id] = {
    left: win.offsetLeft,
    top: win.offsetTop,
    width: win.offsetWidth,
    height: win.offsetHeight
  };
  try { localStorage.setItem(LAYOUT_KEY, JSON.stringify(all)); } catch (e) {}
}

// Restores positions. Elements without the class win are skipped, so a renamed id cannot move the page.
function applySaved() {
  const all = readLayout();
  Object.keys(all).forEach(function (id) {
    const win = document.getElementById(id);
    const box = all[id];
    if (!win || !win.classList.contains("win") || !box) return;
    const nums = [box.left, box.top, box.width, box.height];
    if (!nums.every(function (n) { return typeof n === "number" && isFinite(n); })) return;
    win.style.right = "auto";
    win.style.left = box.left + "px";
    win.style.top = box.top + "px";
    win.style.width = box.width + "px";
    win.style.height = box.height + "px";
  });
}

// Pulls a window back onto the desk.
function keepInside(win) {
  const deskW = desk.clientWidth;
  const deskH = desk.clientHeight;
  if (deskW < 80 || deskH < 80) return;
  let left = win.offsetLeft;
  let top = win.offsetTop;
  let width = win.offsetWidth;
  let height = win.offsetHeight;
  if (width < 40 || height < 40) return;
  let changed = false;
  if (width > deskW) { width = deskW; changed = true; }
  if (height > deskH) { height = deskH; changed = true; }
  if (left < 0) { left = 0; changed = true; }
  if (top < 0) { top = 0; changed = true; }
  if (left + width > deskW) { left = Math.max(0, deskW - width); changed = true; }
  if (top + height > deskH) { top = Math.max(0, deskH - height); changed = true; }
  if (!changed) return;
  win.style.right = "auto";
  win.style.left = Math.round(left) + "px";
  win.style.top = Math.round(top) + "px";
  win.style.width = Math.round(width) + "px";
  win.style.height = Math.round(height) + "px";
}

// Sets a window's place in pixels.
function placeWin(win, left, top, width, height) {
  win.style.right = "auto";
  win.style.left = left + "px";
  win.style.top = top + "px";
  win.style.width = width + "px";
  win.style.height = height + "px";
}

// New rectangle while dragging an edge. The window stays at least 320 by 200 and inside the desk.
function resizedBox(start, clientX, clientY) {
  const dx = clientX - start.x;
  const dy = clientY - start.y;
  const deskW = desk.clientWidth;
  const deskH = desk.clientHeight;
  let left = start.left;
  let top = start.top;
  let right = start.left + start.width;
  let bottom = start.top + start.height;
  const dir = start.dir;
  if (dir.indexOf("e") >= 0) right += dx;
  if (dir.indexOf("w") >= 0) left += dx;
  if (dir.indexOf("s") >= 0) bottom += dy;
  if (dir.indexOf("n") >= 0) top += dy;
  if (right - left < MIN_W) {
    if (dir.indexOf("w") >= 0) left = right - MIN_W;
    else right = left + MIN_W;
  }
  if (bottom - top < MIN_H) {
    if (dir.indexOf("n") >= 0) top = bottom - MIN_H;
    else bottom = top + MIN_H;
  }
  left = Math.max(0, left);
  top = Math.max(0, top);
  right = Math.min(deskW, right);
  bottom = Math.min(deskH, bottom);
  if (right - left < MIN_W) {
    if (left + MIN_W <= deskW) right = left + MIN_W;
    else { left = Math.max(0, deskW - MIN_W); right = Math.min(deskW, left + MIN_W); }
  }
  if (bottom - top < MIN_H) {
    if (top + MIN_H <= deskH) bottom = top + MIN_H;
    else { top = Math.max(0, deskH - MIN_H); bottom = Math.min(deskH, top + MIN_H); }
  }
  return {
    left: Math.round(left),
    top: Math.round(top),
    width: Math.round(right - left),
    height: Math.round(bottom - top)
  };
}

// A string of the current place, used to see whether a drag actually moved the window.
function markWin(win) {
  return [win.offsetLeft, win.offsetTop, win.offsetWidth, win.offsetHeight].join(",");
}

let drag = null;
document.querySelectorAll(".title").forEach(function (bar) {
  bar.addEventListener("pointerdown", function (ev) {
    if (ev.target.closest(".x")) return;
    const win = bar.parentElement;
    front(win);
    drag = {
      win: win,
      dx: ev.clientX - win.offsetLeft,
      dy: ev.clientY - win.offsetTop,
      mark: markWin(win)
    };
    bar.setPointerCapture(ev.pointerId);
  });
  bar.addEventListener("pointermove", function (ev) {
    if (!drag || drag.mode || drag.win !== bar.parentElement) return;
    if (drag.win.id === "akte") {
      drag.win.style.right = "auto";
      drag.win.style.width = drag.win.offsetWidth + "px";
    }
    const maxL = Math.max(0, desk.clientWidth - 120);
    const maxT = Math.max(0, desk.clientHeight - 48);
    drag.win.style.left = Math.min(maxL, Math.max(0, ev.clientX - drag.dx)) + "px";
    drag.win.style.top = Math.min(maxT, Math.max(0, ev.clientY - drag.dy)) + "px";
  });

  // Saves the window position only when the drag actually moved it.
  function endDrag() {
    if (!drag || drag.mode) return;
    const win = drag.win;
    const before = drag.mark;
    drag = null;
    if (markWin(win) !== before) saveLayout(win);
  }
  bar.addEventListener("pointerup", endDrag);
  bar.addEventListener("pointercancel", endDrag);
});

document.querySelectorAll(".win").forEach(function (win) {
  ["n", "e", "s", "w", "nw", "se", "sw"].forEach(function (dir) {
    const handle = document.createElement("div");
    handle.className = "resize " + dir;
    handle.addEventListener("pointerdown", function (ev) {
      ev.preventDefault();
      ev.stopPropagation();
      front(win);
      drag = {
        mode: "resize",
        win: win,
        dir: dir,
        x: ev.clientX,
        y: ev.clientY,
        left: win.offsetLeft,
        top: win.offsetTop,
        width: win.offsetWidth,
        height: win.offsetHeight,
        mark: markWin(win)
      };
      handle.setPointerCapture(ev.pointerId);
    });
    handle.addEventListener("pointermove", function (ev) {
      if (!drag || drag.mode !== "resize" || drag.win !== win || drag.dir !== dir) return;
      const box = resizedBox(drag, ev.clientX, ev.clientY);
      placeWin(win, box.left, box.top, box.width, box.height);
    });

    // Saves the window size only when the resize actually changed it.
    function endResize() {
      if (!drag || drag.mode !== "resize" || drag.win !== win) return;
      const before = drag.mark;
      drag = null;
      if (markWin(win) !== before) saveLayout(win);
    }
    handle.addEventListener("pointerup", endResize);
    handle.addEventListener("pointercancel", endResize);
    win.appendChild(handle);
  });
});

applySaved();
document.querySelectorAll(".win.show").forEach(keepInside);
window.addEventListener("resize", function () {
  document.querySelectorAll(".win.show").forEach(keepInside);
});

document.querySelectorAll(".win").forEach(function (win) {
  win.addEventListener("pointerdown", function () { front(win); });
});

document.getElementById("open-stamm").addEventListener("click", editCurrent);
document.getElementById("stamm-form").addEventListener("submit", function (ev) {
  ev.preventDefault();
  saveStamm();
});
document.getElementById("empf-neu").addEventListener("click", takeRecipient);
document.getElementById("empf-open").addEventListener("click", openRecipient);
document.getElementById("rel-add").addEventListener("click", openPicker);
document.getElementById("stamm-delete").addEventListener("click", deleteCurrent);
document.getElementById("stamm-back").addEventListener("click", editCurrent);
document.querySelectorAll("#praxis .set-nav button").forEach(function (button) {
  button.addEventListener("click", function () {
    const which = button.dataset.set;
    showSettings(which);
    if (which === "adressen") {
      loadAddressBook().catch(function (err) {
        document.getElementById("adr-note").textContent = err.message;
      });
    }
    if (which === "bausteine") {
      loadBausteine().catch(function (err) {
        document.getElementById("bau-note").textContent = err.message;
      });
    }
    if (which === "gebuehren") {
      loadSettingsFees().catch(function (err) {
        document.getElementById("set-fee-note").textContent = err.message;
      });
    }
    if (which === "vorlagen") {
      drawSettingsTemplates().catch(function (err) {
        const box = document.getElementById("set-vorlagen-list");
        clear(box);
        box.appendChild(el("p", "hint", err.message));
      });
    }
  });
});
document.getElementById("set-faktor-save").addEventListener("click", function () {
  const note = document.getElementById("set-faktor-note");
  api("PUT", "/api/practice/faktor", { faktor: val("set-faktor") }).then(function (px) {
    state.practice = Object.assign({}, state.practice || {}, px);
    note.textContent = px.standardfaktor
      ? "Standardfaktor " + px.standardfaktor + " gespeichert."
      : "Leer bedeutet Faktor 1. Er gilt, wenn beim Buchen kein anderer Faktor angegeben ist.";
  }).catch(function (err) {
    note.textContent = err.message;
  });
});
document.getElementById("set-fee-search").addEventListener("input", function (ev) {
  drawSettingsFees(ev.target.value);
});
document.getElementById("praxis-form").addEventListener("submit", function (ev) {
  ev.preventDefault();
  savePractice().catch(function (err) { document.getElementById("px-note").textContent = err.message; });
});
document.getElementById("px-add-tel").addEventListener("click", function () {
  const input = addPhone("");
  input.focus();
});
document.getElementById("px-sign").addEventListener("click", function () {
  document.getElementById("px-sign-file").click();
});
document.getElementById("px-sign-file").addEventListener("change", function () {
  const file = this.files[0];
  if (!file) return;
  api("POST", "/api/practice/signature", file, {
    "X-Filename": file.name,
    "Content-Type": file.type || "application/octet-stream"
  }).then(function (px) {
    state.practice = px;
    fillPracticeForm();
    document.getElementById("px-note").textContent = "Unterschrift gespeichert";
  }).catch(function (err) {
    document.getElementById("px-note").textContent = err.message;
  });
});
document.getElementById("med-search").addEventListener("input", function (ev) {
  const q = ev.target.value;
  clearTimeout(medTimer);
  medTimer = setTimeout(function () { drawMeds(q).catch(function (err) { hint.textContent = err.message; }); }, 180);
});
document.getElementById("pick-med").addEventListener("click", function () {
  medMode = "rx";
  openMeds();
});
document.getElementById("make-rx").addEventListener("click", makePrescription);
document.getElementById("file-add").addEventListener("click", function () {
  document.getElementById("file-input").click();
});
document.getElementById("file-input").addEventListener("change", function () {
  const file = this.files[0];
  this.value = "";
  if (file) uploadFile(file).catch(function (err) { hint.textContent = err.message; });
});
document.getElementById("labor-file").addEventListener("change", function () {
  const file = this.files[0];
  this.value = "";
  if (!file) return;
  readLabUpload(file).catch(function (err) { hint.textContent = err.message; });
});
document.getElementById("open-letter").addEventListener("click", writeLetter);
document.getElementById("letter-adresse").addEventListener("change", showLetterAddress);
document.getElementById("letter-adressen").addEventListener("click", function () {
  openEinstellungen("adressen").catch(function (err) {
    document.getElementById("letter-note").textContent = err.message;
  });
});
document.getElementById("adr-search").addEventListener("input", function () { drawAddresses(); });
document.getElementById("adr-form").addEventListener("submit", function (ev) {
  ev.preventDefault();
  saveAddress().catch(function (err) {
    document.getElementById("adr-note").textContent = err.message;
  });
});
document.getElementById("adr-new").addEventListener("click", function () {
  clearAddressForm();
  document.getElementById("adr-note").textContent = "";
});
document.getElementById("adr-delete").addEventListener("click", function () {
  deleteAddress().catch(function (err) {
    document.getElementById("adr-note").textContent = err.message;
  });
});
document.getElementById("bau-search").addEventListener("input", function () { drawBausteine(); });
document.getElementById("bau-form").addEventListener("submit", function (ev) {
  ev.preventDefault();
  saveBaustein().catch(function (err) {
    document.getElementById("bau-note").textContent = err.message;
  });
});
document.getElementById("bau-new").addEventListener("click", function () {
  clearBausteinForm();
  document.getElementById("bau-note").textContent = "";
});
document.getElementById("bau-delete").addEventListener("click", function () {
  deleteBaustein().catch(function (err) {
    document.getElementById("bau-note").textContent = err.message;
  });
});
document.getElementById("bau-use").addEventListener("click", function () {
  useBaustein().catch(function (err) {
    document.getElementById("bau-note").textContent = err.message;
  });
});
document.getElementById("letter-take").addEventListener("click", takeLetterPieces);
document.getElementById("letter-all").addEventListener("click", function () {
  document.querySelectorAll("#letter-picks input").forEach(function (box) { box.checked = true; });
  const area = document.getElementById("letter-text");
  const blocks = [];
  document.querySelectorAll("#letter-picks input").forEach(function (box) {
    if (box.dataset.text) blocks.push(box.dataset.text);
  });
  if (!blocks.length) {
    document.getElementById("letter-note").textContent = "In der offenen Kartei steht kein Text.";
    return;
  }
  area.value = blocks.join("\n\n");
  document.getElementById("letter-note").textContent = "Alle Texte stehen im Brief. Vor dem Öffnen noch lesen.";
});
document.getElementById("pat-import").addEventListener("click", function () {
  document.getElementById("pat-import-file").click();
});
document.getElementById("pat-import-file").addEventListener("change", function (ev) {
  const file = ev.target.files && ev.target.files[0];
  ev.target.value = "";
  if (!file) return;
  importBesuche(file).catch(function (err) { hint.textContent = err.message; });
});
document.getElementById("pos-search").addEventListener("input", function (ev) { drawCatalog(ev.target.value); });
document.getElementById("pos-faktor").addEventListener("input", function () { drawCatalog(val("pos-search")); });
document.getElementById("dx-search").addEventListener("input", function (ev) {
  const q = ev.target.value;
  clearTimeout(dxTimer);
  dxTimer = setTimeout(function () {
    loadDiagnosen(q).catch(function (err) {
      document.getElementById("dx-note").textContent = err.message;
    });
  }, 160);
});
document.getElementById("dx-save").addEventListener("click", function () {
  const note = document.getElementById("dx-note");
  api("POST", "/api/diagnosen", {
    code: val("dx-code"),
    kurz: val("dx-kurz"),
    lang: val("dx-lang")
  }).then(function () {
    setVal("dx-code", "");
    setVal("dx-kurz", "");
    setVal("dx-lang", "");
    note.textContent = "Die eigene Zeile gilt vor demselben ICD-Code.";
    return loadDiagnosen(val("dx-search"));
  }).catch(function (err) {
    note.textContent = err.message;
  });
});
document.getElementById("kuerzel-save").addEventListener("click", function () {
  const note = document.getElementById("kuerzel-note");
  api("POST", "/api/kuerzel", {
    code: val("kuerzel-code"),
    label: val("kuerzel-label")
  }).then(function (data) {
    eigene = data.kuerzel || [];
    setVal("kuerzel-code", "");
    setVal("kuerzel-label", "");
    note.textContent = "Ein eigenes Kürzel legt eine Info mit dieser Bezeichnung an. Einen Textblock legt man unter Einstellungen bei Bausteine an.";
    drawKuerzel();
  }).catch(function (err) {
    note.textContent = err.message;
  });
});
document.getElementById("cat-save").addEventListener("click", function () {
  const note = document.getElementById("cat-note");
  api("POST", "/api/catalog", {
    code: val("cat-code"),
    text: val("cat-text"),
    betrag: val("cat-betrag")
  }).then(function (row) {
    catalog = (catalog || []).filter(function (item) {
      return item.code.toLowerCase() !== row.code.toLowerCase();
    });
    catalog.push(row);
    catalog.sort(function (a, b) { return a.code.localeCompare(b.code, "de"); });
    setVal("cat-code", "");
    setVal("cat-text", "");
    setVal("cat-betrag", "");
    drawCatalog(val("pos-search"));
    drawSettingsFees(val("set-fee-search"));
    note.textContent = "Steht im Katalog.";
  }).catch(function (err) {
    note.textContent = err.message;
  });
});
document.getElementById("pat-search").addEventListener("input", function (ev) {
  const q = ev.target.value;
  clearTimeout(patTimer);
  patTimer = setTimeout(function () {
    drawPatients(q).catch(function (err) { hint.textContent = err.message; });
  }, 150);
});
document.getElementById("pat-new").addEventListener("click", function () {
  if (pickFor) editNewForLink();
  else editNew();
});

// Loads the open chart on startup and focuses the shortcut field. A fenster query opens that window.
async function load() {
  state = await api("GET", "/api/state");
  renderWho();
  renderChart();
  fillPracticeForm();
  if (state.patient) {
    editMode = "patient";
    editId = state.patient.id;
    fillStamm(state.patient);
  }
  try { await loadKuerzel(); } catch (e) { eigene = []; }
  try { await loadBausteine(); } catch (e) { bausteine = []; }
  ready = true;
  const offen = new URLSearchParams(location.search).get("fenster");
  if (offen === "stammdaten") editCurrent();
  else if (offen === "patienten") await openPatients();
  else if (offen === "rezept") await openRezept();
  else if (offen === "termine") await openTermine();
  else if (offen === "wartezimmer") await openWarte();
  else if (offen && TEXT[offen.replace(/^text-/, "")] && document.getElementById(offen)) openKind(offen.replace(/^text-/, ""));
  else if (offen && document.getElementById(offen)) openWin(offen);
  field.focus();
}

bindTermine();
bindWarte();
refreshWarte().catch(function () {});
warteTimer = setInterval(function () { refreshWarte().catch(function () {}); }, 20000);

load().catch(function () {
  hint.textContent = "Keine Verbindung";
});
