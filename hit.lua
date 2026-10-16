-- Hit Reaction Kit core. Pure Lua, integer maths only. Every output pixel is a copy of a source pixel, except the
-- flash colour (one value you choose). Images are {w=,h=,d={}} with 0 = transparent.
local M = {}
function M.new(w, h) local d = {} for i = 1, w * h do d[i] = 0 end return { w = w, h = h, d = d } end
function M.get(im, x, y) if x < 0 or y < 0 or x >= im.w or y >= im.h then return 0 end return im.d[y * im.w + x + 1] end
function M.set(im, x, y, v) if x >= 0 and y >= 0 and x < im.w and y < im.h then im.d[y * im.w + x + 1] = v end end
function M.clone(im) local o = M.new(im.w, im.h) for i = 1, #im.d do o.d[i] = im.d[i] end return o end
local function round(x) if x >= 0 then return math.floor(x + 0.5) end return -math.floor(-x + 0.5) end

function M.bbox(im)
  local x0, y0, x1, y1 = math.huge, math.huge, -1, -1
  for y = 0, im.h - 1 do for x = 0, im.w - 1 do
    if im.d[y * im.w + x + 1] ~= 0 then
      if x < x0 then x0 = x end; if x > x1 then x1 = x end; if y < y0 then y0 = y end; if y > y1 then y1 = y end
    end
  end end
  if x1 < 0 then return nil end
  return x0, y0, x1, y1
end

function M.shift(im, dx, dy)
  local o = M.new(im.w, im.h)
  for y = 0, im.h - 1 do for x = 0, im.w - 1 do
    local v = im.d[y * im.w + x + 1]
    if v ~= 0 then M.set(o, x + dx, y + dy, v) end
  end end
  return o
end

-- Hit flash: whole silhouette in the flash value, or (outline_only) only the edge pixels; the rest stays as is.
function M.flash(im, fv, outline_only)
  local o = M.new(im.w, im.h)
  for y = 0, im.h - 1 do for x = 0, im.w - 1 do
    local v = im.d[y * im.w + x + 1]
    if v ~= 0 then
      if outline_only then
        local edge = M.get(im, x - 1, y) == 0 or M.get(im, x + 1, y) == 0 or M.get(im, x, y - 1) == 0 or M.get(im, x, y + 1) == 0
        o.d[y * im.w + x + 1] = edge and fv or v
      else
        o.d[y * im.w + x + 1] = fv
      end
    end
  end end
  return o
end

-- Shake amplitude of frame k (1..n): decaying, never above amp, never below 1, never growing.
function M.shake_amp(k, n, amp) return math.max(1, math.ceil(amp * (n - k + 1) / (n + 1))) end
-- axis: "h", "v" or "both". Sign alternates every frame; "both" uses a smaller vertical share.
function M.shake(im, k, n, amp, axis)
  local a = M.shake_amp(k, n, amp)
  local s = (k % 2 == 1) and 1 or -1
  local dx, dy = 0, 0
  if axis == "h" then dx = s * a
  elseif axis == "v" then dy = s * a
  else dx = s * a; dy = -s * math.floor((a + 1) / 2) end
  return M.shift(im, dx, dy), dx, dy
end

-- Squash rows 0..anchor to (height - sq) rows, anchor row fixed (nearest-neighbour). sq >= 0.
local function squash(im, anchor, sq)
  local x0, y0 = M.bbox(im)
  if not x0 or sq <= 0 then return M.clone(im) end
  anchor = math.min(anchor, im.h - 1)
  if anchor < y0 then return M.clone(im) end
  local H = anchor - y0 + 1
  local nh = H - sq
  local o = M.new(im.w, im.h)
  for y = anchor + 1, im.h - 1 do for x = 0, im.w - 1 do M.set(o, x, y, M.get(im, x, y)) end end
  if nh < 1 then return o end
  for j = 0, nh - 1 do
    local sj = math.floor(j * H / nh)
    for x = 0, im.w - 1 do M.set(o, x, anchor - j, M.get(im, x, anchor - sj)) end
  end
  return o
end
M.squash = squash

-- Knockback frame k (1..n): pushed dir*dist px away, squashed by sq rows at the peak, back to the original at k = n.
function M.knockback(im, k, n, dist, dir, sq, anchor)
  local p = math.sin(math.pi * k / n)
  if k >= n then return M.clone(im) end
  local o = squash(im, anchor, round(sq * p))
  return M.shift(o, dir * round(dist * p), 0)
end

-- Blink (i-frames): odd frames hidden (or dithered: every 2nd pixel), even frames the original.
function M.blink(im, k, dither)
  if k % 2 == 0 then return M.clone(im) end
  local o = M.new(im.w, im.h)
  if not dither then return o end
  for y = 0, im.h - 1 do for x = 0, im.w - 1 do
    if (x + y) % 2 == 0 then o.d[y * im.w + x + 1] = im.d[y * im.w + x + 1] end
  end end
  return o
end

local BAYER = { { 0, 8, 2, 10 }, { 12, 4, 14, 6 }, { 3, 11, 1, 9 }, { 15, 7, 13, 5 } }
-- Death dissolve frame k (1..n): a pixel survives if its Bayer value >= 16*k/n. Last frame is empty.
function M.dissolve(im, k, n)
  local o = M.new(im.w, im.h)
  for y = 0, im.h - 1 do for x = 0, im.w - 1 do
    local v = im.d[y * im.w + x + 1]
    if v ~= 0 and BAYER[y % 4 + 1][x % 4 + 1] * n >= 16 * k then o.d[y * im.w + x + 1] = v end
  end end
  return o
end

-- Segment of frames for an effect. opts: fv, outline, flash_n, alt, amp, axis, n, dist, dir, sq, anchor, dither.
function M.segment(im, name, o)
  local out = {}
  if name == "hit" then
    for i = 1, o.flash_n do
      out[#out + 1] = M.flash(im, o.fv, o.outline)
      if o.alt or i == o.flash_n then out[#out + 1] = M.clone(im) end
    end
  elseif name == "shake" then
    for k = 1, o.n do out[#out + 1] = (M.shake(im, k, o.n, o.amp, o.axis)) end
  elseif name == "knockback" then
    for k = 1, o.n do out[#out + 1] = M.knockback(im, k, o.n, o.dist, o.dir, o.sq, o.anchor) end
  elseif name == "blink" then
    for k = 1, o.n do out[#out + 1] = M.blink(im, k, o.dither) end
  elseif name == "dissolve" then
    for k = 1, o.n do out[#out + 1] = M.dissolve(im, k, o.n) end
  else error("unknown effect " .. tostring(name)) end
  return out
end

return M
