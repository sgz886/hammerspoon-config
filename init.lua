-- 加载各个模块
require("hs.ipc")    -- 防止 error: can't access Hammerspoon message port Hammerspoon

-- require("modules.doubao_speak")
require("modules.sleep_mute")
test = require("modules.test")
require("modules.unlock_watcher").start()
require("modules.assign_shortcut_to_function")

cursorSelect = require("utils.get_cursor_selected_text")

-- 挪出 ipc 回调的 timer，存起来防 GC（见 unlock_watcher.lua 的同类注释）
local ipcDeferred, ipcDeferredSeq = {}, 0

-- 把 fn 挪到下一拍执行，让 `hs -c` 的 ipc 回调当场返回
-- ⚠️ 外部 App 用 `hs -c` 调进来时，函数是在 hs.ipc 的回调里同步跑的：几次 yabai 查询（每次 ~40ms）
--    加上一堆 print 期间，hs 客户端一直挂着；而每个 print 都会被 hs.ipc 同步 sendMessage 给所有
--    活着的客户端，等回复时转 runloop，BTT 连发的下一条请求就在里面重入 —— 某个客户端的端口
--    被 delete 掉、外层还在用它，Hammerspoon 整个崩溃（2026-09-23 / 09-26 的 5 份崩溃报告）。
--    挪到 timer 里之后客户端几毫秒就拿到回复、注销走人，后面的 yabai / print 就不在 ipc 里了。
-- ⭐ 连发时这里会排上几个 timer，但它们一进去就被 window_control 的连按保护静默丢掉，不会真的执行。
-- ⭐ 调用方（BTT 等）请用 `hs -q -c`：quiet 模式下 hs.ipc 不把 print 转发给这个客户端
local function deferOutOfIpc(fn, ...)
  local args = table.pack(...)
  ipcDeferredSeq = ipcDeferredSeq + 1
  local key = ipcDeferredSeq
  ipcDeferred[key] = hs.timer.doAfter(0, function()
    ipcDeferred[key] = nil
    fn(table.unpack(args, 1, args.n))
  end)
end

-- ⭐ 暴露全局变量，for wgesture call
wgestures = {
  moveApp = function(direction)
    deferOutOfIpc(require("utils.window_control").move_focused_window_with_direction, direction)
  end,
  sendToChatbox = function(sessionName)
    deferOutOfIpc(require("utils.window_control").copyToChatbox, sessionName)
  end
}

btt = {
  moveSpaceAndApp = function(direction)
    deferOutOfIpc(require("utils.window_control").swap_space_and_app, direction)
  end,
  changeCurrentSpace = function(direction, method)
    deferOutOfIpc(require("utils.window_control").switch_current_space, direction, method)
  end,
}
