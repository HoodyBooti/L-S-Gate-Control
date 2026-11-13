local BASE_URL = "https://raw.githubusercontent.com/HoodyBooti/L-S-Gate-Control/refs/heads/main/"
local PROGRAM_FILES = { "sg_language.lua", "sgcontrol.lua" }
local CONFIG_FILE = "sg_config.lua"

local function stop(message)
  printError(message)
end

if not http or not http.get then
  stop("HTTP is unavailable. Enable HTTP in the CC:Tweaked server configuration and try again.")
  return
end

local config = {}
if fs.exists(CONFIG_FILE) then
  local file = fs.open(CONFIG_FILE, "r")
  if not file then
    stop("Could not read " .. CONFIG_FILE .. ".")
    return
  end
  local contents = file.readAll()
  file.close()
  local saved = textutils.unserialise(contents)
  if type(saved) ~= "table" then
    stop(CONFIG_FILE .. " is not valid serialized configuration. Fix or remove it before installing.")
    return
  end
  config = saved
end

local function downloadTo(path)
  local response, err = http.get(BASE_URL .. path)
  if not response then
    return false, "Could not download " .. path .. ": " .. tostring(err)
  end

  if response.getResponseCode then
    local code = response.getResponseCode()
    if code < 200 or code >= 300 then
      response.close()
      return false, "Download failed for " .. path .. " (HTTP " .. code .. ")."
    end
  end

  local contents = response.readAll()
  response.close()
  if type(contents) ~= "string" or #contents == 0 then
    return false, "Downloaded file is empty: " .. path
  end

  local file, writeError = fs.open(path .. ".install-tmp", "w")
  if not file then
    return false, "Could not write temporary file for " .. path .. ": " .. tostring(writeError)
  end
  file.write(contents)
  file.close()
  return true
end

local function getPeripherals(kind)
  local names = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, kind) then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

local function choose(prompt, options, default, allowAutomatic)
  local minimum = allowAutomatic and 0 or 1
  while true do
    write(prompt .. " [" .. default .. "]: ")
    local value = read()
    if value == "" then value = tostring(default) end
    local number = tonumber(value)
    if number and number >= minimum and number <= #options and number == math.floor(number) then
      return number
    end
    print("Enter a number from " .. minimum .. " to " .. #options .. ".")
  end
end

local function showOptions(names)
  for i, name in ipairs(names) do
    print(i .. " = " .. name)
  end
end

print("Lantea Stargate Control installer")
print("Downloading the latest program files...")

for _, path in ipairs(PROGRAM_FILES) do
  local ok, err = downloadTo(path)
  if not ok then
    for _, cleanupPath in ipairs(PROGRAM_FILES) do
      local tempPath = cleanupPath .. ".install-tmp"
      if fs.exists(tempPath) then fs.delete(tempPath) end
    end
    stop(err)
    return
  end
end

local languageDefault = config.language == "EN" and 1 or 2
print("")
print("Choose interface language: 1 = English, 2 = Deutsch")
config.language = choose("Language", { "EN", "DE" }, languageDefault, false) == 1 and "EN" or "DE"

local gates = getPeripherals("stargate")
print("")
print("Stargate peripherals (0 = automatic detection):")
showOptions(gates)
local gateChoice = choose("Stargate", gates, 0, true)
config.gate = gateChoice == 0 and "" or gates[gateChoice]

local monitors = getPeripherals("monitor")
print("")
print("Monitor peripherals (0 = automatic assignment):")
showOptions(monitors)
local usedMonitors = {}
for _, role in ipairs({ "control", "status", "chevron" }) do
  while true do
    local choice = choose(role .. " monitor", monitors, 0, true)
    local name = choice == 0 and "" or monitors[choice]
    if name == "" or not usedMonitors[name] then
      config[role .. "Monitor"] = name
      if name ~= "" then usedMonitors[name] = true end
      break
    end
    print("That monitor is already assigned to another role.")
  end
end

local configTemp = CONFIG_FILE .. ".install-tmp"
local configFile, configError = fs.open(configTemp, "w")
if not configFile then
  for _, path in ipairs(PROGRAM_FILES) do
    local tempPath = path .. ".install-tmp"
    if fs.exists(tempPath) then fs.delete(tempPath) end
  end
  stop("Could not save configuration: " .. tostring(configError))
  return
end
configFile.write(textutils.serialise(config))
configFile.close()

for _, path in ipairs(PROGRAM_FILES) do
  if fs.exists(path) then fs.delete(path) end
  fs.move(path .. ".install-tmp", path)
end
if fs.exists(CONFIG_FILE) then fs.delete(CONFIG_FILE) end
fs.move(configTemp, CONFIG_FILE)

print("")
print("Installation and quick configuration complete.")
print("Start the program with: sgcontrol")
