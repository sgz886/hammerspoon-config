local utils = require("modules.utils")
local cursorSelection = require("utils.get_cursor_selected_text")
local move_window = require("utils.move_window_to_space")

local function copyTextFromObsidianPasteToChatbox()
  local text = cursorSelection.getSelectedText()
  if text and text ~= "" then
    utils.sendSelectionToChatboxSession1("text_polish")
  end
end

local function setAppLayoutAndFocus(appName, unitRect)
  utils.moveAppWindowEnsureRunning(appName, unitRect)
  utils.focusApp(appName)
end
local function setAppLayout(appName, unitRect)
  utils.moveAppWindowEnsureRunning(appName, unitRect)
end

local M = {}
function M.main()
  local app = hs.application.frontmostApplication()
  local name = app and app:name() or ""

  if name ~= "Chatbox" and name ~= "Obsidian" then
    move_window.focus_app("Obsidian")
  elseif name == "Chatbox" then
    utils.sequence({
      {0,  function() setAppLayout("Chatbox", { 0, 0, 1 / 3, 1 }) end},
      {0.1,  function() move_window.focus_app("Obsidian") end},
      {0.4, function() setAppLayout("Obsidian", { 1 / 3, 1 / 2, 1 / 3, 1 / 2 }) end}
    })
  else
    -- name == Obsidian 的情况
    utils.sequence({
      --{0, function() copySelectedTextFromObsidianToClipboard() end},
      {0, function() hs.eventtap.keyStroke({"cmd"}, "c") end},
      {0.1, function() setAppLayout("Obsidian", { 1 / 3, 1 / 2, 1 / 3, 1 / 2 }) end},
      {0.1,  function() utils.sendSelectionToChatboxSession1("text_polish") end},
      {0.5,  function() setAppLayout("Chatbox", { 0, 0, 1 / 3, 1 }) end},
    })
  end
end

return M