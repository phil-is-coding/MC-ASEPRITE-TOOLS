-- Software triangle rasterizer: z-buffered, nearest-neighbor textured.
--
-- Two choices make this fast enough to run in Lua on every sprite edit:
--
--  * Orthographic projection. Affine UV interpolation is then exact, so the
--    inner loop never divides — no perspective correction needed.
--  * The framebuffer holds pre-packed 4-byte RGBA strings rather than numbers.
--    A skin has at most 4096 texels, so every (texel, face brightness) pair is
--    packed once into a lookup table; shading a pixel is one table read and one
--    table write. The finished frame is a single table.concat straight into
--    Image.bytes.

local M = {}

-- ---------------------------------------------------------------- textures --

local Texture = {}
Texture.__index = Texture

--- Pack a skin Image into per-brightness lookup tables.
-- Fully transparent texels map to `false` so the rasterizer can skip them,
-- which is what makes the overlay ("hat") layer render correctly.
function M.texture(image)
  local w, h = image.width, image.height
  local raw = image.bytes
  local self = setmetatable({ w = w, h = h, luts = {} }, Texture)

  -- Cache the unshaded RGBA of every texel, plus which ones are worth drawing.
  local n = w * h
  local r, g, b, a = {}, {}, {}, {}
  local opaque = {}
  for i = 1, n do
    local o = (i - 1) * 4
    local av = raw:byte(o + 4)
    r[i], g[i], b[i], a[i] = raw:byte(o + 1), raw:byte(o + 2), raw:byte(o + 3), av
    opaque[i] = av > 0
  end
  self.r, self.g, self.b, self.a, self.opaque, self.n = r, g, b, a, opaque, n
  return self
end

--- Lookup table of packed RGBA strings at a given brightness, built on demand.
function Texture:lut(shade)
  local lut = self.luts[shade]
  if lut then return lut end

  lut = {}
  local r, g, b, a, opaque = self.r, self.g, self.b, self.a, self.opaque
  local char = string.char
  for i = 1, self.n do
    if opaque[i] then
      lut[i] = char(r[i] * shade // 1, g[i] * shade // 1, b[i] * shade // 1, a[i])
    else
      lut[i] = false
    end
  end
  self.luts[shade] = lut
  return lut
end

-- --------------------------------------------------------------- renderer --

local Renderer = {}
Renderer.__index = Renderer

function M.renderer(w, h)
  return setmetatable({
    w = w, h = h,
    fb = {},      -- packed RGBA strings, one per pixel
    zb = {},      -- depth, larger is nearer
  }, Renderer)
end

--- Rasterize one screen-space triangle.
-- Vertices are {x, y, z, u, v}; x/y are pixel coords, z is depth (nearer is
-- larger), u/v are texel coords. Backfaces are culled by winding.
function Renderer:tri(p1, p2, p3, lut, texW)
  local x1, y1, z1, u1, v1 = p1[1], p1[2], p1[3], p1[4], p1[5]
  local x2, y2, z2, u2, v2 = p2[1], p2[2], p2[3], p2[4], p2[5]
  local x3, y3, z3, u3, v3 = p3[1], p3[2], p3[3], p3[4], p3[5]

  -- Signed area. Corners run top-left → top-right → bottom-right as seen from
  -- outside the box, which with screen y growing downward makes a front-facing
  -- triangle positive; cull the rest.
  local area = (x2 - x1) * (y3 - y1) - (x3 - x1) * (y2 - y1)
  if area <= 1e-9 then return end
  local inv = 1.0 / area

  local W, H = self.w, self.h
  local minx = math.max(0, math.floor(math.min(x1, x2, x3)))
  local maxx = math.min(W - 1, math.ceil(math.max(x1, x2, x3)))
  local miny = math.max(0, math.floor(math.min(y1, y2, y3)))
  local maxy = math.min(H - 1, math.ceil(math.max(y1, y2, y3)))
  if minx > maxx or miny > maxy then return end

  -- Edge functions, linear in x and y.
  local a1, b1 = -(y3 - y2), (x3 - x2)
  local a2, b2 = -(y1 - y3), (x1 - x3)
  local a3, b3 = -(y2 - y1), (x2 - x1)

  -- Attributes are linear too, so hoist their gradients out of the loop.
  local dudx = (a1 * u1 + a2 * u2 + a3 * u3) * inv
  local dvdx = (a1 * v1 + a2 * v2 + a3 * v3) * inv
  local dzdx = (a1 * z1 + a2 * z2 + a3 * z3) * inv

  local fb, zb = self.fb, self.zb
  local px, py = minx + 0.5, miny + 0.5

  local e1r = a1 * (px - x2) + b1 * (py - y2)
  local e2r = a2 * (px - x3) + b2 * (py - y3)
  local e3r = a3 * (px - x1) + b3 * (py - y1)

  for y = miny, maxy do
    local e1, e2, e3 = e1r, e2r, e3r
    local row = y * W
    -- Attribute values at the start of this scanline.
    local bu = (e1 * u1 + e2 * u2 + e3 * u3) * inv
    local bv = (e1 * v1 + e2 * v2 + e3 * v3) * inv
    local bz = (e1 * z1 + e2 * z2 + e3 * z3) * inv

    for x = minx, maxx do
      if e1 >= 0 and e2 >= 0 and e3 >= 0 then
        local idx = row + x + 1
        if bz > (zb[idx] or -1e30) then
          local ti = (bv // 1) * texW + (bu // 1) + 1
          local c = lut[ti]
          if c then
            fb[idx] = c
            zb[idx] = bz
          end
        end
      end
      e1 = e1 + a1; e2 = e2 + a2; e3 = e3 + a3
      bu = bu + dudx; bv = bv + dvdx; bz = bz + dzdx
    end

    e1r = e1r + b1; e2r = e2r + b2; e3r = e3r + b3
  end
end

--- Box-average each f x f block down to one pixel.
--
-- The whole interior of a face is the same interned string repeated, so a
-- pointer comparison skips the arithmetic everywhere except along edges --
-- which is exactly where anti-aliasing does any work. That keeps the resolve
-- proportional to silhouette length rather than to area.
local function resolve(fb, sw, sh, f)
  local dw, dh = sw // f, sh // f
  local out = {}
  local byte, char = string.byte, string.char
  local n = f * f
  local half = n // 2
  local oi = 1
  for y = 0, dh - 1 do
    local rowbase = y * f * sw
    for x = 0, dw - 1 do
      local p0 = rowbase + x * f + 1
      local s = fb[p0]
      local uniform = true
      for dy = 0, f - 1 do
        local rb = p0 + dy * sw
        for dx = 0, f - 1 do
          if fb[rb + dx] ~= s then uniform = false break end
        end
        if not uniform then break end
      end
      if uniform then
        out[oi] = s
      else
        local r, g, b, a = 0, 0, 0, 0
        for dy = 0, f - 1 do
          local rb = p0 + dy * sw
          for dx = 0, f - 1 do
            local br, bg, bb, ba = byte(fb[rb + dx], 1, 4)
            r = r + br; g = g + bg; b = b + bb; a = a + ba
          end
        end
        out[oi] = char((r + half) // n, (g + half) // n, (b + half) // n, (a + half) // n)
      end
      oi = oi + 1
    end
  end
  return table.concat(out)
end

M.resolve = resolve

--- Render the model. `cam` is {yaw, pitch, scale, originX, originY, pivotY},
-- angles in radians. The model turns about the height `pivotY` (model units),
-- and that point is what lands on (originX, originY).
-- `bg` is either one packed RGBA string (solid fill) or a table of them, one
-- per pixel, for a patterned backdrop. Returns a byte string ready to assign
-- to Image.bytes.
function Renderer:draw(faces, tex, cam, bg, ssaa)
  local W, H = self.w, self.h
  local fb, zb = self.fb, self.zb
  if type(bg) == "table" then
    for i = 1, W * H do fb[i] = bg[i]; zb[i] = -1e30 end
  else
    for i = 1, W * H do fb[i] = bg; zb[i] = -1e30 end
  end

  local cy, sy = math.cos(cam.yaw), math.sin(cam.yaw)
  local cp, sp = math.cos(cam.pitch), math.sin(cam.pitch)
  local scale = cam.scale
  local ox, oy = cam.originX or (W * 0.5), cam.originY
  local pivotY = cam.pivotY or 0

  local texW = tex.w
  local project = {}

  for f = 1, #faces do
    local face = faces[f]
    local quad = face.quad
    local u0, v0, uw, vh = face.uv[1], face.uv[2], face.uv[3], face.uv[4]

    for i = 1, 4 do
      local p = quad[i]
      local x, y, z = p[1], p[2] - pivotY, p[3]
      -- Yaw about Y, then pitch about X.
      local rx = x * cy + z * sy
      local rz = -x * sy + z * cy
      local ry2 = y * cp - rz * sp
      local rz2 = y * sp + rz * cp
      local t = project[i]
      if not t then t = {}; project[i] = t end
      t[1] = ox + rx * scale
      t[2] = oy - ry2 * scale
      t[3] = rz2
    end

    -- UV corners follow the quad's texture-order corners: TL, TR, BR, BL.
    -- Nudge inward by a hair so a texel boundary never samples the neighbor.
    local uL, uR = u0 + 0.001, u0 + uw - 0.001
    local vT, vB = v0 + 0.001, v0 + vh - 0.001
    local p1, p2, p3, p4 = project[1], project[2], project[3], project[4]
    p1[4], p1[5] = uL, vT
    p2[4], p2[5] = uR, vT
    p3[4], p3[5] = uR, vB
    p4[4], p4[5] = uL, vB

    local lut = tex:lut(face.shade)
    self:tri(p1, p2, p3, lut, texW)
    self:tri(p1, p3, p4, lut, texW)
  end

  if ssaa and ssaa > 1 then return resolve(fb, W, H, ssaa) end
  return table.concat(fb)
end

return M
