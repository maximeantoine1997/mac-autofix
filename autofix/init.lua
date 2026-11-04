-- autofix
-- Double-tap a modifier key to fix spelling and grammar in the selected text, in place.
-- Works in any app where Cmd+C and Cmd+V work on a selection.
-- Settings: autofix/config.lua. Visuals: autofix/fx.lua.

local config = require("autofix.config")
local fx = require("autofix.fx")
fx.setup(config)

local M = {}

local TRIGGER = config.triggerKey or "ctrl"
local WINDOW = config.doubleTapWindow or 0.35
local MODS = { "cmd", "alt", "shift", "ctrl" }

-- The first time, macOS asks you to give Hammerspoon Accessibility access.
if not hs.accessibilityState() then hs.accessibilityState(true) end

---------------------------------------------------------------------------
-- API key and provider
---------------------------------------------------------------------------

local function keychainRead(service)
  local out, ok = hs.execute("/usr/bin/security find-generic-password -s '" .. service .. "' -w 2>/dev/null")
  if not ok or not out then return nil end
  out = out:gsub("%s+$", "")
  if out == "" then return nil end
  return out
end

local function findProvider()
  for _, p in ipairs(config.providers or {}) do
    local key = keychainRead(p.keychain)
    if key then return p, key end
  end
  return nil, nil
end

local provider, apiKey = findProvider()
if provider then
  print("autofix: ready, using " .. provider.name .. " (" .. provider.model .. ")")
else
  print("autofix: no API key in the Keychain. Run install.sh.")
end

local function headersFor(p, key)
  local h = {
    ["anthropic-version"] = "2023-06-01",
    ["content-type"] = "application/json",
  }
  if p.auth == "bearer" then
    h["authorization"] = "Bearer " .. key
  else
    h["x-api-key"] = key
  end
  return h
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

-- Identifies the app and window that had focus, so we never paste into the wrong place.
local function focusKey()
  local app = hs.application.frontmostApplication()
  local win = hs.window.focusedWindow()
  return tostring(app and app:pid() or 0) .. ":" .. tostring(win and win:id() or 0)
end

-- Put the original clipboard back after the paste.
local function restoreClipboard(saved)
  hs.timer.doAfter(0.5, function()
    if saved and next(saved) then
      hs.pasteboard.writeAllData(saved)
    else
      hs.pasteboard.clearContents()
    end
  end)
end

local function firstText(content)
  if type(content) ~= "table" then return nil end
  for _, block in ipairs(content) do
    if block.type == "text" and block.text then return block.text end
  end
  return nil
end

local function errorLabel(status)
  if not status or status <= 0 then return "No connection" end
  if status == 401 or status == 403 then return "API key rejected" end
  if status == 429 then return "Rate limited, try again" end
  return "Failed (" .. status .. ")"
end

---------------------------------------------------------------------------
-- The fix
---------------------------------------------------------------------------

local busy = false

local function fixSelection()
  if busy then return end
  if not provider then
    provider, apiKey = findProvider()
    if not provider then
      fx.toast(nil, "error", "No API key. Run install.sh", 3)
      return
    end
  end
  busy = true

  local rect = fx.locateSelection() -- before the copy, while the selection is sure to exist
  local startFocus = focusKey()
  local saved = hs.pasteboard.readAllData()
  local before = hs.pasteboard.changeCount()
  hs.eventtap.keyStroke({ "cmd" }, "c", 0)

  local polls = 0
  hs.timer.waitUntil(
    function()
      polls = polls + 1
      return hs.pasteboard.changeCount() ~= before or polls > 20
    end,
    function()
      if hs.pasteboard.changeCount() == before then
        busy = false
        fx.toast(rect, "info", "Nothing selected")
        return
      end

      local text = hs.pasteboard.getContents()
      if not text or text:match("^%s*$") then
        busy = false
        restoreClipboard(saved)
        return
      end

      -- Models tend to trim surrounding whitespace, so we keep it aside.
      local lead, core, trail = text:match("^(%s*)(.-)(%s*)$")
      local session = fx.start(rect, "Fixing")

      local body = hs.json.encode({
        model = provider.model,
        max_tokens = 8192,
        system = config.prompt,
        messages = { { role = "user", content = core } },
      })

      hs.http.asyncPost(provider.url, body, headersFor(provider, apiKey), function(status, resp)
        busy = false

        local ok, data = pcall(hs.json.decode, resp or "")
        local out = ok and type(data) == "table" and firstText(data.content)
        if status ~= 200 or not out then
          print("autofix: request failed, HTTP " .. tostring(status) .. ": " .. tostring(resp):sub(1, 400))
          session:finish("error", errorLabel(status))
          restoreClipboard(saved)
          return
        end

        local fixed = lead .. out .. trail
        if fixed == text then
          session:finish("info", "Nothing to fix")
          restoreClipboard(saved)
          return
        end

        hs.pasteboard.setContents(fixed)
        if focusKey() ~= startFocus then
          -- You changed windows while the model worked. Keep the result on the clipboard.
          session:finish("info", "Changed window: fixed text copied", 2.5)
          return
        end
        hs.eventtap.keyStroke({ "cmd" }, "v", 0)
        session:finish("success", "Fixed")
        restoreClipboard(saved)
      end)
    end,
    0.025
  )
end

---------------------------------------------------------------------------
-- Double-tap detection
---------------------------------------------------------------------------

local function otherModsDown(f)
  for _, m in ipairs(MODS) do
    if m ~= TRIGGER and f[m] then return true end
  end
  return false
end

local types = hs.eventtap.event.types
local triggerDown = false
local triggerUsed = false -- the key was part of a shortcut or a click, so it is not a tap
local lastTapAt = 0

M.tap = hs.eventtap.new(
  { types.flagsChanged, types.keyDown, types.leftMouseDown, types.rightMouseDown },
  function(e)
    if e:getType() ~= types.flagsChanged then
      triggerUsed = true
      lastTapAt = 0
      return false
    end

    local f = e:getFlags()
    local others = otherModsDown(f)

    if f[TRIGGER] and not others and not triggerDown then
      triggerDown = true
      triggerUsed = false
    elseif not f[TRIGGER] and triggerDown then
      triggerDown = false
      if not triggerUsed and not others then
        local t = hs.timer.secondsSinceEpoch()
        if t - lastTapAt < WINDOW then
          lastTapAt = 0
          hs.timer.doAfter(0.05, fixSelection)
        else
          lastTapAt = t
        end
      end
    elseif others then
      triggerUsed = true
      lastTapAt = 0
    end
    return false
  end
)
M.tap:start()

-- macOS sometimes disables event taps after a slow callback. Turn it back on.
M.watchdog = hs.timer.doEvery(5, function()
  if not M.tap:isEnabled() then M.tap:start() end
end)

M.fix = fixSelection
M.fx = fx
return M
