-- A small PNG decoder: 8-bit, non-interlaced images, any color type.
--
-- Aseprite can load PNGs itself, but only from a file, and it asks the user for
-- permission every time a script reads one. Decoding the bytes here lets the
-- skin downloader work from memory and never touch the disk.

local M = {}

local SIGNATURE <const> = "\137PNG\r\n\26\n"
local MAX_SIDE  <const> = 1024   -- far above any skin; refuses absurd headers

M.SIGNATURE = SIGNATURE

-- ---------------------------------------------------------------- inflate --

local LENGTH_BASE <const> = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                              35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LENGTH_EXTRA <const> = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                               3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DIST_BASE <const> = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385,
                            513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 }
local DIST_EXTRA <const> = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7,
                             8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
-- Order in which a dynamic block stores its code-length code lengths.
local CLEN_ORDER <const> = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

--- Canonical Huffman table from code lengths `lengths[0 .. n-1]`.
local function huffman(lengths, n)
  local count, symbol = {}, {}
  for len = 0, 15 do count[len] = 0 end
  for s = 0, n - 1 do count[lengths[s]] = count[lengths[s]] + 1 end
  local offs = { [1] = 0 }
  for len = 1, 14 do offs[len + 1] = offs[len] + count[len] end
  for s = 0, n - 1 do
    local len = lengths[s]
    if len ~= 0 then
      symbol[offs[len]] = s
      offs[len] = offs[len] + 1
    end
  end
  return { count = count, symbol = symbol }
end

local FIXED_LIT, FIXED_DIST
do
  local l = {}
  for s = 0, 143 do l[s] = 8 end
  for s = 144, 255 do l[s] = 9 end
  for s = 256, 279 do l[s] = 7 end
  for s = 280, 287 do l[s] = 8 end
  FIXED_LIT = huffman(l, 288)
  local d = {}
  for s = 0, 29 do d[s] = 5 end
  FIXED_DIST = huffman(d, 30)
end

--- Inflate the raw deflate stream in `data` starting at byte `pos`.
-- Returns the output as a table of byte values and its length.
local function inflate(data, pos)
  local out, n = {}, 0
  local bitbuf, bitcnt = 0, 0

  local function bits(k)
    while bitcnt < k do
      local b = data:byte(pos)
      if not b then error("PNG data ends early", 0) end
      pos = pos + 1
      bitbuf = bitbuf | (b << bitcnt)
      bitcnt = bitcnt + 8
    end
    local v = bitbuf & ((1 << k) - 1)
    bitbuf = bitbuf >> k
    bitcnt = bitcnt - k
    return v
  end

  local function decode(h)
    local code, first, index = 0, 0, 0
    local count = h.count
    for len = 1, 15 do
      code = code | bits(1)
      local c = count[len]
      if code - c < first then return h.symbol[index + (code - first)] end
      index = index + c
      first = (first + c) << 1
      code = code << 1
    end
    error("bad Huffman code in PNG data", 0)
  end

  local function codes(lit, dist)
    while true do
      local sym = decode(lit)
      if sym < 256 then
        n = n + 1
        out[n] = sym
      elseif sym == 256 then
        return
      else
        sym = sym - 256
        local base = LENGTH_BASE[sym]
        if not base then error("bad length code in PNG data", 0) end
        local len = base + bits(LENGTH_EXTRA[sym])
        local dsym = decode(dist) + 1
        local dbase = DIST_BASE[dsym]
        if not dbase then error("bad distance code in PNG data", 0) end
        local d = dbase + bits(DIST_EXTRA[dsym])
        if d > n then error("bad distance in PNG data", 0) end
        for _ = 1, len do
          n = n + 1
          out[n] = out[n - d]
        end
      end
    end
  end

  repeat
    local final = bits(1)
    local kind = bits(2)
    if kind == 0 then
      bitbuf, bitcnt = 0, 0   -- stored blocks start on a byte boundary
      local len = data:byte(pos) | (data:byte(pos + 1) << 8)
      pos = pos + 4           -- LEN and its complement
      for i = 0, len - 1 do
        n = n + 1
        out[n] = data:byte(pos + i)
      end
      pos = pos + len
    elseif kind == 1 then
      codes(FIXED_LIT, FIXED_DIST)
    elseif kind == 2 then
      local nlen, ndist, ncode = bits(5) + 257, bits(5) + 1, bits(4) + 4
      local cl = {}
      for s = 0, 18 do cl[s] = 0 end
      for i = 1, ncode do cl[CLEN_ORDER[i]] = bits(3) end
      local clh = huffman(cl, 19)

      local lengths, i = {}, 0
      while i < nlen + ndist do
        local sym = decode(clh)
        if sym < 16 then
          lengths[i] = sym
          i = i + 1
        else
          local prev, rep = 0, 0
          if sym == 16 then
            if i == 0 then error("bad code lengths in PNG data", 0) end
            prev, rep = lengths[i - 1], 3 + bits(2)
          elseif sym == 17 then
            rep = 3 + bits(3)
          else
            rep = 11 + bits(7)
          end
          for _ = 1, rep do
            lengths[i] = prev
            i = i + 1
          end
        end
      end

      local dl = {}
      for s = 0, ndist - 1 do dl[s] = lengths[nlen + s] or 0 end
      codes(huffman(lengths, nlen), huffman(dl, ndist))
    else
      error("bad block type in PNG data", 0)
    end
  until final == 1

  return out, n
end

-- -------------------------------------------------------------------- PNG --

-- Bytes per pixel for each color type at 8 bits per channel.
local CHANNELS <const> = { [0] = 1, [2] = 3, [3] = 1, [4] = 2, [6] = 4 }

local function decode(data)
  if data:sub(1, #SIGNATURE) ~= SIGNATURE then error("not a PNG", 0) end

  local w, h, ctype
  local idat, palette, alpha = {}, nil, nil
  local pos = #SIGNATURE + 1
  while pos + 7 <= #data do
    local len, kind = string.unpack(">I4c4", data, pos)
    local body = data:sub(pos + 8, pos + 7 + len)
    if #body < len then error("PNG data ends early", 0) end
    if kind == "IHDR" then
      local depth, compression, filter, interlace
      w, h, depth, ctype, compression, filter, interlace = string.unpack(">I4I4BBBBB", body)
      if depth ~= 8 or not CHANNELS[ctype] or interlace ~= 0 or compression ~= 0 or filter ~= 0 then
        error("unsupported PNG format", 0)
      end
      if w < 1 or h < 1 or w > MAX_SIDE or h > MAX_SIDE then error("unsupported PNG size", 0) end
    elseif kind == "PLTE" then
      palette = body
    elseif kind == "tRNS" then
      alpha = body
    elseif kind == "IDAT" then
      idat[#idat + 1] = body
    elseif kind == "IEND" then
      break
    end
    pos = pos + 12 + len   -- length, type, body, CRC
  end
  if not w then error("PNG has no header", 0) end
  if ctype == 3 and not palette then error("PNG has no palette", 0) end

  -- Skip the two-byte zlib header; the deflate stream follows it.
  local raw, rawLen = inflate(table.concat(idat), 3)
  local bpp = CHANNELS[ctype]
  local stride = w * bpp
  if rawLen < (stride + 1) * h then error("PNG data ends early", 0) end

  local rows = {}
  local prev = {}
  for i = 1, stride do prev[i] = 0 end
  local p = 1
  for y = 1, h do
    local filter = raw[p]
    p = p + 1
    local cur = {}
    for i = 1, stride do
      local x = raw[p + i - 1]
      local a = (i > bpp) and cur[i - bpp] or 0
      local b = prev[i]
      if filter == 1 then
        x = x + a
      elseif filter == 2 then
        x = x + b
      elseif filter == 3 then
        x = x + ((a + b) >> 1)
      elseif filter == 4 then
        local c = (i > bpp) and prev[i - bpp] or 0
        local pa, pb, pc = math.abs(b - c), math.abs(a - c), math.abs(a + b - 2 * c)
        if pa <= pb and pa <= pc then x = x + a
        elseif pb <= pc then x = x + b
        else x = x + c end
      elseif filter ~= 0 then
        error("bad filter in PNG data", 0)
      end
      cur[i] = x & 0xFF
    end
    p = p + stride

    local px = {}
    local char = string.char
    for x = 0, w - 1 do
      local o = x * bpp
      if ctype == 6 then
        px[x + 1] = char(cur[o + 1], cur[o + 2], cur[o + 3], cur[o + 4])
      elseif ctype == 2 then
        px[x + 1] = char(cur[o + 1], cur[o + 2], cur[o + 3], 255)
      elseif ctype == 3 then
        local idx = cur[o + 1]
        local r, g, b = palette:byte(idx * 3 + 1, idx * 3 + 3)
        if not b then error("bad palette index in PNG data", 0) end
        px[x + 1] = char(r, g, b, alpha and alpha:byte(idx + 1) or 255)
      elseif ctype == 0 then
        local v = cur[o + 1]
        px[x + 1] = char(v, v, v, 255)
      else
        local v = cur[o + 1]
        px[x + 1] = char(v, v, v, cur[o + 2])
      end
    end
    rows[y] = table.concat(px)
    prev = cur
  end

  return w, h, table.concat(rows)
end

--- Decode a PNG held in the string `data`.
-- Returns width, height and the pixels as RGBA bytes, or nil plus a message.
function M.decode(data)
  local ok, w, h, rgba = pcall(decode, data)
  if not ok then return nil, tostring(w) end
  return w, h, rgba
end

return M
