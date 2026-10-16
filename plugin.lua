-- Hit Reaction Kit -- Aseprite extension entry point.
-- The pixel maths live in hit.lua; this file reads cels, builds the new frames and writes the tags.

local core = nil
local LITE = true -- the Lite build flips this to true (see build_bundles.py)

local function load_core(dir)
  if not core then core = dofile(app.fs.joinPath(dir, "hit.lua")) end
  return core
end

-- Cel -> sprite-sized core image (0 = transparent). Indexed colours are stored as index+1.
local function cel_to_core(spr, cel)
  local S = core
  local im = S.new(spr.width, spr.height)
  local px = app.pixelColor
  local mode, tc = spr.colorMode, spr.transparentColor
  local cx, cy = cel.position.x, cel.position.y
  for it in cel.image:pixels() do
    local v = it()
    local x, y = it.x + cx, it.y + cy
    if mode == ColorMode.INDEXED then
      if v ~= tc then S.set(im, x, y, v + 1) end
    elseif mode == ColorMode.GRAY then
      if px.grayaA(v) > 0 then S.set(im, x, y, v) end
    else
      if px.rgbaA(v) > 0 then S.set(im, x, y, v) end
    end
  end
  return im
end

local function core_to_image(spr, im)
  local img = Image(im.w, im.h, spr.colorMode)
  local indexed = spr.colorMode == ColorMode.INDEXED
  if indexed then img:clear(spr.transparentColor) end
  for y = 0, im.h - 1 do for x = 0, im.w - 1 do
    local v = im.d[y * im.w + x + 1]
    if v ~= 0 then img:drawPixel(x, y, indexed and (v - 1) or v) end
  end end
  return img
end

-- The flash colour as a core value for this colour mode. Indexed sprites use the nearest palette entry,
-- so the output never leaves the palette.
local function flash_value(spr, c)
  local px = app.pixelColor
  local mode = spr.colorMode
  if mode == ColorMode.INDEXED then
    local pal, best, bi = spr.palettes[1], math.huge, 0
    for i = 0, #pal - 1 do
      if i ~= spr.transparentColor then
        local pc = pal:getColor(i)
        local d = (pc.red - c.red) ^ 2 + (pc.green - c.green) ^ 2 + (pc.blue - c.blue) ^ 2
        if d < best then best, bi = d, i end
      end
    end
    return bi + 1
  elseif mode == ColorMode.GRAY then
    return px.graya(math.floor((c.red * 30 + c.green * 59 + c.blue * 11) / 100), 255)
  end
  return px.rgba(c.red, c.green, c.blue, 255)
end

local function collect_layers(parent, out)
  for _, l in ipairs(parent.layers) do
    if l.isGroup then collect_layers(l, out)
    elseif l.isVisible then out[#out + 1] = l end
  end
end

-- plan: list of { name =, opts = }. Builds every segment as new frames after frame fn, one tag per segment.
-- Returns number of frames created or nil, message.
local function generate(spr, layer, fn, plan, all_layers, duration, fc)
  local S = core
  local layers = {}
  if all_layers then collect_layers(spr, layers) else layers[1] = layer end
  local src = {}
  for _, l in ipairs(layers) do
    local c = l:cel(fn)
    if c then src[#src + 1] = { layer = l, im = cel_to_core(spr, c) } end
  end
  if #src == 0 then return nil, "The selected frame has no drawing on this layer." end
  local anchor = -1
  for _, s in ipairs(src) do
    local _, _, _, y1 = S.bbox(s.im)
    if y1 and y1 > anchor then anchor = y1 end
  end
  local fv = flash_value(spr, fc)
  local made = 0
  app.transaction("Hit Reaction Kit", function()
    local cur = fn
    for _, seg in ipairs(plan) do
      local o = seg.opts
      o.fv, o.anchor = fv, anchor
      local per = {}
      for i, s in ipairs(src) do per[i] = S.segment(s.im, seg.name, o) end
      local first = cur + 1
      for k = 1, #per[1] do
        local nf = spr:newFrame(cur)
        nf.duration = duration / 1000
        for i, s in ipairs(src) do
          spr:newCel(s.layer, cur + 1, core_to_image(spr, per[i][k]), Point(0, 0))
        end
        cur = cur + 1
        made = made + 1
      end
      local tag = spr:newTag(first, cur)
      tag.name = seg.name
    end
  end)
  return made
end

local EFFECTS = { "Hit flash", "Shake", "Knockback", "Blink (i-frames)", "Death dissolve", "All five" }
local NAME_OF = { ["Hit flash"] = "hit", ["Shake"] = "shake", ["Knockback"] = "knockback",
                  ["Blink (i-frames)"] = "blink", ["Death dissolve"] = "dissolve" }
local ORDER = { "hit", "shake", "knockback", "blink", "dissolve" }

local function show_dialog(plugin)
  local spr = app.sprite
  if not spr then app.alert("Open a sprite first."); return end
  local layer = app.layer
  if not layer or layer.isGroup then app.alert("Select a normal layer first."); return end
  load_core(plugin.path)
  local prefs = plugin.preferences
  local title = LITE and "Hit Reaction Kit (Lite)" or "Hit Reaction Kit"
  local dlg = Dialog(title)
  if LITE then
    dlg:label { text = "Hit flash: your sprite in white for one frame, then back." }
    dlg:label { text = "2 new frames, tagged hit." }
  else
    dlg:combobox { id = "effect", label = "Effect", option = prefs.effect or "Hit flash", options = EFFECTS }
    dlg:color { id = "flash", label = "Flash colour", color = Color { r = 255, g = 255, b = 255 } }
    dlg:check { id = "outline", label = "Flash", text = "Edge pixels only (outline flash)", selected = prefs.outline == true }
    dlg:number { id = "flash_n", label = "Flash frames (1-3)", text = tostring(prefs.flash_n or 1), decimals = 0 }
    dlg:check { id = "alt", label = "Flash", text = "Alternate flash / original", selected = prefs.alt == true }
    dlg:separator()
    dlg:number { id = "n", label = "Frames (shake, knockback, blink, dissolve)", text = tostring(prefs.n or 6), decimals = 0 }
    dlg:slider { id = "amp", label = "Shake amplitude (px)", min = 1, max = 8, value = prefs.amp or 3 }
    dlg:combobox { id = "axis", label = "Shake axis", option = prefs.axis or "Horizontal", options = { "Horizontal", "Vertical", "Both" } }
    dlg:slider { id = "dist", label = "Knockback distance (px)", min = 1, max = 12, value = prefs.dist or 4 }
    dlg:combobox { id = "dir", label = "Knockback direction", option = prefs.dir or "Right", options = { "Right", "Left" } }
    dlg:slider { id = "sq", label = "Knockback squash (px)", min = 0, max = 4, value = prefs.sq or 1 }
    dlg:check { id = "dither", label = "Blink", text = "Dither instead of hiding", selected = prefs.dither == true }
    dlg:number { id = "duration", label = "Frame ms", text = tostring(prefs.duration or 70), decimals = 0 }
    dlg:check { id = "all", label = "Layers", text = "All visible layers (default: active layer only)", selected = prefs.all == true }
  end
  dlg:separator()
  dlg:button { id = "ok", text = "Generate", focus = true }
  dlg:button { id = "cancel", text = "Cancel" }
  if LITE then
    dlg:separator()
    dlg:label { text = "Full version: flash colour, shake, knockback, blink, death dissolve." }
  end
  dlg:show()
  local d = dlg.data
  if not d.ok then return end
  local plan, all_layers, duration, fc
  if LITE then
    plan = { { name = "hit", opts = { flash_n = 1, alt = true, outline = false } } }
    all_layers, duration, fc = false, 70, Color { r = 255, g = 255, b = 255 }
  else
    for _, k in ipairs { "effect", "outline", "flash_n", "alt", "n", "amp", "axis", "dist", "dir", "sq", "dither", "duration", "all" } do
      prefs[k] = d[k]
    end
    local n = math.max(2, math.min(24, math.floor(tonumber(d.n) or 6)))
    if n % 2 == 1 then n = n + 1 end -- blink needs an even count to end on the visible sprite
    local opts = {
      hit = { flash_n = math.max(1, math.min(3, math.floor(tonumber(d.flash_n) or 1))), alt = d.alt, outline = d.outline },
      shake = { n = n, amp = d.amp, axis = ({ Horizontal = "h", Vertical = "v", Both = "both" })[d.axis] or "h" },
      knockback = { n = n, dist = d.dist, dir = (d.dir == "Left") and -1 or 1, sq = d.sq },
      blink = { n = n, dither = d.dither },
      dissolve = { n = n },
    }
    plan = {}
    if d.effect == "All five" then
      for _, nm in ipairs(ORDER) do plan[#plan + 1] = { name = nm, opts = opts[nm] } end
    else
      local nm = NAME_OF[d.effect] or "hit"
      plan[1] = { name = nm, opts = opts[nm] }
    end
    all_layers, duration, fc = d.all, math.max(20, tonumber(d.duration) or 70), d.flash
  end
  local fn = app.frame and app.frame.frameNumber or 1
  local made, msg = generate(spr, layer, fn, plan, all_layers, duration, fc)
  if not made then app.alert { title = title, text = msg } end
  app.refresh()
end

function init(plugin)
  local id = LITE and "HitReactionKitLite" or "HitReactionKit"
  local title = LITE and "Hit Reaction Kit (Lite)..." or "Hit Reaction Kit..."
  plugin:newCommand { id = id, title = title, group = "cel_popup_properties", onclick = function() show_dialog(plugin) end }
  plugin:newCommand { id = id .. "Edit", title = title, group = "edit_fx", onclick = function() show_dialog(plugin) end }
end

function exit(plugin) end

return { load_core = load_core, generate = generate }
