#!/usr/bin/env ruby
# frozen_string_literal: true

# Opens practice files on this workstation. It listens only on 127.0.0.1.
# The page asks it to fetch one file from the configured server, save a copy
# here, and hand that copy to the local program. A later save is sent back.
# PRAXIS_NO_OPEN skips the program, for a probe. The server address is
# ~/.config/praxis/ziel, or http://127.0.0.1:8765 when that file is missing.

require "webrick"
require "json"
require "net/http"
require "uri"
require "fileutils"

BIND = "127.0.0.1"
PORT = Integer(ENV["PRAXIS_LOKAL_PORT"] || "8764")
ZIEL_FILE = ENV["PRAXIS_ZIEL_FILE"] || File.join(Dir.home, ".config", "praxis", "ziel")
CACHE = ENV["PRAXIS_CACHE"] || File.join(Dir.home, ".cache", "praxis")
SYNC_SECONDS = Integer(ENV["PRAXIS_SYNC_SECONDS"] || "2")
ALLOWED = %r{\A/api/(?:files/\d+/raw|letters/\d+/datei|templates/[A-Za-z0-9._~%'()!*-]+/datei)\z}

FileUtils.mkdir_p(CACHE)
OPEN = {}
GUARD = Mutex.new

def ziel
  if File.file?(ZIEL_FILE)
    line = File.read(ZIEL_FILE, encoding: "UTF-8").strip
    return line unless line.empty?
  end
  "http://127.0.0.1:8765"
end

def ziel_origin
  uri = URI(ziel)
  return "" unless uri.host
  standard = (uri.scheme == "http" && uri.port == 80) || (uri.scheme == "https" && uri.port == 443)
  standard ? "#{uri.scheme}://#{uri.host}" : "#{uri.scheme}://#{uri.host}:#{uri.port}"
end

# localhost and 127.0.0.1 are the same computer. A page opened either way may call this program.
def origin_allowed?(origin, wanted)
  return false if origin.empty? || wanted.empty?
  return true if origin == wanted
  page = URI(origin)
  home = URI(wanted)
  return false unless page.scheme == home.scheme && page.port == home.port
  loop = %w[127.0.0.1 localhost]
  loop.include?(page.host) && loop.include?(home.host)
rescue URI::InvalidURIError
  false
end

def server_uri(pfad)
  raise ArgumentError, "Unerlaubter Pfad" unless pfad.match?(ALLOWED)
  decoded = WEBrick::HTTPUtils.unescape(pfad)
  raise ArgumentError, "Unerlaubter Pfad" if decoded.include?("..") || decoded.include?("\\") || decoded.include?("\0")
  base = ziel.sub(%r{/\z}, "")
  URI(base + pfad)
end

def http_call(method, pfad, body = nil)
  uri = server_uri(pfad)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == "https"
  http.open_timeout = 5
  http.read_timeout = 60
  request = method == :put ? Net::HTTP::Put.new(uri) : Net::HTTP::Get.new(uri)
  if body
    request["Content-Type"] = "application/octet-stream"
    request.body = body
  end
  response = http.request(request)
  raise ArgumentError, "Der Server hat die Datei nicht hergegeben." unless response.is_a?(Net::HTTPSuccess)
  response.body
end

def safe_name(name, fallback)
  base = File.basename(name.to_s).gsub(/[^\p{L}\p{N}._ -]+/u, "_").strip
  base = fallback if base.empty? || base == "." || base == ".."
  base[0, 120]
end

def local_path(pfad, name)
  tag = pfad.sub(%r{\A/api/}, "").gsub("/", "-")
  File.join(CACHE, "#{tag}-#{safe_name(name, "datei")}")
end

def push_copy(path, pfad, seen)
  return unless File.file?(path) && seen
  mtime = File.mtime(path)
  return if mtime <= seen
  bytes = File.binread(path)
  return if File.mtime(path) != mtime
  http_call(:put, pfad, bytes)
  after = File.mtime(path)
  # A save during the upload keeps the old mark, so the next pass sends the newer bytes.
  GUARD.synchronize { OPEN[path] = [pfad, after == mtime ? after : seen] }
end

def fetch_copy(pfad, name)
  path = local_path(pfad, name)
  seen = nil
  GUARD.synchronize { seen = OPEN[path]&.last }
  push_copy(path, pfad, seen) if seen
  bytes = http_call(:get, pfad)
  raise ArgumentError, "Die Datei ist leer" if bytes.nil? || bytes.empty?
  raise ArgumentError, "Die Datei ist zu groß" if bytes.bytesize > 25 * 1024 * 1024
  File.binwrite(path, bytes)
  File.chmod(0o600, path)
  GUARD.synchronize { OPEN[path] = [pfad, File.mtime(path)] }
  path
end

# /usr/bin, Homebrew, then PATH. PRAXIS_XDG_OPEN overrides the name.
def xdg_open
  given = ENV["PRAXIS_XDG_OPEN"].to_s
  return given if !given.empty? && File.executable?(given)
  dirs = ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"] + ENV["PATH"].to_s.split(File::PATH_SEPARATOR)
  dirs.each do |dir|
    candidate = File.join(dir, "xdg-open")
    return candidate if File.executable?(candidate) && File.file?(candidate)
  end
  nil
end

def reveal(path)
  return true if ENV["PRAXIS_NO_OPEN"] == "1"
  if RUBY_PLATFORM.include?("darwin")
    pid = spawn("open", path, [:out, :err] => File::NULL)
  else
    bin = xdg_open
    return false unless bin
    env = ENV.to_h
    env["DISPLAY"] = ":0" if env["DISPLAY"].to_s.empty?
    runtime = "/run/user/#{Process.uid}"
    env["XDG_RUNTIME_DIR"] ||= runtime if Dir.exist?(runtime)
    bus = File.join(runtime, "bus")
    env["DBUS_SESSION_BUS_ADDRESS"] ||= "unix:path=#{bus}" if File.exist?(bus)
    pid = spawn(env, bin, path, [:out, :err] => File::NULL)
  end
  Process.detach(pid)
  true
rescue StandardError
  false
end

Thread.new do
  loop do
    sleep SYNC_SECONDS
    pairs = GUARD.synchronize { OPEN.map { |path, (pfad, seen)| [path, pfad, seen] } }
    pairs.each do |path, pfad, seen|
      push_copy(path, pfad, seen)
    rescue StandardError
      warn "rueckgabe fehlgeschlagen"
    end
  end
end

class Lokal < WEBrick::HTTPServlet::AbstractServlet
  def do_OPTIONS(req, res)
    allow(req, res)
    res.status = 204
  end

  def do_GET(req, res)
    allow(req, res)
    if req.path == "/api/health"
      res.status = 200
      res["Content-Type"] = "application/json; charset=utf-8"
      res.body = JSON.generate({ "ok" => true })
      return
    end
    res.status = 404
    res["Content-Type"] = "application/json; charset=utf-8"
    res.body = JSON.generate({ "error" => "Nicht gefunden" })
  end

  def do_POST(req, res)
    allow(req, res)
    unless req.path == "/oeffnen"
      res.status = 404
      res["Content-Type"] = "application/json; charset=utf-8"
      res.body = JSON.generate({ "error" => "Nicht gefunden" })
      return
    end
    raw = req.body
    text = raw.respond_to?(:read) ? raw.read.to_s : raw.to_s
    data = JSON.parse(text)
    path = fetch_copy(data["pfad"].to_s, data["name"].to_s)
    opened = reveal(path)
    res.status = opened ? 200 : 500
    res["Content-Type"] = "application/json; charset=utf-8"
    res.body = JSON.generate(opened ? { "opened" => true } : { "error" => "Kein Programm hat die Datei geöffnet." })
  rescue ArgumentError => e
    res.status = 400
    res["Content-Type"] = "application/json; charset=utf-8"
    res.body = JSON.generate({ "error" => e.message })
  rescue StandardError
    res.status = 500
    res["Content-Type"] = "application/json; charset=utf-8"
    res.body = JSON.generate({ "error" => "Die Datei wurde nicht geöffnet." })
  end

  def allow(req, res)
    origin = req["Origin"].to_s
    wanted = ziel_origin
    res["Access-Control-Allow-Origin"] = origin if origin_allowed?(origin, wanted)
    res["Access-Control-Allow-Origin"] = wanted if origin == "" && wanted != ""
    res["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
    res["Access-Control-Allow-Headers"] = "Content-Type"
    res["Access-Control-Allow-Private-Network"] = "true"
    res["Vary"] = "Origin"
  end
end

server = WEBrick::HTTPServer.new(
  BindAddress: BIND,
  Port: PORT,
  AccessLog: [],
  Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN)
)
server.mount "/", Lokal
trap("INT") { server.shutdown }
trap("TERM") { server.shutdown }
server.start
