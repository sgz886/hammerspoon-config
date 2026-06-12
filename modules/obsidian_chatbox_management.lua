local utils = require("modules.utils")
local cursorSelection = require("utils.get_cursor_selected_text")
local focus_app_to_current_space = require("utils.move_app_across_spaces")

local function copyTextFromObsidianPasteToChatBox()
  local text = cursorSelection.getSelectedText()
  if text and text ~= "" then
    utils.sendSelectionToChatBoxSession("text_polish")
  end
end

local function setAppLayoutAndFocus(appName, unitRect)
  utils.moveAppWindowEnsureRunning(appName, unitRect)
  utils.focusApp(appName)
end

local M = {}
function M.main()
  local app = hs.application.frontmostApplication()
  local name = app and app:name() or ""

  if name ~= "Chatbox" and name ~= "Obsidian" then
    focus_app_to_current_space.focus_app_to_current_space("Obsidian")
  elseif name == "Chatbox" then
    utils.sequence({
      {0,  function() setAppLayoutAndFocus("Chatbox", { 0, 0, 1 / 3, 1 }) end},
      {0.3,  function() focus_app_to_current_space.focus_app_to_current_space("Obsidian") end},
      {0.5, function() setAppLayoutAndFocus("Obsidian", { 1 / 3, 1 / 2, 1 / 3, 1 / 2 }) end}
    })
  else
    -- name == Obsidian
    utils.sequence({
      {0,  function() focus_app_to_current_space.focus_app_to_current_space("Chatbox") end},
      {0.4,  function() setAppLayoutAndFocus("Chatbox", { 0, 0, 1 / 3, 1 }) end},
      {0.4, function() setAppLayoutAndFocus("Obsidian", { 1 / 3, 1 / 2, 1 / 3, 1 / 2 }) end},
      {0.3, function() copyTextFromObsidianPasteToChatBox() end}
    })
  end
end

return M