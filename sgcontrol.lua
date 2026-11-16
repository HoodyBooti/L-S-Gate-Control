-- sgcontrol.lua  --  Stargate-Kommandozentrale (Lantea 0.7.7.0 + CC:Tweaked)
-- Monitore: Steuerung (Touch-DHD) / Status / Chevrons -- alle optional, mind. 1 Monitor
-- Start: sgcontrol

local CONFIG_FILE = "sg_config.lua"

------------------------------------------------------------------ Dateien
local function loadTable(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  local d = textutils.unserialise(f.readAll())
  f.close()
  return type(d) == "table" and d or nil
end

local function saveTable(path, t)
  local f = fs.open(path, "w")
  f.write(textutils.serialise(t))
  f.close()
end

------------------------------------------------------------------ Config
-- "" = automatisch. Monitornamen findest du mit:  sgcontrol identify
local defaults = {
  gate           = "",   -- Peripheral-Name des Gates, "" = automatisch suchen
  controlMonitor = "",   -- z.B. "monitor_0"
  statusMonitor  = "",
  chevronMonitor = "",
  textScale      = 0.5,  -- Statusmonitor
  chevronScale   = 0.5,  -- Chevron-Monitor (0.5 = hoechste Aufloesung)
  controlScale   = 1,    -- Steuerungsmonitor: feste Schrift, nur wenn autoScale = false
  autoScale      = true, -- Schriftgroesse des Steuerungsmonitors automatisch an seine Groesse anpassen
  showNames      = true, -- Symbolnamen neben den Nummern zeigen, wenn Platz ist (sonst nur Nummern)
  minNameLen     = 6,    -- Namen werden hoechstens auf so viele Zeichen gekuerzt
  maxNameLen     = 12,
  useGlyphs      = false, -- Glyphenbilder statt Nummern, wenn keine Namen passen (braucht grossen Monitor)
  sidebar        = false, -- veraltet: Lesezeichen erscheinen nur im eigenen Menue
  palmRequired   = true, -- WAHL erst nach Handscan (Hand auf das Display legen)
  palmMode       = "hold", -- "hold" = Hand halten (Rechtsklick gedrueckt halten), "taps" = mehrfach tippen
  palmHoldSeconds = 2.5, -- Haltedauer fuer die Freigabe
  palmTaps       = 5,    -- Anzahl schneller Touches bei palmMode "taps"
  palmGap        = 0.8,  -- max. Pause zwischen Touches, sonst beginnt der Scan neu
  palmTimeout    = 30,   -- Sekunden bis die Freigabe-Ansicht von selbst schliesst
  pollInterval   = 0.25,
  symbolTimeout  = 60,   -- Sekunden Wartezeit pro Symbol
  energyInFE     = false, -- Energieanzeige in FE statt EU (1 EU = 4 FE)
  debug          = false, -- true = Debug-Ausgabe (oder: sgcontrol debug)
  debugTerminal  = true,  -- Debug-Zeilen auch im Terminal anzeigen
  language       = "DE", -- Sprache der Monitoroberflaeche: DE oder EN
}
local cfg = {}
do
  local loaded = loadTable(CONFIG_FILE)
  if fs.exists(CONFIG_FILE) and not loaded then
    printError(CONFIG_FILE .. " ist kein gueltiges Datenformat - Standardwerte aktiv!")
    printError("Datei loeschen, dann wird sie neu angelegt.")
  end
  loaded = loaded or {}
  for k, v in pairs(defaults) do
    if loaded[k] ~= nil then cfg[k] = loaded[k] else cfg[k] = v end
  end
  saveTable(CONFIG_FILE, cfg) -- immer mit allen Schluesseln speichern
end

------------------------------------------------------------------ Sprache
local LANGUAGE_FILE = "sg_language.lua"
if not fs.exists(LANGUAGE_FILE) then
  printError("Language file missing: " .. LANGUAGE_FILE)
  return
end
local language = dofile(LANGUAGE_FILE)
if type(language) ~= "table" or type(language.EN) ~= "table" or type(language.DE) ~= "table" then
  printError("Language data must contain language.EN and language.DE.")
  return
end
local languageCode = tostring(cfg.language or "DE"):upper()
local strings = language[languageCode] or language.DE
local function T(key, ...)
  local value = strings[key] or language.EN[key] or key
  if select("#", ...) > 0 then return value:format(...) end
  return value
end
if not language[languageCode] then printError(T("ERROR_UNKNOWN_LANGUAGE", languageCode)) end

------------------------------------------------------------------ Debug
-- Einschalten:  sgcontrol debug      (nur fuer diesen Start)
--               oder debug = true in sg_config.lua
-- Probe:        sgcontrol probe      (liest alle Abfragen am ruhenden Gate aus)
-- Ausgabe:      Terminal + Datei sg_debug.log (wird bei jedem Start neu angelegt)
local DEBUG_FILE = "sg_debug.log"
local ARGS = { ... }
local probeMode = false
for _, a in ipairs(ARGS) do
  if a == "debug" then cfg.debug = true
  elseif a == "probe" then probeMode = true; cfg.debug = true; cfg.debugTerminal = true end
end

local dbgFile, dbgBytes = nil, 0
local function dbg(fmt, ...)
  if not cfg.debug then return end
  local ok, msg = pcall(string.format, fmt, ...)
  if not ok then msg = tostring(fmt) end
  local line = ("%s [%8.2f] %s"):format(os.date("%H:%M:%S"), os.epoch("utc") / 1000 % 100000, msg)
  if dbgBytes == 0 and not dbgFile then dbgFile = fs.open(DEBUG_FILE, "w") end
  if dbgFile and dbgBytes < 400000 then
    dbgFile.writeLine(line); dbgFile.flush()
    dbgBytes = dbgBytes + #line + 1
  end
  if cfg.debugTerminal then print(line) end
end

-- Hilfsmodus: zeigt auf jedem Monitor seinen Namen an
if ({ ... })[1] == "identify" then
  local found = {}
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.hasType(n, "monitor") then
      local m = peripheral.wrap(n)
      m.setTextScale(1)
      m.setBackgroundColor(colors.black); m.setTextColor(colors.yellow); m.clear()
      m.setCursorPos(1, 1); m.write(n)
      print(n)
      found[#found + 1] = m
    end
  end
  if #found == 0 then print(T("INFO_NO_MONITORS")) else
    print(T("INFO_IDENTIFY_MONITORS"))
    sleep(15)
    for _, m in ipairs(found) do m.setBackgroundColor(colors.black); m.clear() end
  end
  return
end

------------------------------------------------------------------ Gate
local gate
if cfg.gate ~= "" then gate = peripheral.wrap(cfg.gate) else gate = peripheral.find("stargate") end
if not gate then
  printError(T("ERROR_NO_GATE"))
  print(T("INFO_GATE_CONNECT_1"))
  print(T("INFO_GATE_CONNECT_2"))
  return
end

local lastSafeErr = ""
local function safe(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, v = pcall(fn, ...)
  if ok then return v end
  if tostring(v) ~= lastSafeErr then lastSafeErr = tostring(v); dbg("safe(): Fehler: %s", lastSafeErr) end
  return nil
end

local function fmtValue(v)
  if type(v) == "table" then
    local parts = {}
    for _, x in ipairs(v) do parts[#parts + 1] = tostring(x) end
    if #parts > 0 then return table.concat(parts, "-") end
    return (textutils.serialise(v):gsub("%s+", " "))
  end
  return tostring(v)
end

do
  local okN, gname = pcall(peripheral.getName, gate)
  local okM, methods = pcall(peripheral.getMethods, okN and gname or "")
  dbg("=== sgcontrol Debug gestartet (CC %s) ===", tostring(_HOST))
  dbg("Gate-Peripheral: %s", okN and tostring(gname) or "?")
  if okM and methods then
    table.sort(methods)
    dbg("Gate-Methoden: %s", table.concat(methods, ", "))
  end
  local c = {}
  for k, v in pairs(cfg) do c[#c + 1] = k .. "=" .. tostring(v) end
  table.sort(c)
  dbg("Config: %s", table.concat(c, " "))
end

if probeMode then
  local function show(label, fn, ...)
    local r = table.pack(pcall(fn, ...))
    local out = {}
    for i = 2, r.n do out[#out + 1] = textutils.serialise(r[i], { compact = true }) end
    dbg("PROBE %-22s %s %s", label, r[1] and "->" or "FEHLER", r[1] and table.concat(out, " | ") or tostring(r[2]))
  end
  for _, name in ipairs({ "getState", "getChevronsLocked", "getLockedSymbols", "getNextChevron",
      "isRingTurning", "getCurrentSymbol", "getEnergy", "getIrisState", "getIrisMaterial",
      "getLocalAddress", "getPointOfOrigin" }) do
    if gate[name] then show(name .. "()", gate[name]) else dbg("PROBE %-22s Methode fehlt", name .. "()") end
  end
  for _, n in ipairs({ 0, 1, 2, 12, 27, 38 }) do show("getSymbolName(" .. n .. ")", gate.getSymbolName, n) end
  dbg("PROBE fertig. Datei: %s", DEBUG_FILE)
  if dbgFile then dbgFile.close() end
  return
end

local function num(n)
  local s = tostring(math.floor(tonumber(n) or 0))
  local k
  repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1.%2") until k == 0
  return s
end

local MAX_GATE_ENERGY_EU = 8192000

-- Symbole des Gates (Nummer -> Name). DHD-Tasten = alle Nummern > 0 mit bekanntem Namen.
local symName, glyphs = {}, {}
for n = 0, 60 do
  local name = safe(gate.getSymbolName, n)
  if type(name) == "string" then
    symName[n] = name
    if n > 0 then glyphs[#glyphs + 1] = n end
  end
end
if #glyphs == 0 then -- Namen nicht abfragbar: Standard 1..38
  for n = 1, 38 do glyphs[n] = n end
end

-- Eingabe ohne Point of Origin (00 wird beim Waehlen automatisch angehaengt)
local MIN_SYMS, MAX_SYMS = 6, 8

------------------------------------------------------------------ Log
local logLines = {}
local function log(msg)
  dbg("LOG  %s", msg)
  logLines[#logLines + 1] = os.date("%H:%M:%S") .. " " .. msg
  while #logLines > 60 do table.remove(logLines, 1) end
end

------------------------------------------------------------------ Monitore
local mons = {}
do
  local names = {}
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.hasType(n, "monitor") then names[#names + 1] = n end
  end
  table.sort(names)
  local assigned, used = {}, {}
  for _, role in ipairs({ "control", "status", "chevron" }) do
    local want = cfg[role .. "Monitor"]
    if want ~= "" then
      if peripheral.isPresent(want) and peripheral.hasType(want, "monitor") then
        assigned[role] = want; used[want] = true
      else
        printError(T("ERROR_MONITOR_MISSING", want, T("ROLE_" .. role:upper())))
        printError(T("ERROR_AVAILABLE_MONITORS", table.concat(names, ", ")))
      end
    end
  end
  for _, role in ipairs({ "control", "status", "chevron" }) do
    if not assigned[role] then
      for _, n in ipairs(names) do
        if not used[n] then assigned[role] = n; used[n] = true; break end
      end
    end
  end
  for _, role in ipairs({ "control", "status", "chevron" }) do
    local n = assigned[role]
    if n then
      local m = peripheral.wrap(n)
      m.setTextScale(role == "control" and cfg.controlScale or role == "chevron" and cfg.chevronScale or cfg.textScale)
      mons[role] = m
      mons[role .. "Name"] = n
      print(("%-8s -> %s"):format(T("ROLE_" .. role:upper()), n))
      dbg("Monitor %-8s -> %s (%dx%d Zeichen, Skala %s)", role, n, m.getSize() , select(2, m.getSize()), tostring(role == "control" and cfg.controlScale or role == "chevron" and cfg.chevronScale or cfg.textScale))
    end
  end
end
if not mons.control then
  printError(T("ERROR_NO_CONTROL_MONITOR"))
  return
end

------------------------------------------------------------------ Zeichenhilfen
local function fillRect(m, x1, y1, x2, y2, bg)
  m.setBackgroundColor(bg)
  local s = (" "):rep(math.max(0, x2 - x1 + 1))
  for y = y1, y2 do m.setCursorPos(x1, y); m.write(s) end
end

local function put(m, x, y, text, fg, bg)
  if bg then m.setBackgroundColor(bg) end
  m.setTextColor(fg or colors.white)
  m.setCursorPos(x, y)
  m.write(text)
end

local function center(m, y, text, fg, bg, x1, x2)
  local w = m.getSize()
  x1, x2 = x1 or 1, x2 or w
  local width = x2 - x1 + 1
  text = tostring(text):sub(1, width)
  put(m, x1 + math.floor((width - #text) / 2), y, text, fg, bg)
end

local function header(m, title)
  local w = m.getSize()
  fillRect(m, 1, 1, w, 1, colors.blue)
  center(m, 1, title, colors.white, colors.blue)
end

local stateInfo = {
  idle      = { T("STATE_READY"), colors.gray },
  dialing   = { T("STATE_DIALING"), colors.orange },
  connected = { T("STATE_CONNECTED"), colors.lime },
  closing   = { T("STATE_CLOSING"), colors.orange },
  incoming  = { T("STATE_INCOMING"), colors.red },
  unknown   = { T("STATE_UNKNOWN"), colors.purple },
}

------------------------------------------------------------------ Zustand
local S = {
  state = "unknown", raw = "?", localAddr = "?", origin = "?",
  lockedCount = 0, lockedSyms = {}, energy = nil, iris = nil, material = nil,
  turning = false, currentSymbol = nil,
  wormhole = nil,       -- nil | "outgoing" | "incoming"
  closedEvent = false,  -- verhindert Reaktivierung durch verzoegerten getState()-Wert
  closingRequested = false,
  incomingDial = false, -- fremdes Gate waehlt gerade
  target = nil,         -- { name, address, syms }
  connectedAt = nil, blink = false,
  evSeq = 0,             -- zaehlt Gate-Events (Refresh verwirft dann veraltete Abfragen)
  wake = false,          -- Event moechte sofortigen Refresh
  entry = {},            -- am DHD gewaehlte Symbole (ohne 00)
  entryDone = false,     -- Eingabe wurde schon gewaehlt: naechstes Symbol startet neu
}
local D = nil           -- laufender Wahlvorgang { syms, i, sent, t }
local buttons = {}

S.localAddr = fmtValue(safe(gate.getLocalAddress) or "?")
S.origin = fmtValue(safe(gate.getPointOfOrigin) or "?")

local function now() return os.epoch("utc") / 1000 end

-- Blinktakt zeitbasiert (unabhaengig von der Poll-Dauer): 0,4 s an / 0,4 s aus
local function updateBlink()
  S.blink = (math.floor(now() / 0.4) % 2) == 0
end

local function elapsed()
  if not S.connectedAt then return "--:--" end
  local s = math.floor(now() - S.connectedAt)
  return ("%02d:%02d"):format(math.floor(s / 60), s % 60)
end

local function classify(s)
  s = tostring(s):lower()
  if s:find("incoming") or s:find("inbound") then return "incoming" end
  -- Erst Schliesszustaende pruefen: "disconnecting" enthaelt auch "connect".
  if s:find("disconnect") or s:find("closing") or s:find("closed") or s:find("reset") or
      s:find("idle") or s:find("inactive") or s == "close" then return "idle" end
  if s:find("dial") or s:find("chevron") or s:find("engag") or s:find("opening") or s:find("turn") then return "dialing" end
  if s:find("connect") or s:find("open") or s:find("active") or s:find("establish") then return "connected" end
  return "unknown"
end

------------------------------------------------------------------ Wahl-Ablauf (Zustandsautomat)
-- Ruft eine Gate-Methode auf (pcall) und protokolliert Argumente, Rueckgaben und Dauer.
-- Rueckgabe wie pcall: ok, ret1, ret2, ...
local function gcall(name, ...)
  local f = gate[name]
  if type(f) ~= "function" then
    dbg("CALL %s: Methode existiert nicht!", name)
    return false, "Methode fehlt: " .. name
  end
  local args = {}
  for i = 1, select("#", ...) do args[i] = tostring((select(i, ...))) end
  local t0 = os.epoch("utc")
  local r = table.pack(pcall(f, ...))
  local rets = {}
  for i = 2, r.n do rets[#rets + 1] = tostring(r[i]) end
  dbg("CALL %s(%s) -> ok=%s ret=[%s] (%d ms)", name, table.concat(args, ","), tostring(r[1]),
      table.concat(rets, ", "), os.epoch("utc") - t0)
  return table.unpack(r, 1, r.n)
end

local function dialFail(msg)
  dbg("dialFail: %s | D: i=%s sent=%s locked=%s tries=%s", msg, D and D.i or "-", D and tostring(D.sent) or "-",
      D and tostring(D.locked) or "-", D and D.tries or "-")
  log(T("LOG_DIAL_ERROR", msg))
  D = nil
  S.target = nil
  gcall("abort")
end

local MAX_TRIES   = 6
local OPEN_WAIT   = 20  -- s: nach dem letzten Symbol auf das Wurmloch warten

-- Ablauf laut Lantea-Wiki:
--  * encodeSymbol(n) dreht den Ring und verriegelt Symbol n.
--  * Event stargate_chevron_locked kommt, wenn die Verriegelung ABGESCHLOSSEN ist
--    -> erst dann das naechste Symbol senden.
--  * Abgelehnte Befehle (false) werden erneut versucht; angenommene Befehle nicht.
--  * Das Verriegeln des Point of Origin oeffnet das Wurmloch von selbst.
local function stepDial()
  if not D then return end
  local cur = D
  if S.wormhole then D = nil; return end
  local t = now()

  -- 1) Gesendetes Symbol: warten, bis es verriegelt ist
  if D.sent then
    -- Ersatz, falls ein Event verloren ging: Zaehler steht 2 s lang und der Ring ruht
    local settled = S.lockedCount >= D.i and not S.turning
    if settled then D.settledAt = D.settledAt or t else D.settledAt = nil end
    local done = D.locked or (settled and t - D.settledAt > 2)
    if done then
      dbg("STEP Symbol %d/%d verriegelt (via %s, %.1fs nach Senden)", D.i, #D.syms,
          D.locked and "Event" or "Zaehler+Ruhe", t - D.t)
      D.i, D.sent, D.locked, D.tries, D.t, D.next, D.settledAt = D.i + 1, false, false, 0, t, 0, nil
      if D.i > #D.syms then
        D.finishing = true
        dbg("STEP alle Symbole verriegelt - warte auf Wurmloch")
      end
    -- encodeSymbol wurde angenommen (kein Fehler/false), aber das Chevron kann
    -- noch verriegeln, obwohl isRingTurning() bereits false meldet. Nicht erneut
    -- senden: das Gate weist den Doppelaufruf waehrend der Verriegelung ab.
    -- Fehlt eine Verriegelung wirklich, greift unten der Symbol-Timeout.
    elseif t - D.t > cfg.symbolTimeout then
      dialFail(T("LOG_DIAL_TIMEOUT", D.i, S.lockedCount, tostring(S.turning)))
      return
    elseif not D.lastWait or t - D.lastWait >= 2 then
      D.lastWait = t
      dbg("STEP warte auf Verriegelung Symbol %d (%.1fs, Chevrons=%d, dreht=%s, settled=%s)",
          D.i, t - D.t, S.lockedCount, tostring(S.turning), tostring(settled))
    end
  end

  -- 2) Alle Symbole verriegelt: das Gate oeffnet von selbst
  if D.finishing then
    if t - D.t > OPEN_WAIT then dialFail(T("LOG_WORMHOLE_TIMEOUT")) end
    return
  end

  -- 3) Naechstes Symbol senden
  if not D.sent and t >= (D.next or 0) then
    local sym = D.syms[D.i]
    local ok, a, b = gcall("encodeSymbol", sym)
    if D ~= cur then return end -- waehrend des Aufrufs per Event/Touch beendet
    if not ok then dialFail(tostring(a)); return end
    if a == false then -- Gate beschaeftigt: kurz warten, erneut versuchen
      D.tries = D.tries + 1
      if D.tries > MAX_TRIES * 4 then
        dialFail(("Symbol %d abgelehnt: %s"):format(D.i, tostring(b)))
        return
      end
      dbg("STEP Symbol %d abgelehnt (Versuch %d, Grund: %s)", D.i, D.tries, tostring(b))
      if D.tries == 1 then log(T("LOG_GATE_BUSY_WAIT", tostring(b))) end
      D.next = t + 0.5
      return
    end
    log(T("LOG_SYMBOL_SENT", D.i, #D.syms, sym))
    dbg("STEP gesendet: Symbol %d/%d = %d (Chevrons=%d, dreht=%s)", D.i, #D.syms, sym, S.lockedCount, tostring(S.turning))
    D.sent, D.locked, D.t = true, false, t
  end
end

local function isBusy() return D ~= nil or S.wormhole ~= nil or S.incomingDial end

local function entryText()
  local parts = {}
  for _, v in ipairs(S.entry) do parts[#parts + 1] = ("%02d"):format(v) end
  parts[#parts + 1] = "00"
  return table.concat(parts, "-")
end

local function startDial()
  if S.wormhole or S.incomingDial then log(T("LOG_BUSY")); return end
  if D then log(T("LOG_DIAL_RUNNING")); return end
  if #S.entry < MIN_SYMS then
    log(T("LOG_MIN_SYMBOLS", MIN_SYMS, #S.entry))
    return
  end
  local syms = {}
  for i, v in ipairs(S.entry) do syms[i] = v end
  syms[#syms + 1] = 0 -- Point of Origin immer zuletzt
  if S.lockedCount > 0 then gcall("abort") end
  D = { syms = syms, i = 1, sent = false, locked = false, tries = 0, next = 0, t = now() }
  S.target = { name = entryText(), address = entryText(), syms = syms }
  S.entryDone = true
  log(T("LOG_DIAL_TARGET", S.target.name))
  dbg("startDial: Symbole=[%s]  Chevrons=%d", table.concat(syms, ","), S.lockedCount)
end

local function stopAll()
  if S.wormhole == "outgoing" then
    local ok, result = gcall("close")
    if ok and result ~= false then
      S.closingRequested = true
      S.wormhole = nil
      S.connectedAt = nil
      S.target = nil
      D = nil
      log(T("LOG_CLOSE_REQUESTED"))
    else
      log(T("LOG_CLOSE_FAILED", tostring(ok and "rejected" or result)))
    end
  elseif S.wormhole == "incoming" then
    log(T("LOG_INCOMING_CANNOT_CLOSE"))
  else
    D = nil
    S.target = nil
    local ok, err = gcall("abort")
    log(ok and T("LOG_DIAL_ABORTED") or T("LOG_ABORT_FAILED", tostring(err)))
  end
end

local function toggleIris()
  local st = safe(gate.getIrisState)
  if not st or st == "none" then log(T("LOG_NO_IRIS")); return end
  if st == "open" or st == "opening" then
    gcall("closeIris"); log(T("LOG_IRIS_CLOSING"))
  else
    gcall("openIris"); log(T("LOG_IRIS_OPENING"))
  end
  S.slowAt = nil -- Iris-Status sofort neu abfragen
end

------------------------------------------------------------------ Steuerungsmonitor (DHD)
local function addButton(m, x1, y1, x2, y2, label, bg, action)
  fillRect(m, x1, y1, x2, y2, bg)
  center(m, math.floor((y1 + y2) / 2), label, colors.white, bg, x1, x2)
  buttons[#buttons + 1] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, action = action }
end

-- Glyphen-Bitmaps (20x20, je 400 Hex-Ziffern = Helligkeit 0..f, zeilenweise).
-- Reihenfolge = Symbolnummer: [0] = Point of Origin, [1]..[38] = Tasten des DHD.
-- Falls die Nummern im Spiel anders belegt sind, hier die Zuordnung aendern.
local GLYPH_N = 20
local GLYPH_BITS = {
  [0] = "0000000000000000000000000000000000000000000000000000000000000000000009900000000000000008ffff800000000000003ffeeff3000000000000afeffefa0000000000008ffeeff8000000000004ffffffff40000000006ffffffffff60000004fffaffffffafff400009ff1ffffffff1ff900003826ff2ff2ff62830000000efb0ff0bfe0000000000df30ff03fd00000006888899ff99888860000ffffffffffffffff00008bbbbccbbccbbbb8000000000000000000000000000000000000000000",
  [1] = "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000067000000000000000006ffebcfa00000000443affffffff0000000ffffff8857cffe820000ffff90000000eff90000fffc000000005ffa00006ff2000000000de200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
  [2] = "000000000000000000000000000000000000000000000000000000000000002fd00000000002300000aff5000000003ff800007ffc00000000affa000000ff80000005ffb00000004ffe0000eff6000000000fff0000fff0000000000bffb33bffb000000000005ffffff50000000000000ffffff000000000000005ffff5000000000000003ffff3000000000000000ffff00000000000000005ff500000000000000007ff700000000000000000990000000000000000000000000000000000000000000000000",
  [3] = "000000000000000000000000000000000000000000002fff30000000000000008fffe05fa000000000008fffc0fff200000000000ffa00cff000000000000ff0009fa00000000000aff875bf900000000000efffffffe000000000009fccfffff000000000009f1000ff600000000000ff0000ff300000000004ffc004ff400000000000ff5009ff800000000007fa0005ff80000000005ff400006ff800000000cff700000fff600000007ff200001fff500000000000000000c600000000000000000000000000",
  [4] = "000000000000000000000000000000000000000000000000099000000000000000007ff700000000000000005ff500000000000000000ff000000000000000000ff000000000000000000ff000000000000000006ff60000000000000001ffff1000000000000001ffff10000000000000005ff60000000000000000bffd400000000000000cfffffd000000000006effa7dffff00000000cffd20002cff20000000dff3000000da000000003b700000000000000000000000000000000000000000000000000000",
  [5] = "000000000000000000000000000000000000000000000057300000000000000007fff4000000000000000efff9000000000000009ffff700000000000000efffa0000000000000008ff200000000000000004ff900002a20000000005fff9689fff00000000008cffffffffc20000000000ffffc1afffe00000000058bfffbefff0000000000005fffffff00000000000000cff762000000000000000540000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
  [6] = "0000000000000000000000000000000000000000000000000000000000000000000000000000000000028500000000000000003fffc00440357dff00007ffff31fffffffff00002ffffffffffffefd000000ddffffffff400000000001df804fff60000000000000007ffff000000000000004ff9ff700000000000009ff84ffd000000000000fff50fff4000000000affb4009ff1000000003fff00000000000000000ffa0000000000000000014000000000000000000000000000000000000000000000000000",
  [7] = "0000000000000000000000000000000000000000000000009ff90000000000000002ffff2000000000000002ffff200000000000000dffffd0000000000000dff55ffd00000000002bff6006ffb200000000bffffffffffb00000000effffffffffe000000003ff111111ff3000000000ff000001ff0000000000ff300004ff0000000000ff600006ff0000000000ffc0000fff0000000000fff0000eff00000000007f6000006000000000000000000000000000000000000000000000000000000000000000000",
  [8] = "000000000000000000000000000000000000000000000000000004ffe1000000000000000ffff600000000000000effff600000000000000ffffff00000000000000ffffff0000000000000ffffffd0000000000002fffe000000000000001cffd1000000000396008ff800000000000cff307ff60000000005ffff30df70000000000cfff707ff800000000006ffd23dff5000000000004ffffff30000000000000ffffff000000000000001208c400000000000000000000000000000000000000000000000000",
  [9] = "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000044000000000000000031ffb67f30000000024fffffffffd0000000cfffffffffffc0000005fffff80ffffa30000005ffff000fffffff300000cfffc8fff8ffffc0000002ffffff9003ff80000000ffffff100022000000002720440000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
  [10] = "0000000000000000000000000000000000000000000000000000000000000005300000000000000000dff80000000000000000ffffffff943620000000fffffffffffff04000004cff86ffffffffff0000007ff10000bfffff0000000ffd4000025ffb00000006fff10003ff3000000004fffb000ff700000000005bff60aff00000000000008ff4ff7000000000000008fffd0000000000000000fff200000000000000005fa0000000000000000000000000000000000000000000000000000000000000000000",
  [11] = "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002ffe00550000000006ffffff27ff900000000ffffffffdfff10000000ffff04ffffffd0000000fff9008ff97ffb5000000440000cf402fff3000000000006ff20cff1000000000009ff80283000000000000fff5000000000000002cfc4000000000000002fff10000000000000002fff000000000000000008c400000000000000000000000000000000000000000000000000",
  [12] = "0000000000000000000000000000000000000000009c70000000000000000cfff3000000000000000ffff60000000000000006fff6000000000000000027ff000000000000000000cff400000000794000006ffc00000006fff000002ffe0000007ffff0000001ffc00047fff7100000003ff50bffff90000000000bff3fffc4000000000008ffafff40000000000003fffff1000000000000000bff800000000000000008ff800000000000000002a9100000000000000000000000000000000000000000000000",
  [13] = "00000000000000000000000000000000000000000000dff40000000000000005fffc000008f400000003fffb00003ffd000000008ffa00004ff90000000007ff0000afe00000000001ff7000ff6000000000009ffb4aff0000000000002ffffff50000000000000ffffff20000000000005ff4bff1000000000000efc00efc000000000000ff2004ff000000000005ff0000ff60000000000fff0000aff1000000000fff0000dff60000000006c500007ff200000000000000000000000000000000000000000000",
  [14] = "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006ee60000000000000002ffff0000000000022005ffff00006600008ff600ffff0004ff4000cffd0029ff400cffa000fff300003ff09ffff407ff0000000bfaff8dff0ff000000003fffc03ffafb000000000fff0007fff3000000000efc0000fff000000000000000008f90000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
  [15] = "00000000000000000000000000000000000000000000000000000000000000000000000000000000008820000000000000002ffff4600000000000005ffffff80000000000001fffffffef300000000000cd3fffffe94000000000000115fffffa8688000000000001dfffffffc000000000006ff06eff9000000000005ff206ff0000000000009fffdafe0000000000008fffffff00000000000005536fff0000000000000000006000000000000000000000000000000000000000000000000000000000000000",
  [16] = "00000000000000000000000000000000000000000016600000000000000000eff70000000000000000fffe0000000000000000ffffffd00000000000005ffefff50000000000000002ffffe00000000000000000fff900000000000000003fff811882000000000000cffffffa0000000000008ffffff90000000000000ff60ef70000000000000efa0cf90000000000000fffffff0000000000000fffefff0000000000000040005000000000000000000000000000000000000000000000000000000000000000",
  [17] = "00000000033000000000000000008ff80000000000000001ffff1000000000000002ffff20000000000000009ff900000000000640000ff000000000007ff8200ff00000000000bffffffff730000000006fffffffffff958000000010024ffffffff900000000000ff0049ff900000000000ff000058000000000000ff000000000000000000ff000000000000000000ff000000000000000000ff000000000000000008ff800000000000000005ff5000000000000000008800000000000000000000000000000",
  [18] = "00000000000000000000000000000ff00000000000000000ffff0000000000000003ffff3000000000000000ffff0000000000000000ffff0000000000000005ffff400000000000000fffffd00000000000004ffffff40000000000000ffceff10000000000000ff38fc00000000000000ff09fa00000000000004ff09f900000000000009ff0af90000000000002fff5bf90000000000005fffffff0000000000000af8efff000000000000000008c400000000000000000000000000000000000000000000000",
  [19] = "00000000000000000000000000000000000000000000000000000000000000000003100000000000000000aff70000000000000000cfffd4000000000000000affff0000000000000006ffffb6000000000000affffffff8800000003effdffffffff900008fffd30ff8806ff90000cff6000ff000058000004ff1000ff000000000000000000ff000000000000000000ff000000000000000001ff100000000000000009ff900000000000000003ff3000000000000000000000000000000000000000000000000",
  [20] = "00000000000000000000000000000000000000000000000000000000000000000000000000000000000028600000162000000002ffffeefffff000000006fffffffffff000000001fffc8766bfd0000000003ff000008fd0000004972ff000007fe000000fff8ff000007ff000000ffffff100006ff00000027efffa87769ff0000000009ffffffffff5000000002ffedeffffff7000000000000000057ffff30000000000000004fff900000000000000008ff50000000000000000000000000000000000000000",
  [21] = "000000000000000000000000000000000000000000000000008c400041000000000000fff00cff000000000004fff02fff00000000000ff616fffa0000000000ffa07ffa00000000000fffafffc000000000004ffffffb0000000000000ffffff00000000000008fffc100000000000005fffe000000000000001dfff100000000000045efff3000000000000effff400000000000005ffff0000000000000001ffff00000000000000004bb40000000000000000000000000000000000000000000000000000000",
  [22] = "00000000033000000000000000009ff90000000000000001ffff1000000000000002ffff20000000000000009ff90540000000000000afb8dff4000000000005fffffff5000000000008fffe9ba000000000000ffff000000000000005dffbff6000000000000fff00fff200000000000fff00eff700000000003ff3002aff20000000008fa00000ffa000000007ff0000006ff90000000fff0000003ffd00000000e700000008f40000000000000000000000000000000000000000000000000000000000000000",
  [23] = "00000000000000000000000000000ff00000000000000000ffff0000000000000003ffff300000000000005ffffff500000000001dffb55bffd10000002ffff600006ffff20000affe40000004effa0000aff5000000005ffa00002ff5000000005ff2000003fa00000000af30000000ff00000000ff00000000cf10000001fc000000008fa000000af8000000004ff766667ff4000000006ffffffffff6000000001ffdcbbcdff10000000002300000032000000000000000000000000000000000000000000000",
  [24] = "00000000033000000000000000009ff90000000000000001ffff1000000000000002ffff2000000000000003ffff500000000000000ffb9ff3000000000000dff10fff60000000000fff4001fff0000000000fff0000fff0000000000bff0000afa00000000001ff2000cf800000000000ffc000df8000000000006ff001ff9000000000000ffa09fff000000000003fff0dff9000000000000afffff0000000000000000fff700000000000000008ff700000000000000000c90000000000000000000000000000",
  [25] = "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000ffd0000000000000000efff4000000000384000ffff6000000000fff0008fff5000000000fff000026ff600000009ff5000000dff300000eff00000000dffc41016fff000000003fffffcffffb00000000005ffffffc40000000000006eaafd000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
  [26] = "000000000000000000000000000000000000000000aa300000000007ff500cffa0000000000fffd00afff200000001cfff400058fffd4037effb000000007fffffffffd0000000003fffffffff30000000000ffff001ff000000000005ff0000ff100000000000ff0000ff500000000000ffceffffd00000000006fffffffff0000000000dfffb62bff5000000004ff8000006ff0000002aff400000009ff70000aff7000000000fff0000aff4000000000fff00000ca00000000003d50000000000000000000000",
  [27] = "0000000000000000000000000000000000000000001eff50000000000000006fffff400000000000006ffffff10000000000006ffeffd0000000000000cfffff000400000000005fffff40cff100000000000dfffafff80000000000002fffffffb2000000000006ff708ffe00000000000048002ffb00000000000000002ff10000000000000000dff00000000000000000fff400000000000000007efffc00000000000000003fff00000000000000000cff000000000000000000000000000000000000000000",
  [28] = "00000000033000000000000000009ff90000000000000001ffff1000000000000002ffff2000000000000009ffff90000000000000aff55ffa000000000009ff7007ff9000000000afffeeeefffa00000000ffffffffffff000000008ff878878ff8000000006fc000000cf6000000006fc000000cf6000000006fc000000cf6000000006fc000000cf6000000006fc000000cf600000000cffffffffffc00000000dffffffffffd000000003b74444447b300000000000000000000000000000000000000000000",
  [29] = "0000000000000000000000000002ff40000000000000000efff0000000000000000ffff0000000000000000cffe000000000000000005fa000000000000000001ff1000000000000067bfff80000000000003ffffff00000000000005fff6af4002950000000089206ffcffff3000000000009fffffff100000000000bfff8483000000000000fffff00000000000000cf94fff400000000000eff005ffe00000000004fff000ff800000000000ffb00004000000000000000000000000000000000000000000000",
  [30] = "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000198100000000000000008ff8000000000000002ffff600000000000000cffc500000000000003ffff500000000000006fff980000000000007fff8100000000000acffff1000000000000effff920000000000001ffff5000000000000000ffff20000000000000000670000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
  [31] = "00000000000000000000000000000000000000000000000000000000000000000000000000000000002870000000004e800000fffb0000648efff30000ffff4307fffffff00000fffffffffff8440000002edcffffff40000000000002ff80ff60000000000004ff00cfd0000000000006ff00fff300000000000bfd00cffe10000000000fff0004ff90000000000fff00008ffb00000000026100000cff400000000000000002ff0000000000000000002100000000000000000000000000000000000000000000",
  [32] = "00000000000000000000000000000000000000000016600000000000000000eff7000000000df20000fffe000000005ffa0000ffff00000000cff600005fffb000000bff000000003ffa2002aff3000000000affffffffa00000000006ffffffff600000000000bff11ffb0000000000005ff00ff50000000000000ff00ff00000000000000ff33ff00000000000000ffaaff00000000000003ffffff30000000000000ffeeff0000000000000014004100000000000000000000000000000000000000000000000",
  [33] = "00000000000000000000000000000000000000000000000000000000000000004100000008f40000002fff899ceffffd0000007ffffffffffffa0000004fffc2000002f900000005ff00000000fb00000000cf00000000fe000000009f20000000ff000000007fa0000000cf000000005ff00000009f000000002ff0002457dfd00000001ffffffffffff4000000affffffffffff10004ffffe52000000000000efff00000000000000005ff70000000000000000000000000000000000000000000000000000000",
  [34] = "0000000000000000000000000000000000000000000031000000000000000007ff00000000000000007fff000000000000002fffffe30000000000005ffffffc0000000000001ffffffe00000000000000ce24ff9100000000000000009ffe87000000000000001fffff7001000000000003a8ffc0df500000000000009ffcfff000000000000009fffff300000000000004ffdfff700000000000003606fff10000000000000001ffd0000000000000000003000000000000000000000000000000000000000000",
  [35] = "00000000000000000000000000000000000000000000000000000000000000004205f90000000000002fffcfff1000000000007fffffff0000000000004fffd3ff00000000000006ff03ff40000000000000dfffffd0000000000000fffffff40000000000005c6004ff700000000000000000bff100000000000000001effc00000000000000000fff00000000000000000cffc000000000000000000cffc00000000000000000fff00000000000000000cff000000000000000000000000000000000000000000",
  [36] = "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000007e900000000000000005fff000000000000000bffff00000000000006fffa41000039100004cfff60000000fff0004fffc300000000fff00bfff400000000008fc3fffd4000000000008fffff70000000000000fffff200000000000000ffff0000000000000000dfffffa0000000000000053dfff20000000000000002ffe000000000000000000000000000000000000000000000000000",
  [37] = "0000000000000000000000000000000000000000000000000031000000000000000005ff300000000000000009ff80000000000000000fffc000000000000000efeff300000000000006ff2cff1000000000000ff900ff800000000000cff2009ff00000000009ff10000ff7000000001ff8000000ffa000001efff99adffffff300007ffffffffffffff200006ffffda987544840000007eb0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
  [38] = "00000000000000000000000000000000000000000018c500000000000000008fff0000000000000000cfff70000000000000005ffff300000000000000007fff500000000000000003fffb00000671000000004fff20008ff8000000000cfffffffffa00000000000afffc8882000000000002ff300000000000000000ff500000000000000000ef700000000000000000bf800000000000000000eff20000000000000000fff200000000000000004c800000000000000000000000000000000000000000000000",
}

-- Handflaeche fuer die Freigabe (Handscan), 20x20
do
  local rows = {
    "00000000000000000000",
    "00000000ff0000000000",
    "00000000ff0ff0000000",
    "00000ff0ff0ff0000000",
    "00000ff0ff0ff0000000",
    "00000ff0ff0ff0ff0000",
    "00000ff0ff0ff0ff0000",
    "00000ff0ff0ff0ff0000",
    "00000ff0ff0ff0ff0000",
    "00000ffffffffffff000",
    "00ff0ffffffffffff000",
    "00ffffffffffffffff00",
    "000fffffffffffffff00",
    "0000ffffffffffffff00",
    "0000ffffffffffffff00",
    "00000ffffffffffff000",
    "00000ffffffffffff000",
    "000000ffffffffff0000",
    "000000ffffffffff0000",
    "00000000000000000000",
  }
  GLYPH_BITS.hand = table.concat(rows)
end

local glyphCache = {}
-- Skaliert ein Glyph auf S x S Pixel (Flaechenmittel + Schwelle). Gibt Tabelle von Booleans zurueck.
local function glyphBitmap(sym, S)
  local data = GLYPH_BITS[sym]
  if not data then return nil end
  local key = sym .. ":" .. S
  local cached = glyphCache[key]
  if cached then return cached end
  local px = {}
  local k = GLYPH_N / S
  for y = 0, S - 1 do
    local y0, y1 = y * k, (y + 1) * k
    for x = 0, S - 1 do
      local x0, x1 = x * k, (x + 1) * k
      local tot, wsum = 0, 0
      for yy = math.floor(y0), math.min(GLYPH_N - 1, math.ceil(y1) - 1) do
        local wy = math.min(yy + 1, y1) - math.max(yy, y0)
        for xx = math.floor(x0), math.min(GLYPH_N - 1, math.ceil(x1) - 1) do
          local wx = math.min(xx + 1, x1) - math.max(xx, x0)
          local i = yy * GLYPH_N + xx + 1
          local v = tonumber(data:sub(i, i), 16) or 0
          tot = tot + v / 15 * wx * wy
          wsum = wsum + wx * wy
        end
      end
      px[y * S + x + 1] = wsum > 0 and (tot / wsum) > 0.45
    end
  end
  glyphCache[key] = px
  return px
end

local TELE_BIT = { 1, 2, 4, 8, 16 }
-- Zeichnet ein Glyph in eine Taste aus fw x fh Zeichen (je 2x3 Teilpixel) mit Teletext-Zeichen.
local function drawGlyphCell(m, x1, y1, fw, fh, S, sym, fg, bg)
  local px = glyphBitmap(sym, S)
  local ox, oy = math.floor((fw * 2 - S) / 2), math.floor((fh * 3 - S) / 2)
  local function on(x, y)
    local gx, gy = x - ox, y - oy
    if gx < 0 or gy < 0 or gx >= S or gy >= S then return false end
    return px[gy * S + gx + 1]
  end
  local fgh, bgh = colors.toBlit(fg), colors.toBlit(bg)
  for r = 0, fh - 1 do
    local t, f, b = {}, {}, {}
    for c = 0, fw - 1 do
      local x, y = c * 2, r * 3
      local p = { on(x, y), on(x + 1, y), on(x, y + 1), on(x + 1, y + 1), on(x, y + 2), on(x + 1, y + 2) }
      local code, tf, tb = 0, fgh, bgh
      if p[6] then
        -- Unten rechts ist im Teletext-Zeichen immer Hintergrund: Farben tauschen, Bits umkehren
        tf, tb = bgh, fgh
        for i = 1, 5 do if not p[i] then code = code + TELE_BIT[i] end end
      else
        for i = 1, 5 do if p[i] then code = code + TELE_BIT[i] end end
      end
      t[c + 1], f[c + 1], b[c + 1] = string.char(128 + code), tf, tb
    end
    m.setCursorPos(x1, y1 + r)
    m.blit(table.concat(t), table.concat(f), table.concat(b))
  end
end

-- Glyphen-Raster: waehlt Spaltenzahl mit der groessten Glyphengroesse S (mind. 9 Pixel).
local function glyphLayout(w, h, groups, bh)
  local n = #glyphs
  local avail = h - 3 - #groups * bh
  local best
  for cols = 4, 10 do
    local cellW = math.floor((w + 1) / cols)
    local fw = cellW - 1
    local rows = math.ceil(n / cols)
    if fw >= 4 then
      local fhNo = math.floor(avail / rows)
      local fhGap = math.floor((avail + 1) / rows) - 1   -- mit Leerzeile zwischen den Reihen
      local sNo = math.min(2 * fw, 3 * fhNo, GLYPH_N)
      local sGap = math.min(2 * fw, 3 * fhGap, GLYPH_N)
      local fh, S, cellH = fhNo, sNo, fhNo
      if fhGap >= 3 and sGap >= sNo then fh, S, cellH = fhGap, sGap, fhGap + 1 end
      if fh >= 3 and S >= 9 and (not best or S > best.S or (S == best.S and cols > best.cols)) then
        best = { mode = "glyph", cols = cols, rows = rows, cellW = cellW, fw = fw, fh = fh, S = S,
                 cellH = cellH, gridY = 4, groups = groups, bh = bh }
      end
    end
  end
  return best
end

------------------------------------------------------------------ Symbolnamen
-- Laengster Symbolname (fuer die Tastenbreite), begrenzt durch maxNameLen.
local nameMax = 0
for _, s in ipairs(glyphs) do
  local nm = symName[s]
  if type(nm) == "string" and #nm > nameMax then nameMax = #nm end
end
nameMax = math.min(nameMax, cfg.maxNameLen)

local function symLabel(sym, len)
  local nm = symName[sym]
  if type(nm) ~= "string" then return "" end
  return nm:sub(1, len)
end

-- "07 Name" bzw. "07"
local function symText(sym, withName)
  local nm = withName and symLabel(sym, 10) or ""
  return ("%02d"):format(sym) .. (nm ~= "" and (" " .. nm) or "")
end

local function addrLine(syms, withNames)
  local parts = {}
  for _, v in ipairs(syms) do parts[#parts + 1] = symText(v, withNames) end
  return table.concat(parts, withNames and " | " or " ")
end

-- Adresse auf eine Zeile: mit Namen, wenn es passt, sonst nur Nummern (links gekuerzt).
local function fitAddr(syms, width)
  if #syms == 0 or width < 1 then return "" end
  local s = addrLine(syms, true)
  if #s <= width then return s end
  s = addrLine(syms, false)
  if #s > width then s = ".." .. s:sub(-math.max(1, width - 2)) end
  return s
end

------------------------------------------------------------------ Lesezeichen
-- Datei sg_bookmarks.lua:  { { name = "Abydos", syms = { 27, 7, 15, 32, 12, 30 } }, ... }
-- (ohne Point of Origin). Namen aendern: im Terminal  name <Nr> <Text>
local BOOKMARK_FILE = "sg_bookmarks.lua"
local bookmarks = {}
do
  local loaded = loadTable(BOOKMARK_FILE)
  for i, b in ipairs(loaded or {}) do
    if type(b) == "table" and type(b.syms) == "table" and #b.syms > 0 then
      bookmarks[#bookmarks + 1] = { name = tostring(b.name or T("DEFAULT_BOOKMARK_NAME", i)), syms = b.syms }
    end
  end
end
local function saveBookmarks() saveTable(BOOKMARK_FILE, bookmarks) end

local function bmSig()
  local t = {}
  for i, b in ipairs(bookmarks) do t[i] = b.name .. "#" .. #b.syms end
  return table.concat(t, ",")
end

-- Ansichten der Steuerung: "dhd" | "bookmarks" | "palm"
S.view, S.viewAt, S.bmPage, S.bmDel, S.palm = "dhd", 0, 1, nil, nil
local function setView(v)
  S.view, S.viewAt, S.palm, S.bmDel = v, now(), nil, nil
end

local function addBookmark()
  if #S.entry < MIN_SYMS then
    log(T("LOG_MIN_BOOKMARKS", MIN_SYMS)); return
  end
  local key = table.concat(S.entry, "-")
  local taken = {}
  for _, b in ipairs(bookmarks) do
    if table.concat(b.syms, "-") == key then log(T("LOG_ALREADY_SAVED", b.name)); return end
    taken[b.name] = true
  end
  local n = #bookmarks + 1
  while taken[T("DEFAULT_BOOKMARK_NAME", n)] do n = n + 1 end
  local copy = {}
  for i, v in ipairs(S.entry) do copy[i] = v end
  local defaultName = T("DEFAULT_BOOKMARK_NAME", n)
  bookmarks[#bookmarks + 1] = { name = defaultName, syms = copy }
  saveBookmarks()
  log(T("LOG_BOOKMARK_SAVED", defaultName))
end

local function loadBookmark(i)
  local b = bookmarks[i]
  if not b then return end
  if isBusy() then log(T("LOG_BUSY_STOP")); return end
  S.entry = {}
  for k, v in ipairs(b.syms) do S.entry[k] = v end
  S.entryDone = false
  setView("dhd")
  log(T("LOG_BOOKMARK_LOADED", b.name))
end

local function deleteBookmark(i)
  if S.bmDel == i then
    local b = table.remove(bookmarks, i)
    saveBookmarks()
    S.bmDel = nil
    log(T("LOG_BOOKMARK_DELETED", b and b.name or "?"))
  else
    S.bmDel = i -- erst nochmal tippen zum Bestaetigen
  end
end

------------------------------------------------------------------ Handscan (Freigabe)
-- Wie in der Serie: Hand aufs Display legen. CC:Tweaked kennt nur Touch-Events
-- (Rechtsklick). Wer die Maustaste gedrueckt haelt, loest wiederholt Touch-Events aus:
--   palmMode "hold": Touches muessen palmHoldSeconds lang ohne Luecke > palmGap kommen
--   palmMode "taps": palmTaps schnelle Touches hintereinander (Fallback)
local function palmProgress()
  local P = S.palm
  if not P then return 0 end
  local t = now()
  if t - P.last > cfg.palmGap then S.palm = nil; return 0 end
  if cfg.palmMode == "taps" then return math.min(1, P.taps / cfg.palmTaps) end
  return math.min(1, (t - P.t0) / cfg.palmHoldSeconds)
end

local function palmTouch()
  local t = now()
  local P = S.palm
  if not P or t - P.last > cfg.palmGap then
    P = { t0 = t, last = t, taps = 0 }
    S.palm = P
  end
  P.last = t
  P.taps = P.taps + 1
  if palmProgress() >= 1 then
    log(T("LOG_HANDSCAN_OK"))
    setView("dhd")
    startDial()
  end
end

-- WAHL-Taste: mit Freigabe erst den Handscan anzeigen.
local function requestDial()
  if not cfg.palmRequired then startDial(); return end
  if S.wormhole or S.incomingDial then log(T("LOG_BUSY")); return end
  if D then log(T("LOG_DIAL_RUNNING")); return end
  if #S.entry < MIN_SYMS then
    log(T("LOG_MIN_SYMBOLS", MIN_SYMS, #S.entry)); return
  end
  setView("palm")
  log(T("LOG_AUTH_PROMPT"))
end

------------------------------------------------------------------ Layout (Steuerungsmonitor)
-- Tasten mit Nummer + Name. Stapel = Nummer, Name, Schattenkante (3 Zeilen);
-- sonst "07 Name" + Schattenkante (2 Zeilen); zuletzt flach (1 Zeile).
-- Zuerst volle Namen versuchen, dann bis minNameLen kuerzen; passt nichts: nil.
local function nameLayout(w, h, groups, bh)
  if not cfg.showNames or nameMax < 1 then return nil end
  local n = #glyphs
  local avail = h - 3 - #groups * bh
  local minLen = math.max(1, math.min(cfg.minNameLen, nameMax))
  -- Erst 3D-Tasten (Stapel, dann einzeilig mit Kante), danach flach. Innerhalb: lange Namen zuerst.
  local passes = {
    { { stacked = true, fh = 3 }, { stacked = false, fh = 2 } },
    { { stacked = false, fh = 1 } },
  }
  for _, pass in ipairs(passes) do
    for len = nameMax, minLen, -1 do
      for _, v in ipairs(pass) do
        local fw = v.stacked and math.max(len, 2) or (len + 3)
        local cellW = fw + 1
        local cols = math.floor((w + 1) / cellW)
        if cols >= 1 then
          local rows = math.ceil(n / cols)
          if rows * v.fh <= avail then
            local gap = (rows > 1 and rows * v.fh + rows - 1 <= avail) and 1 or 0
            return { mode = "name", stacked = v.stacked, fh = v.fh, fw = fw, cellW = cellW,
                     cellH = v.fh, gap = gap, cols = cols, rows = rows, gridY = 4, groups = groups,
                     bh = bh, nameLen = len, full = (len >= nameMax) }
          end
        end
      end
    end
  end
  return nil
end

-- Rasteraufteilung: Symboltasten oben, Funktionstasten unten. nil = passt nicht.
-- rank: 3 = Nummer + Name, 2 = Glyphenbild (nur useGlyphs), 1 = nur Nummern.
local function controlLayout(w, h, noBm)
  local groups, bh
  if noBm then
    if w >= 25 then groups, bh = { { 1, 2, 3, 4, 5 } }, 3
    else groups, bh = { { 1, 2, 5 }, { 3, 4 } }, 2 end
  else
    if w >= 30 then groups, bh = { { 1, 2, 3, 4, 5, 6 } }, 3
    else groups, bh = { { 1, 2, 6 }, { 3, 4, 5 } }, 2 end
  end
  if h < 16 then bh = 1 end
  for _, bhTry in ipairs({ bh, 1 }) do
    local L = nameLayout(w, h, groups, bhTry)
    if L then L.rank = 3; return L end
  end
  if cfg.useGlyphs then
    for _, bhTry in ipairs({ bh, 1 }) do
      local L = glyphLayout(w, h, groups, bhTry)
      if L then L.rank = 2; return L end
    end
  end
  local n = #glyphs
  for _, bhTry in ipairs({ bh, 1 }) do
    for _, cellW in ipairs({ 4, 3 }) do
      local cols = math.floor((w + 1) / cellW)   -- letzte Spalte ohne Luecke
      if cols >= 1 then
        local rows = math.ceil(n / cols)
        local avail = h - 3 - #groups * bhTry
        if avail >= rows then
          local cellH = (avail >= rows * 2) and 2 or 1
          local gap = (rows > 1 and rows * cellH + rows - 1 <= avail) and 1 or 0
          return { mode = "num", rank = 1, groups = groups, bh = bhTry, cellW = cellW, cols = cols,
                   rows = rows, cellH = cellH, fh = cellH, gap = gap, gridY = 4 }
        end
      end
    end
  end
  return nil
end

-- Lesezeichen werden ausschliesslich in ihrer eigenen Menueansicht angezeigt.
local function splitLayout(w, h)
  return controlLayout(w, h, false), w, 0
end

-- Waehlt die groesste Schrift, bei der noch das beste Wahlraster passt.
-- Wird beim Start und bei jeder Aenderung der Monitorgroesse ausgefuehrt.
local SCALES = { 5, 4, 3, 2.5, 2, 1.5, 1, 0.5 }
local function pickControlScale()
  local m = mons.control
  if not cfg.autoScale then
    pcall(m.setTextScale, cfg.controlScale)
    S.pickW, S.pickH = m.getSize()
    return
  end
  local best
  for _, sc in ipairs(SCALES) do
    if pcall(m.setTextScale, sc) then
      local w, h = m.getSize()
      local L, mw, sw = splitLayout(w, h)
      if L then
      local score = L.rank * 1000
                      + ((L.mode == "name" and L.full) and 15 or 0) + sc * 10
        if not best or score > best.score then
          best = { score = score, scale = sc, mode = L.mode, side = sw }
        end
      end
    end
  end
  local sc = best and best.scale or 0.5
  pcall(m.setTextScale, sc)
  S.pickW, S.pickH = m.getSize()
  dbg("Steuerungsmonitor: Skala %s (%dx%d Zeichen), Layout %s, Sidebar %s", tostring(sc), S.pickW, S.pickH,
      best and best.mode or "keins", best and tostring(best.side) or "0")
end

------------------------------------------------------------------ Design (Tasten, Farben)
-- Eigene Farbpalette nur fuer den Steuerungsmonitor. Jede Taste hat Flaeche + dunklere Kante.
local PALETTE = {
  [colors.white]     = 0xEDF7FA, [colors.orange]   = 0xD9A83F, [colors.magenta] = 0x153B52,
  [colors.lightBlue] = 0x79D8F2, [colors.yellow]   = 0xFFD166, [colors.lime]    = 0x66D9A4,
  [colors.pink]      = 0x713642, [colors.gray]     = 0x48616F, [colors.lightGray] = 0x708D9D,
  [colors.cyan]      = 0x25A8C7, [colors.purple]   = 0x367B9B, [colors.blue]    = 0x14506F,
  [colors.brown]     = 0x253F50, [colors.green]    = 0x188B83, [colors.red]     = 0xD95059,
  [colors.black]     = 0x08131D,
}
local function applyCtrlPalette(m)
  pcall(function() for c, rgb in pairs(PALETTE) do m.setPaletteColor(c, rgb) end end)
end
local function resetCtrlPalette(m)
  pcall(function() for c in pairs(PALETTE) do m.setPaletteColor(c, term.nativePaletteColor(c)) end end)
end

-- { Flaeche, Kante }
local STY = {
  green  = { colors.cyan,      colors.blue },
  red    = { colors.red,       colors.pink },
  orange = { colors.blue,      colors.magenta },
  cyan   = { colors.purple,    colors.blue },
  purple = { colors.blue,      colors.magenta },
  gray   = { colors.gray,      colors.magenta },
  brown  = { colors.lightGray, colors.gray },
}

local SHADE = string.char(143) -- oben 2/3 Zeichen Flaeche, unteres Drittel Kante
-- Zeichnet eine Taste; ab 2 Zeilen bildet die letzte Zeile die Kante (wirkt wie ein erhabener Knopf).
-- Rueckgabe: Zahl der Flaechenzeilen.
local function keyBase(m, x1, y1, x2, y2, face, shadow)
  local n = x2 - x1 + 1
  if n < 1 then return 1 end
  if y2 - y1 + 1 >= 2 then
    fillRect(m, x1, y1, x2, y2 - 1, face)
    m.setCursorPos(x1, y2)
    m.blit(SHADE:rep(n), colors.toBlit(face):rep(n), colors.toBlit(shadow):rep(n))
    return y2 - y1
  end
  fillRect(m, x1, y1, x2, y2, face)
  return 1
end

local function addKey(m, x1, y1, x2, y2, label, sty, action, fg)
  -- Flache Tasten verhindern eine zweite Schatten-Farbzeile am unteren Rand.
  fillRect(m, x1, y1, x2, y2, sty[1])
  center(m, y1 + math.floor((y2 - y1) / 2), label,
         fg or (sty[1] == colors.orange and colors.black or colors.white), sty[1], x1, x2)
  buttons[#buttons + 1] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, action = action }
end

local function headerW(m, x1, x2, title)
  fillRect(m, x1, 1, x2, 1, colors.blue)
  center(m, 1, title, colors.white, colors.blue, x1, x2)
end

------------------------------------------------------------------ Steuerungsmonitor (Ansichten)
-- Mehrere Tasten in einer Reihe ab Spalte ox (Breite bw), Breite nach Gewicht (d[4]).
local function buttonRow(m, ox, bw, y1, y2, defs)
  local total = 0
  for _, d in ipairs(defs) do total = total + d[4] end
  local xs, acc = ox, 0
  for i, d in ipairs(defs) do
    acc = acc + d[4]
    local xe = (i == #defs) and (ox + bw - 1) or (ox - 1 + math.floor(bw * acc / total))
    local vis = (i < #defs and xe - xs >= 2) and (xe - 1) or xe
    addKey(m, xs, y1, vis, y2, d[1], d[2], d[3])
    buttons[#buttons].x2 = xe -- Trefferflaeche inkl. Luecke
    xs = xe + 1
  end
end

-- Eigenstaendiges Lesezeichenmenue mit klaren Karten, Ladeflaeche und Loeschknopf.
local function drawBookmarks(m, w, h)
  local footerH = (h >= 8) and 2 or 1
  local listTop, listBottom = 4, h - footerH
  local rows = math.max(0, listBottom - listTop + 1)
  local cardH = rows >= 3 and 2 or 1
  local stride = cardH + ((rows >= cardH * 2 + 1) and 1 or 0)
  local perPage = math.max(1, math.floor(rows / stride))
  local pages = math.max(1, math.ceil(#bookmarks / perPage))
  S.bmPage = math.max(1, math.min(S.bmPage, pages))

  headerW(m, 1, w, T("TITLE_BOOKMARKS"))
  local hint = (pages > 1) and T("DIAL_PAGE", S.bmPage, pages)
      or T("DIAL_COUNT", #bookmarks)
  center(m, 2, hint, colors.lightBlue, colors.black)
  local xw = math.max(3, math.min(6, math.floor(w * 0.14)))
  local mainEnd = math.max(1, w - xw - 1)
  local mainW = mainEnd

  if #bookmarks == 0 then
    center(m, math.max(4, math.floor((h - footerH) / 2)), T("EMPTY_BOOKMARKS"), colors.lightGray, colors.black)
    if h >= 9 then center(m, math.max(5, math.floor((h - footerH) / 2) + 1), T("EMPTY_BOOKMARKS_HINT"), colors.gray, colors.black) end
  else
    for k = 1, perPage do
      local idx = (S.bmPage - 1) * perPage + k
      local b = bookmarks[idx]
      if not b then break end
      local y1 = listTop + (k - 1) * stride
      local y2 = math.min(listBottom, y1 + cardH - 1)
      if y1 <= listBottom then
        local face = (k % 2 == 1) and colors.gray or colors.black
        fillRect(m, 1, y1, mainEnd, y2, face)
        local nameText = ("%02d  %s"):format(idx, b.name)
        put(m, 2, y1, nameText:sub(1, math.max(1, mainW - 2)), colors.white, face)
        if cardH >= 2 then
          put(m, 2, y1 + 1, fitAddr(b.syms, math.max(1, mainW - 2)), colors.lightBlue, face)
        end
        local pending = S.bmDel == idx
        local delColor = pending and colors.red or colors.lightGray
        fillRect(m, mainEnd + 1, y1, w, y2, pending and colors.red or colors.blue)
        center(m, y1, pending and T("BOOKMARK_CONFIRM") or T("BOOKMARK_DELETE_SHORT"), colors.white, pending and colors.red or colors.blue, mainEnd + 1, w)
        if y2 > y1 then center(m, y1 + 1, T("BOOKMARK_DELETE"), colors.white, pending and colors.red or colors.blue, mainEnd + 1, w) end
        buttons[#buttons + 1] = { x1 = 1, y1 = y1, x2 = mainEnd, y2 = y2, action = "bmload", idx = idx }
        buttons[#buttons + 1] = { x1 = mainEnd + 1, y1 = y1, x2 = w, y2 = y2, action = "bmdel", idx = idx }
      end
    end
  end

  local by1 = h - footerH + 1
  buttonRow(m, 1, w, by1, h, {
    { T("BTN_DIAL"), STY.gray, "bmback", 3 },
    { T("BTN_SAVE"), STY.green, "bmsave", 3 },
    { T("BTN_PREV"), STY.orange, "bmprev", 1 },
    { T("BTN_NEXT"), STY.orange, "bmnext", 1 },
  })
end

local function drawPalm(m, w, h)
  header(m, T("TITLE_RELEASE"))
  local p = palmProgress()
  local active = S.palm ~= nil
  local msg = (cfg.palmMode == "taps") and T("PALM_TAPS") or T("PALM_HOLD")
  if #msg > w - 2 then msg = T("PALM_SHORT") end
  center(m, 2, msg, active and colors.lime or colors.white, colors.black)
  put(m, 2, 3, fitAddr(S.entry, w - 2):sub(1, w - 2), colors.lightBlue, colors.black)

  local zoneTop = (h >= 9) and 4 or 3
  local barY, txtY, zoneBottom
  if h >= 9 then barY, txtY, zoneBottom = h - 2, h - 1, h - 3
  else barY, zoneBottom = h - 1, h - 2 end
  local zx1, zx2 = (w >= 6) and 2 or 1, (w >= 6) and (w - 1) or w

  if zoneBottom >= zoneTop then
    local zw, zh = zx2 - zx1 + 1, zoneBottom - zoneTop + 1
    fillRect(m, zx1, zoneTop, zx2, zoneBottom, colors.gray)
    local ps = math.min(2 * zw, 3 * zh, 40)
    local fg = active and colors.lime or colors.lightBlue
    if ps >= 6 then
      local fw, fh = math.ceil(ps / 2), math.ceil(ps / 3)
      drawGlyphCell(m, zx1 + math.floor((zw - fw) / 2), zoneTop + math.floor((zh - fh) / 2),
                    fw, fh, ps, "hand", fg, colors.gray)
    else
      center(m, zoneTop + math.floor((zh - 1) / 2), T("PALM_HAND"), fg, colors.gray, zx1, zx2)
    end
  end
  buttons[#buttons + 1] = { x1 = 1, y1 = 2, x2 = w, y2 = math.max(2, h - 1), action = "palm" }

  -- Fortschrittsbalken
  local bw = zx2 - zx1 + 1
  fillRect(m, zx1, barY, zx2, barY, colors.black)
  fillRect(m, zx1, barY, zx2, barY, colors.gray)
  local fillW = math.floor(bw * p + 0.5)
  if fillW > 0 then fillRect(m, zx1, barY, zx1 + fillW - 1, barY, colors.lime) end
  if txtY then center(m, txtY, T("PALM_SCAN", math.floor(p * 100)), colors.white, colors.black) end

  addKey(m, 1, h, w, h, T("BTN_AUTH_CANCEL"), STY.red, "palmcancel")
  -- ABBRUCH liegt ueber der Palm-Flaeche: zuerst pruefen
  local cancel = table.remove(buttons)
  table.insert(buttons, 1, cancel)
end

local function drawControl()
  local m = mons.control
  if not S.ctrlPal then S.ctrlPal = true; applyCtrlPalette(m) end
  local cw, ch = m.getSize()
  if not S.ctrlPicked or cw ~= S.pickW or ch ~= S.pickH then
    S.ctrlPicked = true
    pickControlScale()
  end
  local w, h = m.getSize()
  local L, mw = splitLayout(w, h)
  buttons = {}
  m.setBackgroundColor(colors.black); m.clear()

  if S.view == "bookmarks" then drawBookmarks(m, w, h); return end
  if S.view == "palm" then drawPalm(m, w, h); return end

  headerW(m, 1, mw, mw >= 24 and T("TITLE_DIAL") or T("TITLE_DHD"))
  local info = stateInfo[S.state] or stateInfo.unknown
  -- Status als durchgehende Leiste: der Zustand ist so auch aus etwas Abstand
  -- erkennbar und konkurriert nicht mit der Adresseingabe darunter.
  fillRect(m, 1, 2, mw, 2, info[2])
  center(m, 2, info[1], colors.black, info[2], 1, mw)
  if not L then
    put(m, 2, 3, T("LABEL_TOO_SMALL"):sub(1, mw - 2), colors.red, colors.black)
    return
  end

  -- Adresseingabe als kompakte Statuskarte.
  fillRect(m, 1, 3, mw, 3, colors.gray)
  local count = ("%d/%d"):format(#S.entry, MAX_SYMS)
  put(m, 2, 3, count, #S.entry >= MIN_SYMS and colors.lime or colors.lightBlue, colors.gray)
  local addrX = math.min(7, mw)
  local addrW = math.max(0, mw - addrX)
  if addrW > 0 then
    local address = #S.entry == 0 and T("ENTRY_EMPTY") or fitAddr(S.entry, addrW)
    put(m, addrX, 3, address:sub(1, addrW), #S.entry == 0 and colors.lightGray or colors.lightBlue, colors.gray)
  end

  -- Symboltasten
  local busy = isBusy()
  local used = {}
  for _, v in ipairs(S.entry) do used[v] = true end
  local x0 = math.floor((mw - (L.cols * L.cellW - 1)) / 2) + 1
  for i, sym in ipairs(glyphs) do
    local c, r = (i - 1) % L.cols, math.floor((i - 1) / L.cols)
    local x1 = x0 + c * L.cellW
    local x2 = x1 + L.cellW - 2
    local y1 = L.gridY + r * (L.cellH + (L.gap or 0))
    local face, shadow, fg
    if used[sym] then face, shadow, fg = colors.black, colors.black, colors.yellow
    elseif busy then face, shadow, fg = colors.black, colors.black, colors.gray
    else face, shadow, fg = colors.black, colors.black, colors.white end
    if L.mode == "glyph" and GLYPH_BITS[sym] then
      fillRect(m, x1, y1, x2, y1 + L.cellH - 1, colors.black)
      drawGlyphCell(m, x1, y1, L.fw, L.fh, L.S, sym, fg, colors.black)
    elseif L.mode == "name" then
      local nm = symLabel(sym, L.nameLen)
      if L.stacked then
        local nfg = used[sym] and colors.yellow or (busy and colors.gray or colors.lightBlue)
        center(m, y1, ("%02d"):format(sym), fg, colors.black, x1, x2)
        center(m, y1 + 1, nm, nfg, colors.black, x1, x2)
      else
        center(m, y1, ("%02d %s"):format(sym, nm), fg, colors.black, x1, x2)
      end
    else
      center(m, y1 + math.ceil((L.cellH - 1) / 2), ("%02d"):format(sym), fg, colors.black, x1, x2)
    end
    buttons[#buttons + 1] = { x1 = x1, y1 = y1, x2 = (c < L.cols - 1) and (x2 + 1) or x2,
                              y2 = y1 + L.cellH - 1, action = "glyph", sym = sym }
  end

  -- Funktionstasten
  local labels = {
    { T("BTN_DIAL"), STY.green, "dial" },
    { T("BTN_STOP"), STY.red, "stop" },
    { T("BTN_BACK"), STY.orange, "back" },
    { T("BTN_CLEAR"), STY.brown, "clear" },
    { T("BTN_IRIS"), STY.cyan, "iris" },
    { mw >= 30 and T("BTN_BOOKMARKS") or T("BTN_BOOKMARKS_SHORT"), STY.purple, "bookmarks" },
  }
  local top = h - #L.groups * L.bh + 1
  for gi, group in ipairs(L.groups) do
    local y1 = top + (gi - 1) * L.bh
    local y2 = y1 + L.bh - 1
    local bw = math.floor(mw / #group)
    for i, li in ipairs(group) do
      local b = labels[li]
      local x1 = (i - 1) * bw + 1
      local x2 = (i == #group) and mw or (x1 + bw - 1)
      addKey(m, x1, y1, x2, y2, b[1], b[2], b[3])
    end
  end
end

------------------------------------------------------------------ Statusmonitor
local stateShort = {
  idle = T("STATE_SHORT_READY"), dialing = T("STATE_SHORT_DIALING"),
  connected = T("STATE_SHORT_CONNECTED"), closing = T("STATE_SHORT_CLOSING"),
  incoming = T("STATE_SHORT_INCOMING"), unknown = T("STATE_SHORT_UNKNOWN"),
}
local irisTranslation = { open = "IRIS_OPEN", opening = "IRIS_OPENING", closed = "IRIS_CLOSED",
  closing = "IRIS_CLOSING", none = "IRIS_NONE" }
local function irisText(value)
  if value == nil then return "?" end
  local raw = tostring(value)
  local key = irisTranslation[raw:lower()]
  return key and T(key) or raw
end

local function drawStatus()
  local m = mons.status
  if not m then return end
  local w, h = m.getSize()
  local compact = h < 14
  m.setBackgroundColor(colors.black); m.clear()
  local y0 = 1
  if not compact then header(m, T("TITLE_STATUS")); y0 = 3 end
  local info = stateInfo[S.state] or stateInfo.unknown
  local boxH = compact and 2 or 3
  fillRect(m, 1, y0, w, y0 + boxH - 1, info[2])
  local label = compact and stateShort[S.state] or info[1]
  center(m, compact and y0 or (y0 + 1), label, colors.black, info[2])
  if S.wormhole then
    center(m, compact and (y0 + 1) or (y0 + 2), S.wormhole == "outgoing" and T("DIRECTION_OUTGOING") or T("DIRECTION_INCOMING"), colors.black, info[2])
  end

  local y = y0 + boxH + (compact and 0 or 1)
  local function line(lbl, value, color)
    if y > h then return end
    put(m, 2, y, lbl, colors.lightGray, colors.black)
    put(m, 2 + #lbl + 1, y, tostring(value):sub(1, math.max(1, w - #lbl - 2)), color or colors.white, colors.black)
    y = y + 1
  end
  if not compact then
    line(T("LABEL_LOCAL"), S.localAddr)
    line(T("LABEL_ORIGIN"), S.origin)
  end
  local tname = S.target and S.target.name or (S.wormhole == "incoming" and T("STATE_SHORT_INCOMING") or "-")
  line(T("LABEL_TARGET"), tname, colors.yellow)
  line(T("LABEL_TIME"), elapsed())
  line(T("LABEL_CHEVRONS"), S.lockedCount .. "/9")
  if not compact then
    local energy = "?"
    local fill
    if S.energy ~= nil then
      local energyEU = tonumber(S.energy) or 0
      fill = math.max(0, math.min(1, energyEU / MAX_GATE_ENERGY_EU))
      local percent = math.floor(fill * 100 + 0.5)
      energy = cfg.energyInFE == true
        and (percent .. "% " .. num(energyEU * 4) .. " FE")
        or (percent .. "% " .. num(energyEU) .. " EU")
    end
    line(T("LABEL_ENERGY"), energy)
    if fill ~= nil and y <= h then
      local barWidth = math.max(0, w - 2)
      if barWidth > 0 then
        fillRect(m, 2, y, w - 1, y, colors.gray)
        local filledWidth = math.floor(barWidth * fill + 0.5)
        if filledWidth > 0 then fillRect(m, 2, y, 1 + filledWidth, y, colors.lime) end
      end
      y = y + 1
    end
  end
  local iris = irisText(S.iris)
  if S.material and not compact then iris = iris .. " (" .. tostring(S.material) .. ")" end
  line(T("LABEL_IRIS"), iris, (S.iris == "closed" or S.iris == "closing") and colors.red or colors.white)
  if not compact then
    line(T("LABEL_RAW_STATE"), S.raw, colors.gray)
    y = y + 1
    if y < h - 1 then
      put(m, 2, y, T("LABEL_EVENTS"), colors.lightGray, colors.black)
      for i = 1, h - y - 1 do
        local l = logLines[#logLines - i + 1]
        if l then put(m, 2, y + i, l:sub(1, w - 2), colors.gray, colors.black) end
      end
    end
  end
end

------------------------------------------------------------------ Chevron-Monitor (Wahlcomputer wie im Original)
-- Gezeichnet wird als Pixelgrafik ueber die Teletext-Zeichen (2x3 Pixel pro Zeichen).
-- Chevron 1..9 sitzen wie am echten Gate, Nr. 7 ist oben. Rot = verriegelt.
-- Index = Chevron-Slot wie im Bild (1-8 in Wahlreihenfolge, 9 = oben, immer als letztes).
-- Winkel in Grad im Uhrzeigersinn ab oben:
--   1 oben rechts, 2 rechts, 3 unten rechts, 7/8 unten (rechts/links),
--   4 unten links, 5 links, 6 oben links, 9 oben.
local CHEV_ANGLE = { 40, 80, 120, 240, 280, 320, 160, 200, 0 }

-- Welcher Slot wird beim k-ten verriegelten Symbol (von "total") belegt?
-- Das letzte Symbol (Point of Origin) belegt immer Slot 9, egal wie viele es sind.
local function chevSlot(k, total)
  if k >= total or k >= 9 then return 9 end
  return k
end

local DIGITS = {
  ["0"] = { "111", "101", "101", "101", "111" },
  ["1"] = { "010", "110", "010", "010", "111" },
  ["2"] = { "111", "001", "111", "100", "111" },
  ["3"] = { "111", "001", "111", "001", "111" },
  ["4"] = { "101", "101", "111", "001", "001" },
  ["5"] = { "111", "100", "111", "001", "111" },
  ["6"] = { "111", "100", "111", "101", "111" },
  ["7"] = { "111", "001", "001", "001", "001" },
  ["8"] = { "111", "101", "111", "101", "111" },
  ["9"] = { "111", "101", "111", "001", "111" },
}

-- Leuchtende Farben wie auf dem Bildschirm der SGC (nur der Chevron-Monitor)
local chevPaletteSet = false
local function applyChevPalette(m)
  if chevPaletteSet then return end
  chevPaletteSet = true
  pcall(function()
    m.setPaletteColor(colors.blue,      0x145C8C)
    m.setPaletteColor(colors.lightBlue, 0x1AB8FF)
    m.setPaletteColor(colors.cyan,      0xB8FFF2)
    m.setPaletteColor(colors.red,       0xFF2B2B)
    m.setPaletteColor(colors.brown,     0x7F1616)
    m.setPaletteColor(colors.gray,      0x2F4656)
  end)
end

local function resetChevPalette(m)
  if not m then return end
  pcall(function()
    for _, c in ipairs({ colors.blue, colors.lightBlue, colors.cyan, colors.red, colors.brown, colors.gray }) do
      m.setPaletteColor(c, term.nativePaletteColor(c))
    end
  end)
end

local chevGeo = {}
local function chevGeometry(PW, PH, P, ox)
  local key = PW .. "x" .. PH .. ":" .. P .. ":" .. ox
  local g = chevGeo[key]
  if g then return g end

  local R = P / 2
  local cx, cy = ox + (P - 1) / 2, (P - 1) / 2
  local th = math.max(3, math.floor(R * 0.17 + 0.5))        -- Hoehe eines Chevrons
  local tw = math.max(2, math.floor(th * 0.75 + 0.5))        -- halbe Breite
  local bandOut = R - th - 0.5
  local bandIn = bandOut - math.max(2, math.floor(R * 0.22 + 0.5))

  local base = {}
  for i = 1, PW * PH do base[i] = colors.black end
  g = {
    cx = cx, cy = cy, R = R, bandIn = bandIn, base = base,
    chev = {}, chevFace = {}, chevMark = {}, ix = {}, iy = {}, id = {},
  }

  for y = 0, P - 1 do
    for x = ox, ox + P - 1 do
      local dx, dy = x - cx, y - cy
      local d = math.sqrt(dx * dx + dy * dy)
      local idx = y * PW + x + 1
      if d <= bandOut and d >= bandIn then
        base[idx] = (d >= bandOut - 1.2 or d <= bandIn + 1.2) and colors.lightBlue or colors.blue
      elseif d < bandIn - 0.5 then
        g.ix[#g.ix + 1], g.iy[#g.iy + 1], g.id[#g.id + 1] = x, y, d
      end
    end
  end

  for i = 1, 9 do
    local a = math.rad(CHEV_ANGLE[i])
    local rx, ry = math.sin(a), -math.cos(a)
    local tx, ty = math.cos(a), math.sin(a)
    local px, py = cx + rx * (R - 0.5), cy + ry * (R - 0.5)
    local body, face, mark = {}, {}, {}
    local ext = th + tw + 1
    for y = math.floor(py - ext), math.ceil(py + ext) do
      for x = math.floor(px - ext), math.ceil(px + ext) do
        if x >= 0 and x < PW and y >= 0 and y < PH then
          local dx, dy = x - px, y - py
          local v = -(dx * rx + dy * ry)   -- nach innen
          local u = dx * tx + dy * ty      -- seitlich
          if v >= 0 and v <= th then
            local t = v / th
            local bodyHalf = tw * (1 - t) + 0.4
            local faceHalf = tw * 0.62 * (1 - t)
            local idx = y * PW + x + 1
            if math.abs(u) <= bodyHalf + 0.5 then
              body[#body + 1] = idx
              if v >= 1 and v <= th - 1 and math.abs(u) <= faceHalf + 0.35 then
                face[#face + 1] = idx
              end

              local markV = th * 0.55
              if v >= 1 and v <= th - 1 and math.abs(v - markV) <= 0.55 and
                math.abs(u) <= faceHalf + 0.35 then
                mark[#mark + 1] = idx
              end
            end
          end
        end
      end
    end
    g.chev[i], g.chevFace[i], g.chevMark[i] = body, face, mark
  end

  chevGeo[key] = g
  return g
end

local hexOf = {}
local function hx(c)
  local h = hexOf[c]
  if not h then h = colors.toBlit(c); hexOf[c] = h end
  return h
end

local chevPrio = {
  [colors.red] = 5, [colors.cyan] = 4, [colors.lightBlue] = 4,
  [colors.brown] = 3, [colors.gray] = 2, [colors.blue] = 2, [colors.black] = 0,
}

local chevFrame, chevBin = 0, ""

local function drawChevronsRaw()
  local m = mons.chevron
  if not m then return end
  applyChevPalette(m)
  chevFrame = chevFrame + 1

  local cw, ch = m.getSize()
  local PW, PH = cw * 2, ch * 3
  local wide = PW >= PH * 1.5
  local reserve = wide and 0 or ((ch >= 14) and 2 or 1)
  local P = wide and math.min(PH, PW) or math.min(PW, (ch - reserve) * 3)
  local ox = wide and 0 or math.floor((PW - P) / 2)
  local g = chevGeometry(PW, PH, P, ox)

  local syms = S.target and S.target.syms
  local total = syms and #syms or math.max(7, S.lockedCount)
  total = math.min(9, total)
  local lit = S.lockedCount
  if S.wormhole then lit = math.max(lit, total) end

  -- Pixelpuffer
  local cv = {}
  local base = g.base
  for i = 1, PW * PH do cv[i] = base[i] end

  -- Slot-Zustand: Verriegelungsnummer k -> Slot (9 ist immer der letzte)
  local slotColor = {}
  for i = 1, 9 do slotColor[i] = colors.gray end
  -- Bei eingehender Wahl ist die Gesamtzahl unbekannt: dann 1..k der Reihe nach,
  -- erst bei offenem Wurmloch rutscht das letzte Chevron auf Slot 9.
  local totalKnown = (syms ~= nil) or (S.wormhole ~= nil)
  local slotTotal = totalKnown and total or 99
  for k = 1, math.min(lit, 9) do slotColor[chevSlot(k, slotTotal)] = colors.red end
  if S.state == "dialing" and S.blink and lit < total then
    local nxt = chevSlot(lit + 1, slotTotal)
    if slotColor[nxt] ~= colors.red then slotColor[nxt] = colors.lightBlue end
  end
  for i = 1, 9 do
    local c = slotColor[i]
    local shellColor = c == colors.red and colors.brown or (c == colors.lightBlue and colors.blue or colors.gray)
    local faceColor = c == colors.gray and colors.blue or c
    local markColor = c == colors.red and colors.cyan or colors.lightBlue
    for _, idx in ipairs(g.chev[i]) do cv[idx] = shellColor end
    for _, idx in ipairs(g.chevFace[i]) do cv[idx] = faceColor end
    for _, idx in ipairs(g.chevMark[i]) do cv[idx] = markColor end
  end

  if S.wormhole then
    for k = 1, #g.ix do
      local c = ((math.floor(g.id[k] / 1.5) + chevFrame) % 3 == 0) and colors.lightBlue or colors.blue
      cv[g.iy[k] * PW + g.ix[k] + 1] = c
    end
  else
    local sym
    -- Waehren eines laufenden Dial-Schritts bleibt das aktuelle Symbol auch
    -- nach dem Ringstopp sichtbar, bis das Chevron tatsaechlich verriegelt ist.
    if D and D.sent and S.currentSymbol ~= nil then sym = tonumber(S.currentSymbol)
    elseif S.lockedCount > 0 then
      sym = (syms and syms[S.lockedCount]) or tonumber(S.lockedSyms[S.lockedCount])
    end
    if sym then
      local str = ("%02d"):format(sym)
      local sc = math.max(1, math.floor((g.bandIn - 1) / 4.3))
      local x0 = math.floor(g.cx - (7 * sc - 1) / 2 + 0.5)
      local y0 = math.floor(g.cy - (5 * sc - 1) / 2 + 0.5)
      for k = 1, 2 do
        local pat = DIGITS[str:sub(k, k)]
        for r = 1, 5 do
          for c = 1, 3 do
            if pat[r]:sub(c, c) == "1" then
              for dy = 0, sc - 1 do
                for dx = 0, sc - 1 do
                  local x = x0 + (k - 1) * 4 * sc + (c - 1) * sc + dx
                  local y = y0 + (r - 1) * sc + dy
                  if x >= 0 and x < PW and y >= 0 and y < PH then cv[y * PW + x + 1] = colors.cyan end
                end
              end
            end
          end
        end
      end
    end
  end

  -- Pixel -> Teletext-Zeichen
  for row = 1, ch do
    local t, f, b = {}, {}, {}
    local y0 = (row - 1) * 3
    for col = 1, cw do
      local i1 = y0 * PW + (col - 1) * 2 + 1
      local i3 = i1 + PW
      local i5 = i3 + PW
      local bg = cv[i5 + 1]
      local code, fg, fp = 0, bg, -1
      local p = cv[i1];     if p ~= bg then code = code + 1;  if (chevPrio[p] or 1) > fp then fg, fp = p, chevPrio[p] or 1 end end
      p = cv[i1 + 1];       if p ~= bg then code = code + 2;  if (chevPrio[p] or 1) > fp then fg, fp = p, chevPrio[p] or 1 end end
      p = cv[i3];           if p ~= bg then code = code + 4;  if (chevPrio[p] or 1) > fp then fg, fp = p, chevPrio[p] or 1 end end
      p = cv[i3 + 1];       if p ~= bg then code = code + 8;  if (chevPrio[p] or 1) > fp then fg, fp = p, chevPrio[p] or 1 end end
      p = cv[i5];           if p ~= bg then code = code + 16; if (chevPrio[p] or 1) > fp then fg, fp = p, chevPrio[p] or 1 end end
      t[col] = string.char(128 + code)
      f[col] = hx(fg)
      b[col] = hx(bg)
    end
    m.setCursorPos(1, row)
    m.blit(table.concat(t), table.concat(f), table.concat(b))
  end

  -- Textebene
  local function txt(x, y, s, fg, bg)
    if y < 1 or y > ch or x > cw then return end
    s = s:sub(1, cw - x + 1)
    m.setCursorPos(x, y)
    m.setTextColor(fg)
    m.setBackgroundColor(bg or colors.black)
    m.write(s)
  end
  local function ctr(y, s, fg)
    s = s:sub(1, cw)
    txt(math.floor((cw - #s) / 2) + 1, y, s, fg)
  end

  local info = stateInfo[S.state] or stateInfo.unknown
  local tname = S.target and S.target.name or (S.wormhole == "incoming" and T("STATE_SHORT_INCOMING") or "-")

  if not wide then
    ctr(ch, ("%s %d/%d"):format(stateShort[S.state] or "?", math.min(lit, total), total), info[2])
    if reserve == 2 then ctr(ch - 1, tname, colors.yellow) end
  else
    local x0 = math.ceil(P / 2) + 2
    local avail = cw - x0 + 1
    if avail >= 8 then
      local compact = ch < 14
      local top, bottomRows = 4, 3
      if compact then top, bottomRows = 3, 1 end
      txt(x0, 1, T("CHEV_DESTINATION"), colors.lightBlue)
      txt(x0, 2, tname:sub(1, avail), colors.yellow)

      local rows = ch - top - bottomRows + 1
      local slotH = math.max(1, math.min(3, math.floor(rows / total)))
      local bw = math.min(avail - 3, 10)
      local visible = math.min(total, math.floor(rows / slotH))
      for i = 1, visible do
        local y = top + (i - 1) * slotH
        local isLocked = i <= lit
        local bg = isLocked and colors.brown or colors.gray
        if not isLocked and i == lit + 1 and S.state == "dialing" and S.blink then bg = colors.lightBlue end
        local boxRows = (slotH >= 2) and (slotH - 1) or 1
        local mid = math.floor((boxRows - 1) / 2)
        for r = 0, boxRows - 1 do
          local content = (" "):rep(bw)
          local label = "  "
          if r == mid then
            label = tostring(i):sub(1, 1) .. " "
            if isLocked then
              local sv = (syms and syms[i]) or tonumber(S.lockedSyms[i])
              if sv then
                local s = ("%02d"):format(sv)
                local pad = math.floor((bw - #s) / 2)
                content = (" "):rep(pad) .. s .. (" "):rep(bw - pad - #s)
              end
            end
          end
          txt(x0, y + r, label, colors.lightBlue)
          txt(x0 + 2, y + r, content, colors.white, bg)
        end
      end

      txt(x0, ch - (compact and 0 or 2), (T("CHEV_STATUS") .. " " .. info[1]):sub(1, avail), info[2])
      if not compact then
        if chevFrame % 4 == 1 or #chevBin ~= avail then
          local bits = {}
          for i = 1, avail do bits[i] = (math.random() < 0.5) and "0" or "1" end
          chevBin = table.concat(bits)
        end
        txt(x0, ch - 1, chevBin, colors.gray)
        txt(x0, ch, T("CHEV_SYSTEM"), colors.lightBlue)
      end
    end
  end
end

-- Zeichnet nur, wenn sich etwas Sichtbares geaendert hat (spart sehr viel Rechenzeit).
local chevSig = ""
local function drawChevrons()
  local m = mons.chevron
  if not m then return end
  local cw, ch = m.getSize()
  local tNow = now()
  local sig = table.concat({
    cw, ch, S.lockedCount, S.state,
    tostring(S.blink and S.state == "dialing"),
    tostring(S.wormhole), tostring(S.currentSymbol), tostring(D and D.sent),
    S.target and S.target.name or "-", S.target and #S.target.syms or 0,
    fmtValue(S.lockedSyms),
    S.wormhole and math.floor(tNow / 0.25) or 0,  -- Wurmloch-Animation
    math.floor(tNow),                              -- Binaer-Rauschen
  }, "|")
  if sig == chevSig then return end
  chevSig = sig
  local t0 = os.epoch("utc")
  drawChevronsRaw()
  local dt = os.epoch("utc") - t0
  if dt > 50 then dbg("PERF drawChevrons: %d ms (%dx%d Zeichen)", dt, cw, ch) end
end

local lastUi = ""
local function redraw()
  local cw, ch = mons.control.getSize()
  local sg = table.concat({
    cw, ch, S.view, S.bmPage, tostring(S.bmDel), bmSig(), tostring(S.palm ~= nil), math.floor(palmProgress() * 20),
    S.state, S.raw, S.localAddr, S.origin, S.lockedCount, tostring(S.energy), tostring(S.iris),
    tostring(S.material), elapsed(), #logLines, logLines[#logLines] or "",
    S.target and S.target.name or "-", table.concat(S.entry, "-"), tostring(S.entryDone),
    tostring(D ~= nil), tostring(S.incomingDial), tostring(S.wormhole),
  }, "|")
  if sg ~= lastUi then lastUi = sg; drawControl(); drawStatus() end
  drawChevrons()
end

------------------------------------------------------------------ Aktualisierung
local lastSnap = ""
local function refresh()
  local seq0 = S.evSeq
  local raw = safe(gate.getState)
  S.raw = raw ~= nil and fmtValue(raw) or "?"
  S.lockedCount = tonumber(safe(gate.getChevronsLocked)) or 0
  S.lockedSyms = safe(gate.getLockedSymbols) or {}
  if type(S.lockedSyms) ~= "table" then S.lockedSyms = {} end
  -- Langsam veraenderliche Werte nur alle 2 s abfragen (jede Abfrage kostet einen Tick)
  local tSlow = now()
  if not S.slowAt or tSlow - S.slowAt > 2 then
    S.slowAt = tSlow
    S.energy = safe(gate.getEnergy)
    S.iris = safe(gate.getIrisState)
    S.material = safe(gate.getIrisMaterial)
  end
  S.turning = safe(gate.isRingTurning) and true or false
  S.currentSymbol = safe(gate.getCurrentSymbol)
  updateBlink()
  if S.view == "palm" and (isBusy() or now() - S.viewAt > cfg.palmTimeout) then
    log(isBusy() and T("LOG_AUTH_ENDED_BUSY") or T("LOG_AUTH_TIMEOUT"))
    setView("dhd")
  end
  -- Kam waehrend der Abfragen ein Gate-Event, sind die Werte evtl. veraltet:
  -- nicht abgleichen, der naechste Refresh (vom Event ausgeloest) holt frische Werte.
  if S.evSeq ~= seq0 then redraw(); return end

  -- Gate-Zustand als Rueckversicherung zu den Events abgleichen. Damit werden
  -- verlorene Open-/Closed-Events und bereits bestehende Verbindungen erkannt.
  local gateState = classify(S.raw)
  if D and D.finishing and tostring(S.raw):lower():find("reset") then
    -- Nach dem letzten Chevron meldet das Gate beim gescheiterten Aufbau
    -- "resetting" statt zwingend ein stargate_dial_failed-Event zu senden.
    log(T("LOG_RESET"))
    D = nil
    S.target = nil
    S.lockedCount = 0
    S.lockedSyms = {}
  end
  if gateState == "connected" then
    if not S.wormhole and not S.closedEvent and not S.closingRequested then
      S.wormhole = "outgoing"
      S.connectedAt = S.connectedAt or now()
      S.incomingDial = false
    end
  elseif gateState == "idle" then
    S.closedEvent = false
    if S.wormhole or S.closingRequested then
      -- Geschlossen-Event verpasst oder Gate ohne Event geschlossen.
      S.wormhole = nil
      S.connectedAt = nil
      S.incomingDial = false
      S.closingRequested = false
      S.target = nil
      D = nil
      log(T("LOG_GATE_CLOSED"))
    end
    -- Nach dem Schliessen koennen Chevron-Abfragen noch den alten Stand liefern.
    -- Ohne aktive lokale Wahl sind diese Werte kein Hinweis auf eine neue Wahl.
    if not D and not S.turning then
      S.lockedCount = 0
      S.lockedSyms = {}
    end
  end

  stepDial()

  if cfg.debug then
    local nc = safe(gate.getNextChevron)
    local dinfo = D and ("i=%d sent=%s locked=%s tries=%d fin=%s"):format(D.i, tostring(D.sent), tostring(D.locked),
      D.tries or 0, tostring(D.finishing)) or "nil"
    local snap = ("state=%s locked=%d syms=[%s] turning=%s cur=%s next=%s iris=%s wh=%s inc=%s | D: %s"):format(
      S.raw, S.lockedCount, fmtValue(S.lockedSyms), tostring(S.turning), tostring(S.currentSymbol),
      tostring(nc), tostring(S.iris), tostring(S.wormhole), tostring(S.incomingDial), dinfo)
    if snap ~= lastSnap then dbg("POLL %s", snap); lastSnap = snap end
  end

  local state
  if S.wormhole == "outgoing" then state = "connected"
  elseif S.closingRequested then state = "closing"
  elseif S.wormhole == "incoming" or S.incomingDial then state = "incoming"
  elseif D or S.turning or classify(S.raw) == "dialing" then state = "dialing"
  else
    state = classify(S.raw)
    if state == "connected" then state = "idle" end
  end
  if state ~= S.state then
    local stateKey = ({ idle = "STATE_READY", dialing = "STATE_DIALING", connected = "STATE_CONNECTED",
      closing = "STATE_CLOSING", incoming = "STATE_INCOMING", unknown = "STATE_UNKNOWN" })[state] or "STATE_UNKNOWN"
    log(T("LOG_STATUS", T(stateKey)))
    S.state = state
  end
  redraw()
end

local function pressGlyph(sym)
  if isBusy() then log(T("LOG_BUSY_STOP")); return end
  if S.entryDone then S.entry = {}; S.entryDone = false end -- neue Adresse beginnen
  for _, v in ipairs(S.entry) do
    if v == sym then log(T("LOG_DUP_SYMBOL", sym)); return end
  end
  if #S.entry >= MAX_SYMS then log(T("LOG_MAX_SYMBOLS", MAX_SYMS)); return end
  S.entry[#S.entry + 1] = sym
  log(T("LOG_ENTRY_SYMBOL", #S.entry, sym, symName[sym] or ""))
end

local function handleTouch(x, y)
  for _, b in ipairs(buttons) do
    if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then
      local a = b.action
      if a ~= "palm" then dbg("TOUCH %d,%d -> %s", x, y, tostring(a)) end
      if a ~= "bmdel" then S.bmDel = nil end
      if a == "glyph" then pressGlyph(b.sym)
      elseif a == "dial" then requestDial()
      elseif a == "stop" then stopAll()
      elseif a == "back" then
        if isBusy() then log(T("LOG_BUSY_STOP"))
        else S.entry[#S.entry] = nil; S.entryDone = false end
      elseif a == "clear" then
        if isBusy() then log(T("LOG_BUSY_STOP"))
        else S.entry = {}; S.entryDone = false end
      elseif a == "iris" then toggleIris()
      elseif a == "bookmarks" then setView("bookmarks"); S.bmPage = 1
      elseif a == "bmback" then setView("dhd")
      elseif a == "bmsave" then addBookmark()
      elseif a == "bmprev" then S.bmPage = math.max(1, S.bmPage - 1)
      elseif a == "bmnext" then S.bmPage = S.bmPage + 1 -- wird beim Zeichnen begrenzt
      elseif a == "bmload" then loadBookmark(b.idx)
      elseif a == "bmdel" then deleteBookmark(b.idx)
      elseif a == "palm" then palmTouch()
      elseif a == "palmcancel" then setView("dhd"); log(T("LOG_AUTH_CANCELLED")) end
      -- Sofort neu zeichnen (ohne Gate-Abfragen) und den Poller wecken.
      redraw()
      S.wake = true; os.queueEvent("sg_refresh")
      return
    end
  end
end

local function handleGateEvent(ev)
  local e = ev[1]
  if e == "stargate_wormhole_open" then
    -- Event-Argumente: Peripheral, Richtung ("incoming" oder "outgoing").
    local direction = tostring(ev[3] or ev[2] or ""):lower()
    if direction ~= "incoming" and direction ~= "outgoing" then
      -- Defensive Erkennung falls eine Gate-Version nur die Richtung liefert.
      direction = tostring(ev[2] or ""):lower()
    end
    if direction ~= "incoming" and direction ~= "outgoing" then direction = "outgoing" end
    S.wormhole = direction
    S.closedEvent = false
    S.closingRequested = false
    S.connectedAt = now()
    S.incomingDial = false
    D = nil
    if direction == "incoming" then S.target = nil end
    log(T("LOG_WORMHOLE_OPEN", direction == "incoming" and T("DIRECTION_INCOMING") or T("DIRECTION_OUTGOING")))
  elseif e == "stargate_wormhole_closed" then
    S.wormhole = nil; S.connectedAt = nil; S.incomingDial = false
    S.closedEvent = true
    S.closingRequested = false
    S.target = nil; D = nil
    log(T("LOG_WORMHOLE_CLOSED"))
  elseif e == "stargate_incoming" then
    S.incomingDial = true; S.target = nil; D = nil
    log(T("LOG_INCOMING_DIAL"))
  elseif e == "stargate_dial_failed" then
    S.incomingDial = false
    log(T("LOG_DIAL_FAILED", tostring(ev[2])))
    D = nil; S.target = nil
    gcall("abort")
  elseif e == "stargate_chevron_locked" then
    -- Event-Argumente: Peripheral, Chevron-Nummer, Symbolnummer.
    local chevron, symbol = tonumber(ev[3]), tonumber(ev[4])
    log(T("LOG_CHEVRON_LOCKED", tostring(chevron or ev[3]), tostring(symbol or ev[4])))
    -- Verriegelung abgeschlossen -> stepDial() sendet gleich das naechste Symbol
    -- Nur das aktuell erwartete Chevron/Symbol bestaetigt den laufenden Schritt.
    if D and D.sent and
        (chevron == nil or chevron == D.i) and
        (symbol == nil or symbol == D.syms[D.i]) then
      D.locked = true
      dbg("EVENT bestaetigt Symbol %d/%d = %d", D.i, #D.syms, D.syms[D.i])
    end
  elseif e == "stargate_iris" then
    S.slowAt = nil
    log(T("LOG_IRIS", tostring(ev[2])))
  elseif e == "stargate_iris_struck" then
    log(T("LOG_IRIS_HIT", tostring(ev[2])))
  end
end

------------------------------------------------------------------ Hauptschleife
term.clear(); term.setCursorPos(1, 1)
print(T("TERM_RUNNING"))
print(T("TERM_LOCAL_ADDRESS", S.localAddr))

-- Zwei Coroutinen: "main" nimmt nur Events entgegen, "poller" fragt das Gate ab.
-- Wichtig: Waehrend eines Gate-Aufrufs gehen Events verloren, auf die die Coroutine
-- nicht wartet. Der Poller startet seinen Timer deshalb erst NACH dem Refresh, und
-- Touch/Gate-Events werden von einer eigenen Coroutine angenommen.
local function main()
  while true do
    local ev = table.pack(os.pullEvent())
    if cfg.debug and ev[1] ~= "timer" and ev[1] ~= "sg_refresh" and ev[1] ~= "task_complete" then
      local parts = {}
      for i = 2, ev.n do parts[#parts + 1] = tostring(ev[i]) end
      dbg("EVENT %s (%s)", tostring(ev[1]), table.concat(parts, ", "))
    end
    if ev[1] == "monitor_touch" and ev[2] == mons.controlName then
      handleTouch(ev[3], ev[4])
    elseif ev[1]:sub(1, 9) == "stargate_" then
      S.evSeq = S.evSeq + 1
      handleGateEvent(ev)
      redraw()
      S.wake = true; os.queueEvent("sg_refresh")
    elseif ev[1] == "monitor_resize" and ev[2] == mons.controlName then
      redraw() -- Groesse wird in drawControl erkannt, Skala neu gewaehlt
    elseif ev[1] == "peripheral" or ev[1] == "peripheral_detach" then
      log(T("LOG_PERIPHERAL_CHANGE"))
    end
  end
end

local function poller()
  while true do
    S.wake = false
    refresh()
    if not S.wake then
      local t = os.startTimer(cfg.pollInterval)
      while true do
        local ev, p = os.pullEvent()
        if (ev == "timer" and p == t) or ev == "sg_refresh" then break end
      end
      os.cancelTimer(t)
    end
  end
end

-- Eigene Coroutine nur fuer die Chevron-Animation: laeuft weiter, waehrend main()
-- auf langsame Gate-Abfragen wartet. Zeichnet nur bei sichtbarer Aenderung.
local function anim()
  if not mons.chevron then while true do sleep(60) end end
  while true do
    updateBlink()
    drawChevrons()
    sleep(0.1)
  end
end

-- Terminal-Befehle fuer Lesezeichen (Monitor hat keine Tastatur)
local function terminalInput()
  print(T("TERM_BOOKMARK_HELP"))
  while true do
    write("> ")
    local line = read()
    local cmd, rest = tostring(line or ""):match("^%s*(%S+)%s*(.-)%s*$")
    if cmd == "list" then
      for i, b in ipairs(bookmarks) do print(i, b.name, addrLine(b.syms, false)) end
      if #bookmarks == 0 then print(T("TERM_NO_BOOKMARKS")) end
    elseif cmd == "name" then
      local nr, text = rest:match("^(%d+)%s+(.+)$")
      nr = tonumber(nr)
      if nr and bookmarks[nr] then
        bookmarks[nr].name = text:sub(1, 24)
        saveBookmarks(); redraw(); print(T("TERM_OK"))
      else print(T("TERM_NAME_USAGE")) end
    elseif cmd == "del" then
      local nr = tonumber(rest)
      if nr and bookmarks[nr] then
        table.remove(bookmarks, nr); S.bmDel = nil
        saveBookmarks(); redraw(); print(T("TERM_OK"))
      else print(T("TERM_DELETE_USAGE")) end
    elseif cmd then
      print(T("TERM_UNKNOWN_BOOKMARK_COMMAND"))
    end
  end
end

local ok, err = pcall(parallel.waitForAny, main, poller, anim, terminalInput)
dbg("Programmende: %s", ok and "normal" or tostring(err))
if dbgFile then dbgFile.close() end
for _, role in ipairs({ "control", "status", "chevron" }) do
  local m = mons[role]
  if m then
    if role == "chevron" then resetChevPalette(m) end
    if role == "control" then resetCtrlPalette(m) end
    m.setBackgroundColor(colors.black); m.clear()
  end
end
term.setCursorPos(1, 3)
if not ok and err ~= "Terminated" then printError(err) else print(T("TERM_STOPPED")) end
