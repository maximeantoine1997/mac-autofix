-- autofix/fx.lua
-- Visual feedback:
--   * while the model works, a light sweeps over the selected text and a bubble shows a spinner,
--   * when the text changes, the selection flashes in the result color and the bubble shows the result.
-- Every call here is protected with pcall. A visual problem never stops the fix.

local fx = {}

local theme = {}
local animate = true

local FPS = 45
local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local ICONS = { success = "✓", error = "✕", info = "•" }

local FONT_SIZE = 13
local BUBBLE_H = 28
local PAD_X = 12
local GAP = 7
local SHADOW = 12 -- room around the bubble for its shadow
local TEXT_PAD = 3 -- room around the selected text for the overlay

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function safe(fn, ...)
  local ok, res = pcall(fn, ...)
  if not ok then
    print("autofix fx: " .. tostring(res))
    return nil
  end
  return res
end

local function hex(value, alpha)
  local h = tostring(value or "#FFFFFF"):gsub("#", "")
  return {
    red = (tonumber(h:sub(1, 2), 16) or 255) / 255,
    green = (tonumber(h:sub(3, 4), 16) or 255) / 255,
    blue = (tonumber(h:sub(5, 6), 16) or 255) / 255,
    alpha = alpha or 1,
  }
end

local function now()
  return hs.timer.secondsSinceEpoch()
end

local function colorFor(kind)
  if kind == "success" then return theme.success end
  if kind == "error" then return theme.error end
  if kind == "busy" then return theme.accent end
  return theme.neutral
end

-- Hammerspoon can garbage-collect timers and canvases that nothing references.
-- Keep a reference to each one until it is done.
local live = {}

local function keep(obj)
  if obj then live[obj] = true end
  return obj
end

local function drop(obj)
  if obj then live[obj] = nil end
end

local function after(seconds, fn)
  local t
  t = hs.timer.doAfter(seconds, function()
    drop(t)
    safe(fn)
  end)
  return keep(t)
end

local function every(seconds, fn)
  return keep(hs.timer.doEvery(seconds, function() safe(fn) end))
end

local function stop(t)
  if t then
    t:stop()
    drop(t)
  end
end

local function remove(canvas, fade)
  if not canvas then return end
  fade = fade or 0
  safe(function() canvas:delete(fade) end)
  after(fade + 0.2, function() drop(canvas) end)
end

-- A short animation: step(p) gets p from 0 to 1.
local function tween(duration, step, done)
  local t0 = now()
  local t
  t = every(1 / FPS, function()
    local p = math.min(1, (now() - t0) / duration)
    step(p)
    if p >= 1 then
      stop(t)
      if done then done() end
    end
  end)
  return t
end

local FONT = (function()
  local ok, name = pcall(function() return hs.styledtext.defaultFonts.boldSystem.name end)
  if ok and type(name) == "string" then return name end
  return "Helvetica Neue"
end)()

local function textSize(str)
  local ok, s = pcall(hs.drawing.getTextDrawingSize, str, { font = FONT, size = FONT_SIZE })
  if ok and type(s) == "table" and s.w then return math.ceil(s.w), math.ceil(s.h) end
  return math.ceil(utf8.len(str) * FONT_SIZE * 0.6), math.ceil(FONT_SIZE * 1.3)
end

local iconWidth -- the widest icon, measured once
local function getIconWidth()
  if not iconWidth then
    iconWidth = 0
    for _, s in ipairs({ SPINNER[1], ICONS.success, ICONS.error, ICONS.info }) do
      iconWidth = math.max(iconWidth, (textSize(s)))
    end
  end
  return iconWidth
end

local function screenAt(point)
  for _, s in ipairs(hs.screen.allScreens()) do
    local f = s:fullFrame()
    if point.x >= f.x and point.x <= f.x + f.w and point.y >= f.y and point.y <= f.y + f.h then
      return s
    end
  end
  return hs.screen.mainScreen()
end

local function mouseAnchor()
  local m = hs.mouse.absolutePosition()
  return { x = m.x, y = m.y + 6, w = 0, h = 12 }
end

local function prepare(canvas)
  pcall(function() canvas:level(hs.canvas.windowLevels.overlay) end)
  pcall(function() canvas:behaviorAsLabels({ "canJoinAllSpaces", "transient" }) end)
  pcall(function() canvas:clickActivating(false) end)
  return keep(canvas)
end

---------------------------------------------------------------------------
-- Where is the selected text on the screen?
---------------------------------------------------------------------------

-- Returns a rect {x, y, w, h} in screen coordinates, or nil when the app
-- does not expose text positions (then the bubble shows at the mouse pointer).
function fx.locateSelection()
  return safe(function()
    local ax = hs.axuielement
    local app = hs.application.frontmostApplication()
    if app then
      -- Electron apps (Slack, Notion, Linear...) expose text positions only with this flag.
      pcall(function() ax.applicationElement(app):setAttributeValue("AXManualAccessibility", true) end)
    end
    local el = ax.systemWideElement():attributeValue("AXFocusedUIElement")
    if not el then return nil end
    local range = el:attributeValue("AXSelectedTextRange")
    if type(range) ~= "table" or (range.length or 0) == 0 then return nil end
    local b = el:parameterizedAttributeValue("AXBoundsForRange", range)
    if type(b) ~= "table" then return nil end
    local x, y = b.x, b.y
    local w, h = b.w or b.width, b.h or b.height
    if not (x and y and w and h) or w < 2 or h < 2 then return nil end
    local f = screenAt({ x = x + w / 2, y = y + h / 2 }):fullFrame()
    if w > f.w or h > f.h then return nil end
    return { x = x, y = y, w = w, h = h }
  end)
end

---------------------------------------------------------------------------
-- The overlay on the text
---------------------------------------------------------------------------

local function newOverlay(rect)
  local frame = {
    x = rect.x - TEXT_PAD,
    y = rect.y - TEXT_PAD,
    w = rect.w + TEXT_PAD * 2,
    h = rect.h + TEXT_PAD * 2,
  }
  local radius = math.min(7, frame.h / 2)
  local c = prepare(hs.canvas.new(frame))
  c:appendElements(
    { -- 1. tint
      type = "rectangle",
      action = "fill",
      roundedRectRadii = { xRadius = radius, yRadius = radius },
      fillColor = hex(theme.accent, 0.10),
    },
    { -- 2. the light that sweeps from left to right
      type = "rectangle",
      action = "fill",
      frame = { x = -1000, y = 0, w = 1, h = frame.h },
      fillGradient = "linear",
      fillGradientAngle = 0,
      fillGradientColors = { hex(theme.shimmer, 0), hex(theme.shimmer, 0.42), hex(theme.shimmer, 0) },
    },
    { -- 3. border
      type = "rectangle",
      action = "stroke",
      frame = { x = 0.75, y = 0.75, w = frame.w - 1.5, h = frame.h - 1.5 },
      roundedRectRadii = { xRadius = radius, yRadius = radius },
      strokeWidth = 1.5,
      strokeColor = hex(theme.accent, 0.5),
    }
  )
  return c, frame
end

---------------------------------------------------------------------------
-- The bubble
---------------------------------------------------------------------------

local function bubbleFrame(anchor, w)
  local scr = screenAt({ x = anchor.x + anchor.w / 2, y = anchor.y + anchor.h / 2 }):frame()
  local x = anchor.x + anchor.w / 2 - w / 2
  local y = anchor.y + anchor.h + 8
  if y + BUBBLE_H > scr.y + scr.h - 8 then
    y = anchor.y - BUBBLE_H - 8 -- no room below: put it above the text
  end
  x = math.max(scr.x + 8, math.min(x, scr.x + scr.w - w - 8))
  y = math.max(scr.y + 8, y)
  return { x = x, y = y, w = w, h = BUBBLE_H }
end

local function newBubble(anchor, kind, label)
  local color = colorFor(kind)
  local icon = (kind == "busy") and SPINNER[1] or ICONS[kind] or ICONS.info
  local iconW = getIconWidth()
  local labelW, labelH = textSize(label)
  local f = bubbleFrame(anchor, PAD_X * 2 + iconW + GAP + labelW)
  local ty = SHADOW + math.floor((BUBBLE_H - labelH) / 2)

  local c = prepare(hs.canvas.new({
    x = f.x - SHADOW,
    y = f.y - SHADOW,
    w = f.w + SHADOW * 2,
    h = f.h + SHADOW * 2,
  }))
  c:appendElements(
    { -- 1. pill
      type = "rectangle",
      action = "strokeAndFill",
      frame = { x = SHADOW, y = SHADOW, w = f.w, h = BUBBLE_H },
      roundedRectRadii = { xRadius = BUBBLE_H / 2, yRadius = BUBBLE_H / 2 },
      fillColor = hex(theme.bubble, 0.94),
      strokeColor = hex(color, 0.55),
      strokeWidth = 1,
      withShadow = true,
      shadow = { blurRadius = 10, color = hex("#000000", 0.35), offset = { h = -3, w = 0 } },
    },
    { -- 2. icon
      type = "text",
      text = icon,
      frame = { x = SHADOW + PAD_X, y = ty, w = iconW + 4, h = labelH + 2 },
      textColor = hex(color),
      textFont = FONT,
      textSize = FONT_SIZE,
    },
    { -- 3. label
      type = "text",
      text = label,
      frame = { x = SHADOW + PAD_X + iconW + GAP, y = ty, w = labelW + 6, h = labelH + 2 },
      textColor = hex(theme.text),
      textFont = FONT,
      textSize = FONT_SIZE,
    }
  )
  return c
end

---------------------------------------------------------------------------
-- A fix in progress
---------------------------------------------------------------------------

local Session = {}
Session.__index = Session

-- rect: the selected text from locateSelection(), or nil.
function fx.start(rect, label)
  local s = setmetatable({ t0 = now(), frames = 0 }, Session)
  if animate and rect then
    safe(function()
      s.overlay, s.overlayFrame = newOverlay(rect)
      s.overlay:show(0.12)
    end)
  end
  s.anchor = s.overlayFrame or rect or mouseAnchor()
  safe(function()
    s.bubble = newBubble(s.anchor, "busy", label or "Fixing")
    s.bubble:show(0.12)
  end)
  s.timer = every(1 / FPS, function() s:tick() end)
  return s
end

function Session:tick()
  local t = now() - self.t0
  if self.overlay then
    local W, H = self.overlayFrame.w, self.overlayFrame.h
    local band = math.max(36, math.min(180, W * 0.35))
    local period = 0.9 + math.min(W, 1200) / 900 -- longer text, slower pass
    local p = (t % period) / period
    local eased = p < 0.5 and 2 * p * p or 1 - ((-2 * p + 2) ^ 2) / 2
    self.overlay:elementAttribute(2, "frame", { x = -band + eased * (W + band), y = 0, w = band, h = H })
    local pulse = 0.35 + 0.3 * (0.5 + 0.5 * math.sin(t * 5))
    self.overlay:elementAttribute(3, "strokeColor", hex(theme.accent, pulse))
  end
  if self.bubble then
    self.frames = self.frames + 1
    local i = math.floor(self.frames / 3) % #SPINNER + 1
    self.bubble:elementAttribute(2, "text", SPINNER[i])
  end
end

-- kind: "success", "error" or "info".
function Session:finish(kind, label, hold)
  if self.done then return end
  self.done = true
  stop(self.timer)
  self.timer = nil

  local color = colorFor(kind)
  hold = hold or ((kind == "error") and 2.4 or 1.1)

  local o = self.overlay
  if o then
    safe(function()
      o:elementAttribute(2, "frame", { x = -1000, y = 0, w = 1, h = 1 }) -- stop the sweep
      local peak = (kind == "success") and 0.30 or 0.16
      tween(0.9, function(p)
        local k = p < 0.2 and 1 or 1 - (p - 0.2) / 0.8 -- hold the flash, then fade
        o:elementAttribute(1, "fillColor", hex(color, peak * k))
        o:elementAttribute(3, "strokeColor", hex(color, 0.9 * k))
      end, function() remove(o) end)
    end)
  end

  local old = self.bubble
  safe(function()
    self.bubble = newBubble(self.anchor, kind, label)
    self.bubble:show()
  end)
  remove(old)
  local b = self.bubble
  after(hold, function() remove(b, 0.3) end)
end

-- A bubble alone, for messages without a fix in progress.
function fx.toast(rect, kind, label, hold)
  safe(function()
    local b = newBubble(rect or mouseAnchor(), kind, label)
    b:show(0.12)
    after(hold or 1.6, function() remove(b, 0.3) end)
  end)
end

function fx.setup(config)
  config = config or {}
  local defaults = {
    accent = "#8B5CF6",
    shimmer = "#67E8F9",
    success = "#22C55E",
    error = "#EF4444",
    neutral = "#A1A1AA",
    bubble = "#121216",
    text = "#F4F4F5",
  }
  theme = {}
  for k, v in pairs(defaults) do theme[k] = (config.theme and config.theme[k]) or v end
  animate = config.animation ~= false
end

return fx
