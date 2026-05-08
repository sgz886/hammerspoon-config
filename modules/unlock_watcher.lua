-- ─────────────────────────────────────────────────────────
-- modules/unlock_watcher.lua
-- 监听屏幕解锁事件，触发每日任务
-- ─────────────────────────────────────────────────────────

local mwinit = require("modules.mwinit")

local M = {}

-- 保存 watcher 引用到 module 级变量
-- 不这么做的话会被 GC，watcher 就失效了！
local watcher = nil

function M.start()
    if watcher then
        print("[unlock_watcher] already running")
        return
    end

    watcher = hs.caffeinate.watcher.new(function(event)
        -- 事件 ID 转换成可读名字（调试用）
        local eventName = "unknown"
        for name, id in pairs(hs.caffeinate.watcher) do
            if id == event then
                eventName = name
                break
            end
        end
        print(string.format("[unlock_watcher] event: %s (%d)",
            eventName, event))

        if event == hs.caffeinate.watcher.screensDidUnlock then
            -- 延迟一点再跑，让系统稳定
            hs.timer.doAfter(5, function()
                mwinit.runOncePerDay()
            end)
        end
    end)

    watcher:start()
    print("[unlock_watcher] started")
end

function M.stop()
    if watcher then
        watcher:stop()
        watcher = nil
        print("[unlock_watcher] stopped")
    end
end

return M
