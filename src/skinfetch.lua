-- Optional download of Mojang's default skins.
--
-- These are Mojang's assets, not ours. They are fetched from Mojang's own CDN
-- when the user asks for them -- never bundled with this extension, never
-- committed to the repo. Each user therefore obtains them from Mojang
-- directly, the same way the game does, and nothing here redistributes them.
--
-- Aseprite asks the user before a script runs a command, and again before it
-- reads or writes a file. So the download is one curl command whose output is
-- read straight from the pipe, the images are decoded here rather than loaded
-- from disk, and the result is kept in the extension's own preferences. That
-- is one permission question, once, and no files at all.

local png = require("src.png")

local M = {}

local SKIN_SIZE  <const> = 64
local CONFIG     <const> = "skins.curl"
local PREF_KEY   <const> = "skin_"

-- The skins this module knows about, in the order skins.curl downloads them.
M.SOURCES = {
  { id = "steve", slim = false },
  { id = "alex",  slim = true },
}

-- Directory this file was loaded from, which is where skins.curl sits.
local HERE <const> = (function()
  local src = debug.getinfo(1, "S").source or ""
  if src:sub(1, 1) == "@" then src = src:sub(2) end
  return app.fs.filePath(src)
end)()

-- Where downloaded skins are remembered between sessions: the extension's
-- preferences table, which Aseprite saves itself. Without one (the module is
-- being used outside the extension) skins last for the session only.
local store
local memo = {}

--- Give the module the extension's preferences table to remember skins in.
function M.setStore(prefs)
  store = prefs
end

local function toHex(s)
  return (s:gsub(".", function(c) return ("%02x"):format(c:byte()) end))
end

local function fromHex(h)
  return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end))
end

--- PNG bytes to a skin Image, or nil plus why not.
local function toImage(data)
  local w, h, rgba = png.decode(data)
  if not w then return nil, h end
  if w ~= SKIN_SIZE or h ~= SKIN_SIZE then return nil, "not a 64x64 skin" end
  local img = Image(w, h, ColorMode.RGB)
  img.bytes = rgba
  return img
end

--- The PNG bytes remembered for a skin, if any.
local function stored(id)
  local hex
  pcall(function() hex = store and store[PREF_KEY .. id] end)
  if type(hex) ~= "string" or hex == "" then return nil end
  return fromHex(hex)
end

function M.isCached(id)
  return memo[id] ~= nil or stored(id) ~= nil
end

--- A fresh copy of the skin as an Image, or nil when it has not been
-- downloaded yet.
function M.cached(id)
  local data = memo[id] or stored(id)
  if not data then return nil end
  local img = toImage(data)
  if not img then
    -- Whatever was remembered is not a skin. Forget it so the next attempt
    -- downloads again.
    memo[id] = nil
    pcall(function() if store then store[PREF_KEY .. id] = nil end end)
    return nil
  end
  memo[id] = data
  return img
end

local function quote(s) return '"' .. tostring(s):gsub('"', '\\"') .. '"' end

--- Path of `path` relative to `base`, or nil when it is not inside it.
local function relativeTo(path, base)
  local sep = app.fs.pathSeparator
  if base:sub(-1) ~= sep then base = base .. sep end
  if path:sub(1, #base) ~= base then return nil end
  return path:sub(#base + 1)
end

local function isWindows() return app.fs.pathSeparator == "\\" end

--- The command that fetches the skins.
--
-- Aseprite shows the user this exact text when it asks for permission, in a
-- dialog as wide as the text. With the download URLs in it the dialog was
-- wider than a laptop screen and its buttons were out of reach. So the URLs
-- live in skins.curl, and the command runs from the Aseprite config folder so
-- the path to that file can be short and relative.
local function command()
  local root = app.fs.userConfigPath
  local config = app.fs.joinPath(HERE, CONFIG)
  local cd = isWindows() and "cd /d " or "cd "
  return cd .. quote(root) .. " && curl -K " .. quote(relativeTo(config, root) or config)
end

--- The command text, for checking how long the permission dialog will be.
function M.commandText() return command() end

--- Split a byte stream holding several PNGs back to back.
local function splitPngs(data)
  local parts, sig = {}, png.SIGNATURE
  local at = data:find(sig, 1, true)
  while at do
    local nextAt = data:find(sig, at + #sig, true)
    parts[#parts + 1] = data:sub(at, nextAt and nextAt - 1 or #data)
    at = nextAt
  end
  return parts
end

--- Fetch every default skin. Returns true, or false plus a message when none
-- of them arrived.
--
-- Aseprite's Lua has no HTTP client, so this shells out to curl, which ships
-- with macOS, modern Windows and virtually every Linux.
function M.downloadAll()
  -- Windows opens pipes in text mode unless told otherwise, which would
  -- mangle the image bytes.
  local pipe = io.popen(command(), isWindows() and "rb" or "r")
  local out = pipe and pipe:read("a") or ""
  if pipe then pipe:close() end

  local parts = splitPngs(out)
  local got = 0
  for i, src in ipairs(M.SOURCES) do
    local data = parts[i]
    if data and toImage(data) then
      memo[src.id] = data
      pcall(function() if store then store[PREF_KEY .. src.id] = toHex(data) end end)
      got = got + 1
    end
  end
  if got == 0 then
    if out == "" then
      return false, "Nothing was received. Check the internet connection."
    end
    return false, "What was received was not a skin."
  end
  return true
end

--- Forget the downloaded skins. Returns how many were forgotten.
function M.clearCache()
  local n = 0
  for _, src in ipairs(M.SOURCES) do
    if M.isCached(src.id) then n = n + 1 end
    memo[src.id] = nil
    pcall(function() if store then store[PREF_KEY .. src.id] = nil end end)
  end
  return n
end

return M
