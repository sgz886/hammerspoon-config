-- 加载各个模块
require("hs.ipc")    -- 防止 error: can't access Hammerspoon message port Hammerspoon

require("modules.doubao_speak")
require("modules.sleep_mute")
test = require("modules.test")
require("modules.unlock_watcher").start()
require("modules.assign_shortcut_to_function")

cursorSelect = require("utils.get_cursor_selected_text")
cursorSelect.bindHotkey()

-- ⭐ 暴露工作流为全局变量，for wgesture call
workflow = {
  sendToApp = function(appName) 
    require("modules.utils").sendSelectionToApp(appName) 
  end,
}
-- for wgesture call
move_app = require("utils.move_app_across_spaces")
