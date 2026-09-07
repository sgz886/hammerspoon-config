-- ─────────────────────────────────────────────────────────
-- modules/mwinit.lua
-- 自动执行 mwinit 登录流程
-- ─────────────────────────────────────────────────────────

local M = {}

-- 脚本路径
-- ⚠️ 必须是绝对路径：iTerm 的 command 参数不经过 shell（`~` 不会被展开），
--    而且 session 的 cwd 由 profile 的 Working Directory 决定，不是 .hammerspoon
local SCRIPT_PATH = hs.configdir .. "/modules/mwinit-auto.sh"

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

    -- 2. 构造 AppleScript
    --    ⭐ `command` 参数：脚本直接作为 session 进程启动，不经过 login shell
    --       → 不用白等 zsh/oh-my-zsh/p10k 初始化（实测省 0.8~1.3s），
    --         也不会打出 "Last login" 和一行重复回显的脚本路径
    --       （旧写法是 `write text "exec ..."`，那是模拟键盘输入，
    --         文本得排队等 zsh 加载完读 stdin 才执行，1 秒延迟就来自这里）
    --    ⚠️ SCRIPT_PATH 里不能有空格 —— iTerm 会对 command 做 argv 拆分
    --
    --    `launch` 而不是 `activate`：launch 发的是 no-op Apple event，
    --    不触发 open-untitled，所以冷启动不会多冒一个空窗口；
    --    对已在运行的 iTerm 是 no-op —— 一句话覆盖「在跑 / 没在跑」两种情况
    local applescript = string.format([[
        tell application "iTerm"
            launch
            create window with default profile command "%s"
        end tell
    ]], SCRIPT_PATH)
    local ok, result = hs.osascript.applescript(applescript)
    if not ok then
        hs.alert.show("❌ 启动 iTerm2 失败")
        print("AppleScript error:", hs.inspect(result))
        return
    end

    -- 3. 弹提示让用户按 YubiKey
    hs.alert.show("👆开始 mwinit login", {
        textSize = 36,
        radius = 12,
    }, 3)  -- 显示 3 秒
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
