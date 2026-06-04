local utils = require("modules.utils")
local cursorSelection = require("utils.cursor_selection")

-- ========== 单窗口布局快捷键 ==========
-- local layouts = {
--   {mods = {"option", "ctrl"},  key = "Left",  rect = {0,   0, 1/3, 1}},
-- }

-- for _, L in ipairs(layouts) do
--   hs.hotkey.bind(L.mods, L.key, function()
--     utils.moveWindow(L.rect)
--   end)
-- end

-- ========== 多应用组合布局 ==========

-- 布局 Z：App1 左 1/3 | App2 中下 1/6
hs.hotkey.bind({"ctrl", "shift", "cmd"}, "Z", function()
  local app = hs.application.frontmostApplication()
  local name = app and app:name() or ""
  if name == "Chatbox" or name == "Obsidian"   then
    utils.moveAppWindowEnsureRunning("Obsidian", {1/3, 1/2, 1/3, 1/2})
    utils.focusApp("Obsidian")

    if name == "Obsidian" then
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

    hs.timer.doAfter(0.3, function()
      utils.moveAppWindowEnsureRunning("Chatbox",  {0,   0,   1/3, 1  })
      utils.focusApp("Chatbox")
    end)
    hs.timer.doAfter(0.4, function()
      hs.eventtap.keyStroke({"cmd"}, "1")
    end)
    hs.timer.doAfter(0.6, function()
      hs.eventtap.keyStroke({"cmd"}, "i")
    end)
    hs.alert.show("📐 布局 Z 已应用")
  else
    hs.application.launchOrFocus("Obsidian")
  end
end)
