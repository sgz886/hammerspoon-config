-- ~/.hammerspoon/modules/focus.lua
-- 应用聚焦/切换快捷键配置

local common = require("utils.common")
local window_control = require("utils.window_control")   -- ⭐ 引入工具模块
local obsidian_chatbox_management = require("modules.obsidian_chatbox_management")
local kirocli_copy_and_send_to_chatbox_translate = require("modules.kiro-cli_copy_and_send_to_chatbox_translate")

-- 单个绑定示例
-- hs.hotkey.bind({"option"}, "space", function()
--   window_control.toggleApp("Chatbox")
-- end)

-- 批量绑定（推荐做法）
local toggleAppBindings = {
  {mods = {"option"}, key = "space", app = common.CHATBOX_APP},
}

for _, b in ipairs(toggleAppBindings) do
  hs.hotkey.bind(b.mods, b.key, function()
    window_control.toggleApp(b.app)
  end)
end

-- individual bindings
hs.hotkey.bind({"ctrl", "cmd"}, "z", obsidian_chatbox_management.main)

hs.hotkey.bind({"cmd", "alt"}, "t", kirocli_copy_and_send_to_chatbox_translate.main)

