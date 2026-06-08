local utils = require("modules.utils")
local cursorSelection = require("utils.get_cursor_selected_text")
local focus_app_to_current_space = require("utils.move_app_across_spaces")

local function copyTextFromObsidianPasteToChatBox()
  local text = cursorSelection.getSelectedText()
  if text and text ~= "" then
    hs.eventtap.keyStroke({"cmd"}, "c")
    hs.timer.doAfter(1.2, function()
      hs.eventtap.keyStroke({"cmd"}, "v")
    end)
    hs.timer.doAfter(1.4, function()
      hs.eventtap.keyStroke({"cmd"}, "return")
    end)
  end
end

local function setAppLayoutAndFocus(appName, unitRect)
  utils.moveAppWindowEnsureRunning(appName, unitRect)
  utils.focusApp(appName)
end

local function layoutObsidianAndChatbox(name)
  setAppLayoutAndFocus("Obsidian", { 1 / 3, 1 / 2, 1 / 3, 1 / 2 })

  if name == "Obsidian" then
    copyTextFromObsidianPasteToChatBox()
  end

  hs.timer.doAfter(0.3, function()
    setAppLayoutAndFocus("Chatbox", { 0, 0, 1 / 3, 1 })
  end)
  hs.timer.doAfter(0.4, function()
    hs.eventtap.keyStroke({ "cmd" }, "1")
  end)
  hs.timer.doAfter(0.6, function()
    hs.eventtap.keyStroke({ "cmd" }, "i")
  end)
  hs.alert.show("📐 布局 Obsidian & Chatbox 已应用")
end

local M = {}
function M.main()
  local app = hs.application.frontmostApplication()
  local name = app and app:name() or ""
  if name == "Chatbox" or name == "Obsidian" then
    layoutObsidianAndChatbox(name)
  else
    focus_app_to_current_space.focus_app_to_current_space("Obsidian")
  end
end






return M