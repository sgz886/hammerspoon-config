-- ─────────────────────────────────────────────────────────
-- modules/unlock_watcher.lua
-- 监听屏幕解锁事件，触发每日任务
-- ─────────────────────────────────────────────────────────

local mwinit = require("modules.mwinit")
local LOGIN_MWINIT_DELAY = 60

local M = {}

-- 所有事件都走这里
-- call in console
-- require("modules.unlock_watcher").handleEvent(hs.caffeinate.watcher.screensDidUnlock)
function M.handleEvent(event)
    -- 输出所有的MacOS events
    -- event 默认是 ID, 获取name（调试用）
    local eventName = "unknown"
    for name, id in pairs(hs.caffeinate.watcher) do
        if id == event then
            eventName = name
            break
        end
    end
    print(string.format("[unlock_watcher] event: %s (%d)", eventName, event))

    -- screensDidUnlock, 执行mwinit login
    if event == hs.caffeinate.watcher.screensDidUnlock then
        print(string.format("screen unlocked, will triger mwinit login in %s seconds", LOGIN_MWINIT_DELAY))
        hs.timer.doAfter(LOGIN_MWINIT_DELAY, function()
            mwinit.runOncePerDay()
        end)
    end
end

-- 保存 watcher 引用到 module 级变量
-- 不这么做的话会被 GC，watcher 就失效了！
local watcher = nil

function M.start()
    if watcher then
        print("[unlock_watcher] already running")
        return
    end
    watcher = hs.caffeinate.watcher.new(M.handleEvent)
    watcher:start()
    print("[unlock_watcher] started")

    -- 启动时也跑一次：处理开机后 Hammerspoon 才启动、错过 unlock 事件的情况
    -- runOncePerDay 自带"今天已跑过就跳过"，所以重复触发是安全的
    print("[unlock_watcher] starting unlock_watcher.lua, will run mwinit, in case of boot system in the morning.")
    print(string.format("run mwinit proactively in %s seconds", LOGIN_MWINIT_DELAY))
    hs.timer.doAfter(LOGIN_MWINIT_DELAY, function()
        mwinit.runOncePerDay()
    end)
end

function M.stop()
    if watcher then
        watcher:stop()
        watcher = nil
        print("[unlock_watcher] stopped")
    end
end

return M
