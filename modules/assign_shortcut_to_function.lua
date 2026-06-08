-- ~/.hammerspoon/modules/focus.lua
-- 应用聚焦/切换快捷键配置

local utils = require("modules.utils")   -- ⭐ 引入工具模块
local obsidian_chatbox_management = require("modules.obsidian_chatbox_management")

-- 单个绑定示例
-- hs.hotkey.bind({"option"}, "space", function()
--   utils.toggleApp("Chatbox")
-- end)

-- 批量绑定（推荐做法）
local toggleAppBindings = {
  {mods = {"option"}, key = "space", app = "Chatbox"},
}

for _, b in ipairs(toggleAppBindings) do
  hs.hotkey.bind(b.mods, b.key, function()
    utils.toggleApp(b.app)
  end)
end

-- individual bindings
hs.hotkey.bind({"ctrl", "shift", "cmd"}, "z", obsidian_chatbox_management.main)
