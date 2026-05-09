-- ─────────────────────────────────────────────────────────
-- modules/mwinit.lua
-- 自动执行 mwinit 登录流程
-- ─────────────────────────────────────────────────────────

local M = {}

-- 脚本路径（展开 ~ 到真实 home 目录）
local SCRIPT_PATH = os.getenv("HOME") .. "/bin/mwinit-auto.sh"

-- hs.settings 里存储"上次自动触发日期"的 key
local SETTINGS_KEY = "mwinit.lastAutoRunDate"

--- 核心：在 iTerm 里跑 mwinit-auto.sh
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
                delay 1
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

--- 每日首次调用：如果今天还没跑过，就跑；否则跳过
--- @return boolean 是否真的执行了
function M.runOncePerDay()
    local today = os.date("%Y-%m-%d")
    local lastRun = hs.settings.get(SETTINGS_KEY)
    print(string.format("[mwinit] runOncePerDay: today=%s lastRun=%s",
        today, tostring(lastRun)))
    if lastRun == today then
        print("[mwinit] 今天已经自动运行过了，跳过")
        return false
    end
    -- 先记录日期再执行 —— 即使执行失败，今天也不再重试
    -- （避免失败时反复弹窗打扰用户；想要重试就手动调用 M.run()）
    hs.settings.set(SETTINGS_KEY, today)
    print("[mwinit] 今日首次解锁，触发 mwinit")
    M.mwinit()
    return true
end

--- 调试用：清除"今日已运行"标记，让下次解锁重新触发
function M.resetDailyFlag()
    hs.settings.clear(SETTINGS_KEY)
    print("[mwinit] 已清除每日标记")
end


return M
