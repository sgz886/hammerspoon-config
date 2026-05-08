-- 加载各个模块
require("hs.ipc")    -- 防止 error: can't access Hammerspoon message port Hammerspoon

require("modules.doubao_speak")
require("modules.sleep_mute")
require("modules.toggle_apps")
require("modules.layouts")
test = require("modules.test")
require("modules.unlock_watcher").start()

-- ⭐ 暴露工作流为全局变量，方便 CLI 调用
workflow = {
  sendToApp = function(appName) 
    require("modules.utils").sendSelectionToApp(appName) 
  end,
}

-- function reloadConfig(files)
--   local doReload = false
--   for _, file in pairs(files) do
--     if file:sub(-4) == ".lua" then
--       doReload = true
--       break
--     end
--   end
--   if doReload then
--     hs.reload()
--   end
-- end
-- hs.pathwatcher.new(os.getenv("HOME") .. "/.hammerspoon/", reloadConfig):start()
-- hs.alert.show("当 .lua 文件变化时,Hammerspoon重新加载 ✅")
