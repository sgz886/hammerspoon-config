-- 加载各个模块
require("hs.ipc")    -- 防止 error: can't access Hammerspoon message port Hammerspoon

-- require("modules.doubao_speak")
require("modules.sleep_mute")
test = require("modules.test")
require("modules.unlock_watcher").start()
require("modules.assign_shortcut_to_function")

cursorSelect = require("utils.get_cursor_selected_text")

-- ⭐ 暴露全局变量，for wgesture call
wgestures = {
  moveApp = function(direction)
    require("utils.move_window_to_space").move_focused_window(direction)
  end,
  sendToChatbox = function(sessionName)
    require("modules.utils").focusChatboxAndExecute(sessionName)
  end
}
