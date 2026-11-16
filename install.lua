local REPOSITORY_URL = "https://github.com/HoodyBooti/L-S-Gate-Control"
local RELEASES_URL = REPOSITORY_URL .. "/releases"
local RAW_URL = "https://raw.githubusercontent.com/HoodyBooti/L-S-Gate-Control/refs/heads/"
local PROGRAM_FILES = { "sg_language.lua", "sgcontrol.lua" }
local CONFIG_FILE = "sg_config.lua"
local BASE_URL

local function stop(message)
  printError(message)
end

local function validRef(ref)
  if type(ref) ~= "string" or ref == "" or ref:sub(1, 1) == "/" or ref:sub(-1) == "/" or ref:find("//", 1, true) then
    return false
  end
  for segment in ref:gmatch("[^/]+") do
    if segment == "." or segment == ".." or not segment:match("^[%w_%-][%w%._%-]*$") then
      return false
    end
  end
  return true
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

local function chooseMonitor(role, used)
  while true do
    write(role .. " monitor number (Enter = automatic): ")
    local value = read()
    if value == "" or value:lower() == "auto" then
      return ""
    end

    if value:match("^%d+$") then
      local name = "monitor_" .. tonumber(value)
      if not used[name] then
        used[name] = true
        return name
      end
      print("That monitor is already assigned to another role.")
    else
      print("Enter a non-negative monitor number, or press Enter for automatic discovery.")
    end
  end
end

local function readRef(prompt, default)
  while true do
    write(prompt .. " [" .. default .. "]: ")
    local ref = read()
    if ref == "" then ref = default end
    if validRef(ref) then return ref end
    print("Enter a valid release tag or branch name.")
  end
end

print("Lantea Stargate Control installer")
print("")
print("Choose program source: 1 = Latest release, 2 = Release tag, 3 = Development branch")
local sourceChoice = choose("Source", { "latest release", "release tag", "branch" }, 1, false)
local sourceDescription
if sourceChoice == 1 then
  BASE_URL = RELEASES_URL .. "/latest/download/"
  sourceDescription = "latest release"
elseif sourceChoice == 2 then
  write("Release tag (Enter = latest release): ")
  local tag = read()
  if tag == "" then
    BASE_URL = RELEASES_URL .. "/latest/download/"
    sourceDescription = "latest release"
  elseif validRef(tag) then
    BASE_URL = RELEASES_URL .. "/download/" .. tag .. "/"
    sourceDescription = "release " .. tag
  else
    stop("Invalid release tag.")
    return
  end
else
  local branch = readRef("Branch name", "main")
  BASE_URL = RAW_URL .. branch .. "/"
  sourceDescription = "branch " .. branch
end

print("")
print("Downloading program files from " .. sourceDescription .. "...")

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

local energyUnitDefault = config.energyInFE == true and 2 or 1
print("")
print("Choose energy unit: 1 = EU, 2 = FE (1 EU = 4 FE)")
config.energyInFE = choose("Energy unit", { "EU", "FE" }, energyUnitDefault, false) == 2

local gates = getPeripherals("stargate")
print("")
print("Stargate peripherals (0 = automatic detection):")
showOptions(gates)
local gateChoice = choose("Stargate", gates, 0, true)
config.gate = gateChoice == 0 and "" or gates[gateChoice]

print("")
print("For each monitor role, enter its number (for example 10 for monitor_10),")
print("or press Enter for automatic discovery.")
local usedMonitors = {}
for _, role in ipairs({ "control", "status", "chevron" }) do
  config[role .. "Monitor"] = chooseMonitor(role, usedMonitors)
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
