-- ~/.hammerspoon/modules/focus.lua
-- 应用聚焦/切换快捷键配置

local utils = require("modules.utils")   -- ⭐ 引入工具模块

-- 单个绑定示例
-- hs.hotkey.bind({"option"}, "space", function()
--   utils.toggleApp("Chatbox")
-- end)

-- 批量绑定（推荐做法）
local toggleBindings = {
  {mods = {"option"}, key = "space", app = "Chatbox"},
}

for _, b in ipairs(toggleBindings) do
  hs.hotkey.bind(b.mods, b.key, function()
    utils.toggleApp(b.app)
  end)
end
