-- Minecraft player geometry and its 64x64 skin UV layout.
--
-- Space: +X right, +Y up, +Z toward the viewer. Origin sits between the feet,
-- so the model spans y = 0 (soles) to y = 32 (top of head), in skin pixels.
-- "Right arm" is the player's right, which is -X when they face the camera.

local M = {}

-- Per-face brightness, matching Minecraft's own directional shading.
local SHADE_TOP    <const> = 1.00
local SHADE_SIDE   <const> = 0.60
local SHADE_FRONT  <const> = 0.80
local SHADE_BOTTOM <const> = 0.50

-- The standard box unwrap. For a box of size (w,h,d) whose net starts at
-- (u,v), the six faces land in a fixed cross layout:
--
--        +---+---+
--        |top|bot|          row 1, height d
--    +---+---+---+---+
--    |rgt|frt|lft|bck|      row 2, height h
--    +---+---+---+---+
--      d   w   d   w
local function unwrap(u, v, w, h, d)
  return {
    top    = { u + d,         v,     w, d },
    bottom = { u + d + w,     v,     w, d },
    right  = { u,             v + d, d, h },
    front  = { u + d,         v + d, w, h },
    left   = { u + d + w,     v + d, d, h },
    back   = { u + d + w + d, v + d, w, h },
  }
end

-- Build the six faces of an axis-aligned box.
--
-- Each face lists its four corners in texture order — top-left, top-right,
-- bottom-right, bottom-left as seen from outside the box — so the rasterizer
-- can map the UV rect onto them without per-face special cases.
local function box(x0, y0, z0, x1, y1, z1, uv, inflate)
  inflate = inflate or 0
  x0, y0, z0 = x0 - inflate, y0 - inflate, z0 - inflate
  x1, y1, z1 = x1 + inflate, y1 + inflate, z1 + inflate

  return {
    { name = "front",  shade = SHADE_FRONT,  uv = uv.front,
      quad = { {x0,y1,z1}, {x1,y1,z1}, {x1,y0,z1}, {x0,y0,z1} } },
    { name = "back",   shade = SHADE_FRONT,  uv = uv.back,
      quad = { {x1,y1,z0}, {x0,y1,z0}, {x0,y0,z0}, {x1,y0,z0} } },
    { name = "right",  shade = SHADE_SIDE,   uv = uv.right,
      quad = { {x0,y1,z0}, {x0,y1,z1}, {x0,y0,z1}, {x0,y0,z0} } },
    { name = "left",   shade = SHADE_SIDE,   uv = uv.left,
      quad = { {x1,y1,z1}, {x1,y1,z0}, {x1,y0,z0}, {x1,y0,z1} } },
    { name = "top",    shade = SHADE_TOP,    uv = uv.top,
      quad = { {x0,y1,z0}, {x1,y1,z0}, {x1,y1,z1}, {x0,y1,z1} } },
    { name = "bottom", shade = SHADE_BOTTOM, uv = uv.bottom,
      quad = { {x0,y0,z1}, {x1,y0,z1}, {x1,y0,z0}, {x0,y0,z0} } },
  }
end

-- Overlay ("hat", "jacket", sleeves, trouser legs) sits slightly proud of the
-- base box so it never z-fights with the skin underneath.
local OVERLAY_INFLATE <const> = 0.25
local HAT_INFLATE     <const> = 0.5

-- Part table. `armWidth` is 4 for the classic model, 3 for slim ("Alex").
function M.build(slim)
  local aw = slim and 3 or 4          -- arm width
  local ax = slim and 7 or 8          -- outer arm edge, mirrored per side
  local parts = {}

  local function add(name, layer, x0,y0,z0, x1,y1,z1, u,v, w,h,d, inflate)
    local faces = box(x0,y0,z0, x1,y1,z1, unwrap(u,v,w,h,d), inflate)
    for _, f in ipairs(faces) do
      f.part = name
      f.layer = layer
      parts[#parts + 1] = f
    end
  end

  --   name        layer     box bounds                    uv     w  h  d
  add("head",     "base",    -4,24,-4,   4,32, 4,   0, 0,  8, 8, 8)
  add("body",     "base",    -4,12,-2,   4,24, 2,  16,16,  8,12, 4)
  add("rightArm", "base",   -ax,12,-2,  -4,24, 2,  40,16, aw,12, 4)
  add("leftArm",  "base",     4,12,-2,  ax,24, 2,  32,48, aw,12, 4)
  add("rightLeg", "base",    -4, 0,-2,   0,12, 2,   0,16,  4,12, 4)
  add("leftLeg",  "base",     0, 0,-2,   4,12, 2,  16,48,  4,12, 4)

  add("head",     "overlay", -4,24,-4,   4,32, 4,  32, 0,  8, 8, 8, HAT_INFLATE)
  add("body",     "overlay", -4,12,-2,   4,24, 2,  16,32,  8,12, 4, OVERLAY_INFLATE)
  add("rightArm", "overlay",-ax,12,-2,  -4,24, 2,  40,32, aw,12, 4, OVERLAY_INFLATE)
  add("leftArm",  "overlay",  4,12,-2,  ax,24, 2,  48,48, aw,12, 4, OVERLAY_INFLATE)
  add("rightLeg", "overlay", -4, 0,-2,   0,12, 2,   0,32,  4,12, 4, OVERLAY_INFLATE)
  add("leftLeg",  "overlay",  0, 0,-2,   4,12, 2,   0,48,  4,12, 4, OVERLAY_INFLATE)

  return parts
end

-- Texture regions covered by a classic (4-wide) arm but not by a slim (3-wide)
-- one. A skin drawn for the slim model leaves every one of them empty, which
-- makes the arm width detectable rather than something the user must remember
-- to set — getting it wrong renders the arm backs shifted by a texel and their
-- outer column see-through.
local CLASSIC_ONLY <const> = {
  { 54, 20, 2, 12 },   -- right arm, back face
  { 50, 16, 2,  4 },   -- right arm, bottom face
  { 46, 52, 2, 12 },   -- left arm, back face
  { 42, 48, 2,  4 },   -- left arm, bottom face
}

--- True when the skin appears to be drawn for the slim ("Alex") model.
function M.detectSlim(image)
  if image.width ~= 64 or image.height ~= 64 then return false end
  local alpha = app.pixelColor.rgbaA
  for _, r in ipairs(CLASSIC_ONLY) do
    for y = r[2], r[2] + r[4] - 1 do
      for x = r[1], r[1] + r[3] - 1 do
        if alpha(image:getPixel(x, y)) ~= 0 then return false end
      end
    end
  end
  return true
end

M.HEIGHT = 32

return M
