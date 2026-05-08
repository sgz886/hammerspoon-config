local utils = require("modules.utils")
hs.window.animationDuration = 0

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
    utils.moveAppWindowEnsureRunning("Chatbox",  {0,   0,   1/3, 1  })
    utils.moveAppWindowEnsureRunning("Obsidian", {1/3, 1/2, 1/3, 1/2})
    utils.focusApp("Chatbox")
    utils.focusApp("Obsidian")
    hs.alert.show("📐 布局 Z 已应用")
  else 
    hs.application.launchOrFocus("Obsidian")
  end
end)
