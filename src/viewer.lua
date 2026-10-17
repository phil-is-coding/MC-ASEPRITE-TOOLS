-- The viewer dialog: an orbitable 3D preview that tracks the sprite live.
--
-- Built to stay open for a whole editing session: it remembers how you left
-- it, can be pinned to one skin while you work in other tabs, and never asks
-- for attention it does not need.

local model  = require("src.model")
local raster = require("src.raster")
local tmpl   = require("src.templates")

local M = {}

-- Starting panel size in REAL screen pixels. Aseprite multiplies every dialog
-- dimension by its screen scale, so asking for 300x400 widget units on a 2x
-- display produces a 600x800 panel that swallows the screen. Divide it back
-- out. The canvas can be resized freely afterward; see ensureTargets for why
-- that never distorts the model.
local PANEL_W_PX  <const> = 300
local PANEL_H_PX  <const> = 400
local MIN_PANEL_W <const> = 120
local MIN_PANEL_H <const> = 160

-- Fraction of the panel height the model occupies at zoom 1. Resolved once at
-- open and then held fixed, so resizing the window reveals more space around
-- the model rather than resizing it.
local MODEL_FILL  <const> = 0.78

local SKIN_SIZE   <const> = 64
local MIN_ZOOM    <const> = 0.35
local MAX_ZOOM    <const> = 4.0
local ORBIT_SPEED <const> = 0.012   -- radians per pixel dragged
local PITCH_LIMIT <const> = math.pi / 2 - 0.01

-- Aseprite's sprite 'change' event fires once per undoable transaction, i.e.
-- when a brush stroke finishes -- not while it is being drawn. Compositing the
-- sprite and comparing bytes costs ~0.005 ms, so a light poll on top of the
-- event gives a preview that keeps up mid-stroke for no meaningful cost.
local POLL_SECONDS   <const> = 1 / 15
local TURNTABLE_STEP <const> = (2 * math.pi) / (15 * 12)   -- one turn per 12s

local DEFAULT_VIEW <const> = {
  yaw = math.rad(28), pitch = math.rad(10), zoom = 1.0, panX = 0, panY = 0,
}

-- Preset yaw angles, bound to number keys. Pitch is leveled so a preset is a
-- true orthographic elevation, which is what you want for checking a face.
local PRESETS <const> = {
  ["1"] = { yaw =   0, pitch = 0 },   -- front
  ["2"] = { yaw =  90, pitch = 0 },   -- the player's right
  ["3"] = { yaw = 180, pitch = 0 },   -- back
  ["4"] = { yaw = 270, pitch = 0 },   -- the player's left
  ["5"] = { yaw =  28, pitch = 10 },  -- default three-quarter
}

-- Supersampling. 2x is where the edges stop looking jagged; 3x cost twice as
-- much again for a difference nobody could see.
local SSAA <const> = {
  { name = "Off", factor = 1 },
  { name = "On",  factor = 2 },
}

local PARTS <const> = {
  { key = "head",     text = "Head"  },
  { key = "body",     text = "Body"  },
  { key = "rightArm", text = "R arm" },
  { key = "leftArm",  text = "L arm" },
  { key = "rightLeg", text = "R leg" },
  { key = "leftLeg",  text = "L leg" },
}

-- What Shift+1..6 type on a US keyboard. Matching the character as well as
-- the key code means the part toggles do not depend on Aseprite reporting the
-- Shift modifier for the press.
local SHIFT_DIGITS <const> = {
  ["!"] = 1, ["@"] = 2, ["#"] = 3, ["$"] = 4, ["%"] = 5, ["^"] = 6,
}

-- The cheat sheet drawn over the view by the "?" button. Every key listed here
-- is one Aseprite does not claim first for a menu command of its own.
local HELP <const> = {
  { "Drag",       "orbit" },
  { "Shift-drag", "pan" },
  { "Wheel, + -", "zoom" },
  { "Arrows",     "orbit" },
  { "1 - 5",      "front, right, back, left, 3/4" },
  { "R",          "reset view" },
  { "B",          "background" },
  { "T",          "turntable" },
  { "I / O",      "inner / outer layer" },
  { "Shift 1 - 6", "head, body, arms, legs" },
  { "H or ?",     "hide this" },
}

local LAYERS <const> = {
  { key = "base",    text = "Inner" },
  { key = "overlay", text = "Outer" },
}

local MODEL_MODES <const> = { "Auto", "Classic", "Slim" }

local BACKGROUNDS <const> = {
  { name = "Sky",     sky = true },
  { name = "Checker", checker = true },
  { name = "Custom",  custom = true },
}
local DEFAULT_CUSTOM_BG <const> = { 24, 24, 28 }

--- Aseprite's combined widget-to-pixel multiplier.
local function uiScale()
  local ok, s = pcall(function()
    local g = app.preferences.general
    return (g.screen_scale or 1) * (g.ui_scale or 1)
  end)
  if not ok or type(s) ~= "number" or s < 1 then return 1 end
  return math.floor(s)
end

--- Clamp and wrap an orbit so dragging never flips the model upside down.
function M.orbit(view, dx, dy)
  view.yaw = (view.yaw + dx * ORBIT_SPEED) % (2 * math.pi)
  view.pitch = math.max(-PITCH_LIMIT, math.min(PITCH_LIMIT, view.pitch + dy * ORBIT_SPEED))
  return view
end

function M.zoom(view, steps)
  view.zoom = math.max(MIN_ZOOM, math.min(MAX_ZOOM, view.zoom * (1.0 - steps * 0.12)))
  return view
end

--- Fresh visibility table: every part, both layers, on.
function M.newVisibility()
  local vis = {}
  for _, p in ipairs(PARTS) do
    vis[p.key] = {}
    for _, l in ipairs(LAYERS) do vis[p.key][l.key] = true end
  end
  return vis
end

--- Faces that survive the current visibility mask.
function M.filterFaces(faces, vis)
  local out = {}
  for _, f in ipairs(faces) do
    local part = vis[f.part]
    if part and part[f.layer] then out[#out + 1] = f end
  end
  return out
end

-- ------------------------------------------------------------- settings --

-- Preferences round-trip through Aseprite's own storage, so keep the shape
-- flat and boring: scalars plus one bit-string. Anything unrecognized or out
-- of range falls back to the default rather than breaking the viewer.

function M.encodeVis(vis)
  local out = {}
  for _, p in ipairs(PARTS) do
    for _, l in ipairs(LAYERS) do
      out[#out + 1] = (vis[p.key] and vis[p.key][l.key]) and "1" or "0"
    end
  end
  return table.concat(out)
end

function M.decodeVis(str)
  local vis = M.newVisibility()
  if type(str) ~= "string" or #str ~= #PARTS * #LAYERS then return vis end
  local i = 1
  for _, p in ipairs(PARTS) do
    for _, l in ipairs(LAYERS) do
      vis[p.key][l.key] = str:sub(i, i) == "1"
      i = i + 1
    end
  end
  return vis
end

function M.captureSettings(state, view)
  return {
    bg = state.bgIndex, ssaa = state.ssaa,
    modelMode = state.modelMode, vis = M.encodeVis(state.vis),
    yaw = view.yaw, pitch = view.pitch, zoom = view.zoom,
    turntable = state.turntable and 1 or 0,
    winX = state.win and state.win.x or nil, winY = state.win and state.win.y or nil,
    winW = state.win and state.win.w or nil, winH = state.win and state.win.h or nil,
    stats = state.stats and 1 or 0,
    bgR = state.bgCustom[1], bgG = state.bgCustom[2], bgB = state.bgCustom[3],
  }
end

function M.applySettings(s, state, view)
  if type(s) ~= "table" then return end
  local function num(v, lo, hi, dflt)
    v = tonumber(v)
    if not v or v ~= v or v < lo or v > hi then return dflt end
    return v
  end
  state.bgIndex = math.floor(num(s.bg,     1, #BACKGROUNDS, state.bgIndex))
  state.ssaa    = math.floor(num(s.ssaa,   1, #SSAA,        state.ssaa))
  for _, m in ipairs(MODEL_MODES) do
    if s.modelMode == m then state.modelMode = m end
  end
  if s.vis ~= nil then state.vis = M.decodeVis(s.vis) end
  view.yaw   = num(s.yaw,   -1e4, 1e4, view.yaw) % (2 * math.pi)
  view.pitch = math.max(-PITCH_LIMIT, math.min(PITCH_LIMIT, num(s.pitch, -1e4, 1e4, view.pitch)))
  view.zoom  = num(s.zoom, MIN_ZOOM, MAX_ZOOM, view.zoom)
  state.turntable = tonumber(s.turntable) == 1
  -- Where the window was left. Pin is deliberately not restored: a viewer
  -- that reopens already pinned has no skin it was pinned to.
  local wx, wy = num(s.winX, -1e5, 1e5, nil), num(s.winY, -1e5, 1e5, nil)
  local ww, wh = num(s.winW, 40, 1e5, nil), num(s.winH, 40, 1e5, nil)
  if wx and wy and ww and wh then
    state.win = { x = math.floor(wx), y = math.floor(wy), w = math.floor(ww), h = math.floor(wh) }
  end
  state.stats     = tonumber(s.stats) == 1
  state.bgCustom  = {
    math.floor(num(s.bgR, 0, 255, DEFAULT_CUSTOM_BG[1])),
    math.floor(num(s.bgG, 0, 255, DEFAULT_CUSTOM_BG[2])),
    math.floor(num(s.bgB, 0, 255, DEFAULT_CUSTOM_BG[3])),
  }
end

--- Checkerboard backdrop, one packed RGBA string per pixel.
local function checkerBytes(w, h, cell)
  local a = string.char(60, 60, 68, 255)
  local b = string.char(48, 48, 55, 255)
  local out = {}
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      out[y * w + x + 1] = (((x // cell) + (y // cell)) % 2 == 0) and a or b
    end
  end
  return out
end

-- Minecraft has no sky texture to borrow: its daytime sky is a flat color
-- that fades into fog at the horizon. These are the plains-biome values.
local SKY_TOP     <const> = { 120, 167, 255 }
local SKY_HORIZON <const> = { 192, 216, 255 }

--- Vertical sky gradient in the same per-pixel form as the checkerboard.
-- The color steps once per OUTPUT row (`ss` supersampled rows), so every
-- supersample block is uniform and anti-aliasing skips the whole backdrop.
local function skyBytes(w, h, ss)
  local out = {}
  local rows = math.max(1, h // ss - 1)
  for y = 0, h - 1 do
    local t = math.min(1, (y // ss) / rows)
    local px = string.char(
      (SKY_TOP[1] + (SKY_HORIZON[1] - SKY_TOP[1]) * t + 0.5) // 1,
      (SKY_TOP[2] + (SKY_HORIZON[2] - SKY_TOP[2]) * t + 0.5) // 1,
      (SKY_TOP[3] + (SKY_HORIZON[3] - SKY_TOP[3]) * t + 0.5) // 1, 255)
    local row = y * w
    for x = 1, w do out[row + x] = px end
  end
  return out
end

local function checkId(partKey, layerKey) return "vis_" .. partKey .. "_" .. layerKey end

--- Short display name for a sprite, for the "tracking" readout.
local function spriteLabel(spr)
  if not spr then return "no sprite" end
  local ok, name = pcall(function()
    local fn = spr.filename
    if fn and fn ~= "" then return app.fs.fileName(fn) end
    return nil
  end)
  if ok and name and name ~= "" then return name end
  return "Untitled"
end

--- Why a sprite of this size cannot be a skin, or nil when it can.
function M.sizeError(w, h)
  if w == SKIN_SIZE and h == SKIN_SIZE then return nil end
  return ("Skin must be %dx%d (this one is %dx%d)"):format(SKIN_SIZE, SKIN_SIZE, w, h)
end

-- The open viewer, if there is one. A second window would mean a second
-- timer and a second set of listeners all rendering the same skin, so asking
-- for the viewer while it is open re-uses the one that exists.
local current

--- Close the viewer if it is open. Called when the extension is disabled,
-- updated or removed, so no timer or listener outlives the code it runs.
function M.close()
  if current then pcall(function() current.dlg:close() end) end
  current = nil
end

function M.show(plugin)
  if current then
    current.retarget()
    return current.dlg
  end

  local scale = uiScale()
  local CANVAS_W = math.max(MIN_PANEL_W, PANEL_W_PX // scale)
  local CANVAS_H = math.max(MIN_PANEL_H, PANEL_H_PX // scale)
  local MODEL_PX = CANVAS_H * MODEL_FILL

  local view = {}
  for k, v in pairs(DEFAULT_VIEW) do view[k] = v end

  local state = {
    sprite    = nil,
    tex       = nil,
    faces     = model.build(false),
    slim      = false,
    modelMode = "Auto",
    vis       = M.newVisibility(),
    visible   = nil,
    bgIndex   = 1,
    bgCustom  = { DEFAULT_CUSTOM_BG[1], DEFAULT_CUSTOM_BG[2], DEFAULT_CUSTOM_BG[3] },
    ssaa      = 1,
    turntable = false,
    pinned    = false,
    stats     = false,
    help      = false,
    lastBytes = nil,
    error     = nil,
    painted   = false,
    dragging  = false,
    panning   = false,
    lastX = 0, lastY = 0,
  }

  -- Restore the previous session. Never let bad stored data stop the viewer.
  local prefs
  pcall(function() prefs = plugin and plugin.preferences end)
  if prefs then pcall(function() M.applySettings(prefs, state, view) end) end

  local dlg

  local function saveSettings()
    if not prefs then return end
    pcall(function()
      if dlg then
        local b = dlg.bounds
        state.win = { x = b.x, y = b.y, w = b.width, h = b.height }
      end
    end)
    pcall(function()
      for k, v in pairs(M.captureSettings(state, view)) do prefs[k] = v end
    end)
  end

  local rend, buffer, rw, rh, rss
  -- Patterned backdrops are per-pixel tables tied to the buffer size, so they
  -- are built on first use and dropped whenever the buffer changes.
  local checker, sky

  -- Timings for the stats overlay. os.clock is CPU time, which is the honest
  -- measure of what the viewer costs Aseprite; frames are counted per whole
  -- wall-clock second because CPU time stands still while idle.
  local helpRect
  local perf = { render = 0, blit = 0, poll = 0, fps = 0, frames = 0, sec = os.time() }

  --- Size the render buffer to the live canvas, one buffer pixel per canvas
  -- pixel, so a resized window can never squash or stretch the model.
  local function ensureTargets(cw, ch)
    local ss = SSAA[state.ssaa].factor
    local nw, nh = math.max(1, cw), math.max(1, ch)
    if rend and nw == rw and nh == rh and ss == rss then return end
    rw, rh, rss = nw, nh, ss
    rend = raster.renderer(rw * ss, rh * ss)
    buffer = Image(rw, rh, ColorMode.RGB)
    checker, sky = nil, nil
  end
  ensureTargets(CANVAS_W, CANVAS_H)

  local spriteListener, siteListener, timer
  local refresh
  local rebuildVisible
  local syncRadios

  --- dlg:modify that leaves the window where the user put it. Changing a
  -- widget makes Aseprite lay the dialog out again and snap the window back to
  -- its preferred size and place; painting on the skin triggers that through
  -- the status labels, which would undo any resize mid-stroke.
  local function modify(args)
    local ok, before = pcall(function() return dlg.bounds end)
    dlg:modify(args)
    if not ok or not before then return end
    pcall(function()
      local after = dlg.bounds
      if after.x ~= before.x or after.y ~= before.y
         or after.width ~= before.width or after.height ~= before.height then
        dlg.bounds = before
      end
    end)
  end

  --- Hand keyboard focus back to the 3D view. Aseprite only delivers key
  -- presses to the focused widget, so without this the hotkeys go dead after
  -- any click on a radio, checkbox or button until the view is clicked again.
  local function focusView()
    if not dlg then return end
    pcall(function() dlg:modify{ id = "view", focus = true } end)
  end

  ---------------------------------------------------------------- sprite --

  local scratch

  local function compose()
    local spr = state.sprite
    if not spr then return nil, "Open a 64x64 skin, or use New skin" end
    local ok, w, h = pcall(function() return spr.width, spr.height end)
    if not ok then return nil, "Sprite closed" end
    local sizeErr = M.sizeError(w, h)
    if sizeErr then return nil, sizeErr end
    if not scratch or scratch.width ~= w or scratch.height ~= h then
      scratch = Image(w, h, ColorMode.RGB)
    end
    local drawn = pcall(function()
      scratch:drawSprite(spr, app.frame and app.frame.frameNumber or 1)
    end)
    if not drawn then return nil, "Sprite closed" end
    return scratch
  end

  local function adopt(img)
    local slim
    if state.modelMode == "Auto" then
      slim = model.detectSlim(img)
    else
      slim = state.modelMode == "Slim"
    end
    if slim ~= state.slim or not state.visible then
      state.slim = slim
      state.faces = model.build(slim)
      rebuildVisible()
    end
    state.tex = raster.texture(img)
    state.error = nil
  end

  local function refreshTexture()
    local img, err = compose()
    if not img then
      state.tex, state.lastBytes, state.error = nil, nil, err
      return nil, err
    end
    state.lastBytes = img.bytes
    adopt(img)
    return state.tex
  end

  --- Cheap tick. The first one always repaints -- that is the backstop that
  -- puts the model on screen without the user touching anything -- and it must
  -- fire even with no sprite, so the placeholder message is drawn too.
  local function poll()
    if not dlg then return end
    local first = not state.painted
    state.painted = true

    local img = compose()
    if not img then
      if first then dlg:repaint() end
      return
    end
    local bytes = img.bytes
    if bytes == state.lastBytes and not first then return end
    state.lastBytes = bytes
    adopt(img)
    dlg:repaint()
  end

  local function detach()
    if state.sprite and spriteListener then
      pcall(function() state.sprite.events:off(spriteListener) end)
    end
    spriteListener = nil
  end

  --- Point the viewer at a sprite, replacing any previous subscription.
  -- Registering exactly once per sprite is what keeps repeated opens from
  -- stacking listeners and re-rendering N times per stroke.
  local function attach(sprite)
    if sprite == state.sprite then return end
    detach()
    state.sprite = sprite
    state.tex, state.lastBytes = nil, nil
    if sprite then
      spriteListener = sprite.events:on('change', function()
        state.tex = nil
        refresh()
      end)
    end
  end

  ----------------------------------------------------------------- drawing --

  rebuildVisible = function()
    state.visible = M.filterFaces(state.faces, state.vis)
  end

  local function backgroundBytes()
    local def = BACKGROUNDS[state.bgIndex]
    if def.checker then
      checker = checker or checkerBytes(rw * rss, rh * rss, 8 * rss)
      return checker
    elseif def.sky then
      sky = sky or skyBytes(rw * rss, rh * rss, rss)
      return sky
    end
    local c = state.bgCustom
    return string.char(c[1], c[2], c[3], 255)
  end

  local function renderFrame()
    local tex, err = state.tex, state.error
    if not tex then tex, err = refreshTexture() end
    if not tex then return nil, err end

    -- Buffer pixels per model unit. Derived from MODEL_PX, not from the
    -- canvas, so the model is the same size whatever the window size.
    local unit = (MODEL_PX / model.HEIGHT) * view.zoom * rss
    local cam = {
      yaw = view.yaw, pitch = view.pitch,
      scale = unit,
      originX = rw * rss * 0.5 + view.panX * rss,
      originY = rh * rss * 0.5 + view.panY * rss,
      -- Orbit about the middle of the body, not the soles of the feet.
      pivotY = model.HEIGHT * 0.5,
    }
    if not state.visible then rebuildVisible() end
    buffer.bytes = rend:draw(state.visible, tex, cam, backgroundBytes(),
                             rss > 1 and rss or nil)
    return buffer
  end

  ------------------------------------------------------------------ dialog --

  dlg = Dialog{
    title = "Minecraft Skin Viewer",
    -- By default Aseprite shrinks a dialog back to its preferred size every
    -- time a widget's text or visibility changes. This window is meant to be
    -- resized and left alone, so turn that off.
    autofit = 0,
    onclose = function()
      saveSettings()
      if timer then pcall(function() timer:stop() end) end
      detach()
      if siteListener then pcall(function() app.events:off(siteListener) end) end
      dlg = nil
      current = nil
    end,
  }

  local shown = {}
  refresh = function()
    if not dlg then return end
    refreshTexture()
    -- Only touch a label whose text really changed: this runs on every edit
    -- to the skin, and an untouched label costs no layout at all.
    local tracking = (state.pinned and "pinned: " or "tracking: ") .. spriteLabel(state.sprite)
    if tracking ~= shown.tracking then
      shown.tracking = tracking
      modify{ id = "tracking", text = tracking }
    end
    dlg:repaint()
  end

  local function syncChecks()
    for _, p in ipairs(PARTS) do
      for _, l in ipairs(LAYERS) do
        modify{ id = checkId(p.key, l.key), selected = state.vis[p.key][l.key] }
      end
    end
  end

  local function setLayer(layerKey, on)
    for _, p in ipairs(PARTS) do state.vis[p.key][layerKey] = on end
  end
  local function partIsOn(partKey)
    for _, l in ipairs(LAYERS) do
      if state.vis[partKey][l.key] then return true end
    end
    return false
  end

  dlg:canvas{
    id = "view",
    width = CANVAS_W,
    height = CANVAS_H,
    focus = true,
    onpaint = function(ev)
      local gc = ev.context
      ensureTargets(gc.width, gc.height)
      local t0 = os.clock()
      local img, err = renderFrame()
      local t1 = os.clock()
      if not img then
        gc.color = Color{ r = 190, g = 190, b = 200 }
        local msg = err or "Nothing to show"
        local sz = gc:measureText(msg)
        gc:fillText(msg, (gc.width - sz.width) // 2, (gc.height - sz.height) // 2)
        return
      end
      gc:drawImage(img, 0, 0)
      if state.stats then
      local t2 = os.clock()
      perf.render, perf.blit = (t1 - t0) * 1000, (t2 - t1) * 1000
      local now = os.time()
      if now ~= perf.sec then
        perf.fps = (now - perf.sec == 1) and perf.frames or 0
        perf.frames, perf.sec = 0, now
      end
      perf.frames = perf.frames + 1

      local lines = {
        ("render %.1f ms   blit %.1f ms"):format(perf.render, perf.blit),
        ("%d fps   poll %.2f ms"):format(perf.fps, perf.poll),
        ("buffer %dx%d   ssaa x%d"):format(rw, rh, rss),
      }
      local lineH, boxW = 0, 0
      for _, line in ipairs(lines) do
        local sz = gc:measureText(line)
        lineH = math.max(lineH, sz.height)
        boxW = math.max(boxW, sz.width)
      end
      gc.color = Color{ r = 0, g = 0, b = 0, a = 170 }
      gc:fillRect(Rectangle(0, 0, boxW + 6, (lineH + 1) * #lines + 4))
      gc.color = Color{ r = 235, g = 235, b = 120 }
      for i, line in ipairs(lines) do
        gc:fillText(line, 3, 2 + (i - 1) * (lineH + 1))
      end
      end

      -- Help badge in the top-right corner. Its rectangle is remembered so a
      -- click there toggles the cheat sheet instead of starting an orbit.
      do
        local sz = gc:measureText("?")
        local side = math.max(sz.width, sz.height) + 4
        local bx, by = gc.width - side - 3, 3
        helpRect = { x = bx, y = by, w = side, h = side }
        gc.color = state.help and Color{ r = 235, g = 235, b = 120, a = 230 }
                               or Color{ r = 0, g = 0, b = 0, a = 150 }
        gc:fillRect(Rectangle(bx, by, side, side))
        gc.color = state.help and Color{ r = 20, g = 20, b = 20 }
                               or Color{ r = 235, g = 235, b = 235 }
        gc:fillText("?", bx + (side - sz.width) // 2, by + (side - sz.height) // 2)
      end

      if state.help then
        local keyW, textW, lineH = 0, 0, 0
        for _, row in ipairs(HELP) do
          local k, t = gc:measureText(row[1]), gc:measureText(row[2])
          keyW, textW = math.max(keyW, k.width), math.max(textW, t.width)
          lineH = math.max(lineH, k.height, t.height)
        end
        local pad, gap = 4, 6
        local boxW = pad + keyW + gap + textW + pad
        local boxH = pad + (lineH + 2) * #HELP + pad
        local x = math.max(0, (gc.width - boxW) // 2)
        local y = math.max(0, (gc.height - boxH) // 2)
        gc.color = Color{ r = 0, g = 0, b = 0, a = 200 }
        gc:fillRect(Rectangle(x, y, boxW, boxH))
        for i, row in ipairs(HELP) do
          local ly = y + pad + (i - 1) * (lineH + 2)
          gc.color = Color{ r = 235, g = 235, b = 120 }
          gc:fillText(row[1], x + pad, ly)
          gc.color = Color{ r = 235, g = 235, b = 235 }
          gc:fillText(row[2], x + pad + keyW + gap, ly)
        end
      end
    end,
    onmousedown = function(ev)
      local r = helpRect
      if r and ev.x >= r.x and ev.x < r.x + r.w and ev.y >= r.y and ev.y < r.y + r.h then
        state.help = not state.help
        dlg:repaint()
        return
      end
      state.lastX, state.lastY = ev.x, ev.y
      state.panning = (ev.button == MouseButton.MIDDLE) or ev.shiftKey
      state.dragging = not state.panning
    end,
    onmousemove = function(ev)
      if not (state.dragging or state.panning) then return end
      local dx, dy = ev.x - state.lastX, ev.y - state.lastY
      state.lastX, state.lastY = ev.x, ev.y
      if state.panning then
        view.panX = view.panX + dx
        view.panY = view.panY + dy
      else
        M.orbit(view, dx, dy)
      end
      dlg:repaint()
    end,
    onmouseup = function()
      state.dragging, state.panning = false, false
    end,
    onwheel = function(ev)
      M.zoom(view, ev.deltaY)
      dlg:repaint()
    end,
    onkeydown = function(ev)
      local code = ev.code or ""
      local key = (ev.key or ""):lower()
      local digit = code:match("^Digit(%d)$") or code:match("^Numpad(%d)$") or key:match("^(%d)$")
      local handled = true

      local partIndex = SHIFT_DIGITS[ev.key or ""]
        or (digit and ev.shiftKey and tonumber(digit)) or nil

      if partIndex then
        local p = PARTS[partIndex]
        if p then
          local on = not partIsOn(p.key)
          for _, l in ipairs(LAYERS) do state.vis[p.key][l.key] = on end
          syncChecks(); rebuildVisible()
        end
      elseif digit and PRESETS[digit] then
        local p = PRESETS[digit]
        view.yaw, view.pitch = math.rad(p.yaw), math.rad(p.pitch)
      elseif code == "KeyR" or key == "r" then
        for k, v in pairs(DEFAULT_VIEW) do view[k] = v end
      elseif code == "KeyI" or key == "i" then
        setLayer("base", not state.vis[PARTS[1].key].base)
        syncChecks(); rebuildVisible()
      elseif code == "KeyO" or key == "o" then
        setLayer("overlay", not state.vis[PARTS[1].key].overlay)
        syncChecks(); rebuildVisible()
      elseif code == "KeyB" or key == "b" then
        state.bgIndex = state.bgIndex % #BACKGROUNDS + 1
        syncRadios()
      elseif code == "KeyT" or key == "t" then
        state.turntable = not state.turntable
        modify{ id = "turntable", selected = state.turntable }
      elseif code == "KeyH" or key == "h" or key == "?" then
        state.help = not state.help
      elseif code == "ArrowLeft"  then M.orbit(view, -12, 0)
      elseif code == "ArrowRight" then M.orbit(view,  12, 0)
      elseif code == "ArrowUp"    then M.orbit(view, 0, -12)
      elseif code == "ArrowDown"  then M.orbit(view, 0,  12)
      elseif code == "Equal" or key == "=" or key == "+" then M.zoom(view, -1)
      elseif code == "Minus" or key == "-" then M.zoom(view, 1)
      else
        handled = false
      end

      if handled then
        -- Claim the key. Otherwise it carries on to Aseprite, which treats
        -- B, I, T and friends as its own tool shortcuts.
        pcall(function() ev:stopPropagation() end)
        dlg:repaint()
        focusView()
      end
    end,
  }

  -- Which skin is on screen, and whether it will follow the active tab.
  dlg:label{ id = "tracking", text = "" }
  dlg:check{
    id = "pinned", text = "Pin",
    selected = state.pinned,
    onclick = function()
      state.pinned = dlg.data.pinned
      if not state.pinned and app.sprite ~= state.sprite then attach(app.sprite) end
      refresh()
      focusView()
    end,
  }

  local function names(list)
    local out = {}
    for i, e in ipairs(list) do out[i] = e.name end
    return out
  end

  -- Controls live in tabs so the switches cost no panel height.
  dlg:tab{ id = "tabView", text = "View" }

  -- Every choice here is a short fixed list, so each is a row of radio
  -- buttons: one click, nothing to open or scroll. A click re-asserts every
  -- group from `state` rather than trusting Aseprite's implicit grouping, so
  -- one row can never knock out the selection in another.
  local radioGroups = {}
  local colorShown = BACKGROUNDS[state.bgIndex].custom == true

  syncRadios = function()
    for _, g in ipairs(radioGroups) do
      local current = g.get()
      for i = 1, g.count do
        modify{ id = g.prefix .. i, selected = (i == current) }
      end
    end
    -- Changing visibility makes Aseprite lay the whole dialog out again and
    -- snap the window back to its preferred size, so only do it on a real
    -- change rather than on every click.
    local showColor = BACKGROUNDS[state.bgIndex].custom == true
    if showColor ~= colorShown then
      colorShown = showColor
      modify{ id = "bgColor", visible = showColor }
    end
  end

  local function radioRow(prefix, label, texts, get, set)
    radioGroups[#radioGroups + 1] = { prefix = prefix, count = #texts, get = get }
    for i, text in ipairs(texts) do
      dlg:radio{
        id = prefix .. i,
        label = (i == 1) and label or nil,
        text = text,
        selected = (i == get()),
        onclick = function()
          set(i)
          syncRadios()
          focusView()
        end,
      }
    end
  end

  radioRow("model_", "Model", MODEL_MODES,
    function()
      for i, m in ipairs(MODEL_MODES) do
        if m == state.modelMode then return i end
      end
      return 1
    end,
    function(i)
      state.modelMode = MODEL_MODES[i]
      state.tex = nil
      refresh(); saveSettings()
    end)

  dlg:check{
    id = "smoothing", label = "Smoothing", text = "Smooth edges",
    selected = (state.ssaa == 2),
    onclick = function()
      state.ssaa = dlg.data.smoothing and 2 or 1
      dlg:repaint(); saveSettings()
      focusView()
    end,
  }

  radioRow("bg_", "Background", names(BACKGROUNDS),
    function() return state.bgIndex end,
    function(i) state.bgIndex = i; dlg:repaint(); saveSettings() end)
  dlg:color{
    id = "bgColor",
    visible = BACKGROUNDS[state.bgIndex].custom == true,
    color = Color{ r = state.bgCustom[1], g = state.bgCustom[2], b = state.bgCustom[3] },
    onchange = function()
      local c = dlg.data.bgColor
      state.bgCustom = { c.red, c.green, c.blue }
      -- Picking a color is a clear request to use it.
      for i, b in ipairs(BACKGROUNDS) do
        if b.custom then state.bgIndex = i end
      end
      syncRadios()
      dlg:repaint(); saveSettings()
    end,
  }

  dlg:check{
    id = "turntable", label = "Turntable", text = "Auto-rotate",
    selected = state.turntable,
    onclick = function()
      state.turntable = dlg.data.turntable
      saveSettings()
      focusView()
    end,
  }

  dlg:check{
    id = "stats", label = "Stats", text = "Show timings",
    selected = state.stats,
    onclick = function()
      state.stats = dlg.data.stats
      dlg:repaint(); saveSettings()
      focusView()
    end,
  }

  dlg:tab{ id = "tabParts", text = "Parts" }

  for _, p in ipairs(PARTS) do
    for li, l in ipairs(LAYERS) do
      dlg:check{
        id = checkId(p.key, l.key),
        -- Only the first checkbox of each pair carries a label, which is what
        -- puts the part name in the label column and both switches on one row.
        label = (li == 1) and p.text or nil,
        text = l.text,
        selected = state.vis[p.key][l.key],
        onclick = function()
          state.vis[p.key][l.key] = dlg.data[checkId(p.key, l.key)]
          rebuildVisible(); dlg:repaint(); saveSettings()
          focusView()
        end,
      }
    end
  end

  dlg:button{
    id = "allInner", text = "All inner",
    onclick = function()
      setLayer("base", true); setLayer("overlay", false)
      syncChecks(); rebuildVisible(); dlg:repaint(); saveSettings()
      focusView()
    end,
  }
  dlg:button{
    id = "allParts", text = "Show all",
    onclick = function()
      state.vis = M.newVisibility()
      syncChecks(); rebuildVisible(); dlg:repaint(); saveSettings()
      focusView()
    end,
  }

  dlg:endtabs{ id = "tabs", selected = "tabView" }

  dlg:button{
    id = "newSkin", text = "New skin",
    onclick = function()
      local created = tmpl.chooser()
      if created then
        state.pinned = false
        modify{ id = "pinned", selected = false }
        attach(created)
        refresh()
      end
    end,
  }
  dlg:button{
    id = "reset", text = "Reset view",
    onclick = function()
      for k, v in pairs(DEFAULT_VIEW) do view[k] = v end
      dlg:repaint(); saveSettings()
      focusView()
    end,
  }
  dlg:button{ id = "close", text = "Close", onclick = function() dlg:close() end }

  -- Follow the user as they switch tabs between skins, unless pinned.
  siteListener = app.events:on('sitechange', function()
    if not state.pinned and app.sprite ~= state.sprite then
      attach(app.sprite)
      refresh()
    end
  end)

  attach(app.sprite)
  -- Prepare the texture before the window exists, but do not ask for a paint
  -- yet: a repaint issued before show() is discarded, which would leave the
  -- canvas blank until the first mouse move.
  refreshTexture()
  rebuildVisible()
  -- Reopen where the window was left, pulled back on screen if Aseprite's own
  -- window has since become smaller than that spot.
  local showArgs = { wait = false }
  if state.win then
    pcall(function()
      local w, h = state.win.w, state.win.h
      local x, y = state.win.x, state.win.y
      local okWin, aw, ah = pcall(function() return app.window.width, app.window.height end)
      if okWin and aw and ah and aw > 0 and ah > 0 then
        w, h = math.min(w, aw), math.min(h, ah)
        x = math.max(0, math.min(x, aw - w))
        y = math.max(0, math.min(y, ah - h))
      end
      showArgs.bounds = Rectangle(x, y, w, h)
    end)
  end
  dlg:show(showArgs)
  refresh()

  timer = Timer{ interval = POLL_SECONDS, ontick = function()
    local ok = pcall(function()
      local t0 = os.clock()
      poll()
      perf.poll = (os.clock() - t0) * 1000
      if state.turntable and dlg then
        view.yaw = (view.yaw + TURNTABLE_STEP) % (2 * math.pi)
        dlg:repaint()
      end
    end)
    if not ok then pcall(function() timer:stop() end) end
  end }
  timer:start()

  current = {
    dlg = dlg,
    retarget = function()
      if not state.pinned and app.sprite ~= state.sprite then attach(app.sprite) end
      refresh()
      focusView()
    end,
  }
  return dlg
end

return M
