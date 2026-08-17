-- ─────────────────────────────────────────────────────────
-- modules/mwinit.lua
-- 自动执行 mwinit 登录流程
-- ─────────────────────────────────────────────────────────

local M = {}

-- 脚本路径（展开 ~ 到真实 home 目录）
local SCRIPT_PATH = os.getenv("HOME") .. "/.hammerspoon/modules/mwinit-auto.sh"

-- hs.settings 里存储"上次成功登录日期"的 key
-- ⭐ 只有 mwinit-auto.sh 走完 interact 且 mwinit 成功退出后，
--    脚本才会用 `hs -c` 回调 M.markSuccess() 写这个 key
local SETTINGS_KEY = "mwinit.lastAutoRunDate"

-- 上一次启动脚本的时间戳（module 级变量，防 GC / reload 即清零）
-- 用来避免 60s 窗口内重复解锁、或开机补偿 timer 叠加时开出多个 iTerm 窗口
-- （两个 expect 抢同一个 tty 会互相打断）
local pendingSince = nil
local PENDING_TIMEOUT = 300  -- 秒；超过就认为上一次已经死了，可以再开

--- 核心：在 iTerm 里跑
function M.mwinit()
    -- 1. 先检查脚本是否存在
    local f = io.open(SCRIPT_PATH, "r")
    if not f then
        hs.alert.show("❌ 找不到脚本: " .. SCRIPT_PATH)
        print(string.format("  找不到脚本 %s", SCRIPT_PATH))
        return
    end
    f:close()

    -- 2. 判断 iTerm2 是否已在运行
    --    hs.application.get 对已运行的 app 返回 app 对象，否则 nil
    local iterm = hs.application.get("iTerm2") or hs.application.get("iTerm")
    local wasRunning = iterm ~= nil

    -- 3. 构造 AppleScript
    --    - 已运行：create window with default profile → 在新窗口执行
    --    - 未运行：直接 activate 会自动开一个窗口，再 write 即可
    --    iTerm2 的 AppleScript 模型：application → window → tab → session
    --    `write text` 是发送到 current session 的命令
    local applescript
    print("start")
    print(string.format("iterm was Running = %s", wasRunning))
    if wasRunning then
        applescript = string.format([[
            tell application "iTerm"
                create window with default profile
                tell current session of current window
                    write text "exec %s"
                end tell
            end tell
        ]], SCRIPT_PATH)
    else
        -- 冷启动：activate 会自动创建一个窗口，不需要再 create
        applescript = string.format([[
            tell application "iTerm"
                activate
                repeat until (count of windows) > 0
                    delay 0.1
                end repeat
                tell current session of current window
                    write text "exec %s"
                end tell
            end tell
        ]], SCRIPT_PATH)
    end
    local ok, result = hs.osascript.applescript(applescript)
    if not ok then
        hs.alert.show("❌ 启动 iTerm2 失败")
        print("AppleScript error:", hs.inspect(result))
        return
    end

    -- 4. 弹提示让用户按 YubiKey
    hs.alert.show("👆 请触摸 USB 安全密钥", {
        textSize = 36,
        radius = 12,
    }, 5)  -- 显示 5 秒
end

--- 由 mwinit-auto.sh 在成功后通过 `hs -c` 回调：
---   hs -c 'require("modules.mwinit").markSuccess()'
--- 这是唯一写入"今天已完成"标记的地方
function M.markSuccess()
    local today = os.date("%Y-%m-%d")
    hs.settings.set(SETTINGS_KEY, today)
    pendingSince = nil
    print(string.format("[mwinit] ✅ 登录成功，已标记 %s", today))
    hs.alert.show("✅ mwinit 登录成功")
end

--- 每日调用：今天还没成功登录过就跑；已成功或正在进行中则跳过
--- 注意：失败/取消不会写标记，所以今天下次解锁还会再试
--- @return boolean 是否真的执行了
function M.runOncePerDay()
    local today = os.date("%Y-%m-%d")
    local lastRun = hs.settings.get(SETTINGS_KEY)
    print(string.format("[mwinit] runOncePerDay: today=%s lastRun=%s",
        today, tostring(lastRun)))
    if lastRun == today then
        print("[mwinit] 今天已经成功登录过了，跳过")
        return false
    end

    -- 上一次还在进行中（用户可能正盯着 iTerm 等着摸 key）→ 不要再开一个窗口
    if pendingSince and (os.time() - pendingSince) < PENDING_TIMEOUT then
        print(string.format("[mwinit] 上一次 mwinit 还在进行中（%d 秒前启动），跳过",
            os.time() - pendingSince))
        return false
    end

    -- ⭐ 这里不写日期标记！只有脚本成功后回调 M.markSuccess() 才写
    pendingSince = os.time()
    print("[mwinit] 今天还没成功登录，触发 mwinit")
    M.mwinit()
    return true
end

--- 调试用：清除"今日已完成"标记，让下次解锁重新触发
function M.resetDailyFlag()
    hs.settings.clear(SETTINGS_KEY)
    pendingSince = nil
    print("[mwinit] 已清除每日标记")
end

--- 调试用：打印当前状态
function M.status()
    print(string.format("[mwinit] today=%s lastRun=%s pendingSince=%s",
        os.date("%Y-%m-%d"),
        tostring(hs.settings.get(SETTINGS_KEY)),
        pendingSince and string.format("%d 秒前", os.time() - pendingSince) or "nil"))
end


return M
