-- 需求：
-- 1) 按住右 Command 超过 1 秒 → 模拟双击 Option（间隔 0.2 秒）
-- 2) 在 (1) 触发之后，松开右 Command 1 秒后 → 再次模拟双击 Option（间隔 0.2 秒）

local log = require("utils.mylog").new("doubao_speak", "info")

local M = {}

-- ======== 日志 ========
-- 日志级别可选: 'debug' | 'info' | 'warning' | 'error'
-- 调试时用 'debug'，稳定后改成 'info' 即可

--| 普通版 | printf 风格 | 作用 |
--|---|---|---|
--| `log.e(...)` | `log.ef(fmt, ...)` | error |
--| `log.w(...)` | `log.wf(fmt, ...)` | warning |
--| `log.i(...)` | `log.f(fmt, ...)` 或 `log.if_(...)`* | info |
--| `log.d(...)` | `log.df(fmt, ...)` | debug |
--| `log.v(...)` | `log.vf(fmt, ...)` | verbose |

-- ======== 配置参数 ========
local FUNC_A_DELAY         = 0.1   -- 按下后多久执行函数 A
local FIRST_DOUBLE_TAP_OPTION_DELAY = 0.8   -- 按下后多久触发第一组 Option
local SECOND_DOUBLE_TAP_OPTION_DELAY = 0.1   -- 松开后多久触发第二组 Option
local FUNC_B_DELAY         = 1.5   -- 松开后多久执行函数 B
local DOUBLE_TAP_INTERVAL  = 0.18   -- 两次 Option 之间的间隔

-- ======== 状态 ========
local rightCmdDown        = false
local firstBurstFired     = false  -- 第一组 Option 是否已触发
local funcAExecuted       = false  -- 函数 A 是否已执行
local pressStartTime      = 0      -- 仅用于日志打印持续时长

-- 各种 timer
local funcATimer          = nil    -- 按下后 0.5s 执行函数 A
local longPressTimer      = nil    -- 按下后 1.0s 触发第一组
local firstBurstTimer     = nil    -- 第一组第二次 Option 的延时
local releaseOptionTimer  = nil    -- 松开后 1.0s 触发第二组
local secondBurstTimer    = nil    -- 第二组第二次 Option 的延时
local funcBTimer          = nil    -- 松开后 1.5s 执行函数 B

-- 右 Command keycode
local RIGHT_CMD_KEYCODE = 54

--输入法相关
local TARGET_INPUT_METHOD = "豆包输入法"    -- "com.bytedance.inputmethod.doubaoime"
local ENGLISH_INPUT = "U.S."
local markedInputMethod = nil

local watcher = hs.keycodes.inputSourceChanged(function()
    log.df("current method: %s", hs.keycodes.currentMethod())
end)

-- ======== 工具函数 ========
local function cancelTimer(t, name)
    if t then
        t:stop()
        log.df("  -> 取消 timer: %s", name or "?")
    end
    return nil
end

local function now()
    return hs.timer.secondsSinceEpoch()
end

-- 模拟一次 Option
local function tapOption(tag)
    log.df("    [tap] 模拟按下 Option (%s)", tag or "")
    hs.eventtap.event.newKeyEvent(hs.keycodes.map.rightalt, true):post()
    hs.timer.usleep(30000)  -- 30ms
    hs.eventtap.event.newKeyEvent(hs.keycodes.map.rightalt, false):post()
end

-- 触发一组"双击 Option"
local function doubleTapOption(burstName, timerSlotSetter)
    log.f(">>> 触发 [%s]：第 1 次 Option", burstName)
    tapOption(burstName .. " #1")

    local t = hs.timer.doAfter(DOUBLE_TAP_INTERVAL, function()
        log.f(">>> 触发 [%s]：第 2 次 Option", burstName)
        tapOption(burstName .. " #2")
        if timerSlotSetter then timerSlotSetter(nil) end
        log.df("[%s] 完成", burstName)
    end)
    if timerSlotSetter then timerSlotSetter(t) end
end

-- 取消所有待执行的 timer
local function cancelAllPending(reason)
    if funcATimer or longPressTimer or firstBurstTimer
       or releaseOptionTimer or secondBurstTimer or funcBTimer then
        log.df("[cancelAllPending] 原因: %s", reason or "")
    end
    funcATimer         = cancelTimer(funcATimer,         "funcATimer")
    longPressTimer     = cancelTimer(longPressTimer,     "longPressTimer")
    firstBurstTimer    = cancelTimer(firstBurstTimer,    "firstBurstTimer")
    releaseOptionTimer = cancelTimer(releaseOptionTimer, "releaseOptionTimer")
    secondBurstTimer   = cancelTimer(secondBurstTimer,   "secondBurstTimer")
    funcBTimer         = cancelTimer(funcBTimer,         "funcBTimer")
end

-- ======== 业务逻辑 ========
-- 得到当前输入法
local function nowInputMethod()
    return hs.keycodes.currentMethod()
end


local function debugCurrentInputState(prefix)
    log.df("[%s] currentMethod   = %s", prefix, tostring(hs.keycodes.currentMethod()))
    log.df("[%s] currentLayout   = %s", prefix, tostring(hs.keycodes.currentLayout()))
    log.df("[%s] currentSourceID = %s", prefix, tostring(hs.keycodes.currentSourceID()))
end

local function switchToTargetIME()
    markedInputMethod = nowInputMethod()

    if markedInputMethod == TARGET_INPUT_METHOD then
        log.df("当前已经是目标输入法，无需切换: %s", TARGET_INPUT_METHOD)
        return
    end
    debugCurrentInputState("before switch")

    local result = hs.keycodes.setMethod(TARGET_INPUT_METHOD)
    --local result = hs.keycodes.currentSourceID("com.bytedance.inputmethod.doubaoime.pinyin")
    log.df("切换到目标输入法: %s, 结果: %s", TARGET_INPUT_METHOD, tostring(result))
    debugCurrentInputState("after switch")
end

local function restorePreviousIME()
    if markedInputMethod == TARGET_INPUT_METHOD then
        log.df("当前已经是目标输入法，无需切换: %s", markedInputMethod)
        return
    end

    log.df("准备恢复 U.S.")

    log.i("由于第二次开始切换后，语音功能不正常，临时取消恢复成英文输入法")
    --debugCurrentInputState("before restore")
    --local result = hs.keycodes.currentSourceID("com.apple.keylayout.US")
    --local result = hs.keycodes.setLayout(ENGLISH_INPUT)
    --log.df("恢复 %s , 结果: %s", ENGLISH_INPUT, tostring(result))
    --debugCurrentInputState("after restore")
end

-- ======== 业务函数占位 ========
local function functionA()
    log.f(">>> 执行 [函数 A]")
end
local function functionB()
    log.f(">>> 执行 [函数 B]")
end

-- ======== 事件监听 ========

-- flagsChanged：监听右 Cmd 的按下/松开
local flagsWatcher = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(event)
    if event:getKeyCode() ~= RIGHT_CMD_KEYCODE then
        return false
    end

    local flags = event:getFlags()
    if flags.cmd then
        -- —— 右 Cmd 按下 ——
        pressStartTime  = now()
        rightCmdDown    = true
        firstBurstFired = false
        funcAExecuted   = false
        log.i("=== 右 Cmd 按下 ===")
        cancelAllPending("新一轮按下，清理旧 timer")

        -- 安排 FUNC_A_DELAY 后执行函数 A
        log.df("安排 funcATimer：%.2f 秒后执行函数 A", FUNC_A_DELAY)
        funcATimer = hs.timer.doAfter(FUNC_A_DELAY, function()
            funcATimer = nil
            log.df("funcATimer 到期。rightCmdDown=%s",  tostring(rightCmdDown))
            if rightCmdDown  then
                funcAExecuted = true
                functionA()
                switchToTargetIME()
            else
                log.i("条件不满足，跳过函数 A")
            end
        end)

        -- 安排 LONG_PRESS_THRESHOLD 后触发第一组 Option
        log.df("安排 longPressTimer：%.2f 秒后触发第一组", FIRST_DOUBLE_TAP_OPTION_DELAY)
        longPressTimer = hs.timer.doAfter(FIRST_DOUBLE_TAP_OPTION_DELAY, function()
            longPressTimer = nil
            log.df("longPressTimer 到期。rightCmdDown=%s", tostring(rightCmdDown))
            if rightCmdDown then
                firstBurstFired = true
                doubleTapOption("第一组", function(t) firstBurstTimer = t end)
            else
                log.i("长按条件不满足，跳过第一组")
            end
        end)
    else
        -- —— 右 Cmd 松开 ——
        local held = now() - pressStartTime
        rightCmdDown = false
        log.i(string.format("=== 右 Cmd 松开（按住 %.3f 秒）===", held))

        -- 松开时，若按下阶段的 timer 还没到期，全部取消
        if funcATimer then
            funcATimer = cancelTimer(funcATimer, "funcATimer(提前松开)")
        end
        if longPressTimer then
            log.df("还没到 %.2f 秒就松开了，取消第一组", FIRST_DOUBLE_TAP_OPTION_DELAY)
            longPressTimer = cancelTimer(longPressTimer, "longPressTimer")
        end

        -- 安排第二组 Option：前提是第一组已经触发过
        if firstBurstFired then
            log.df("第一组已触发过，安排 releaseOptionTimer：%.2f 秒后触发第二组", SECOND_DOUBLE_TAP_OPTION_DELAY)
            releaseOptionTimer = hs.timer.doAfter(SECOND_DOUBLE_TAP_OPTION_DELAY, function()
                releaseOptionTimer = nil
                log.df("releaseOptionTimer 到期，开始触发第二组")
                doubleTapOption("第二组", function(t) secondBurstTimer = t end)
            end)
        else
            log.df("不安排第二组 (firstBurstFired=%s)",  tostring(firstBurstFired))
        end
        -- 安排函数 B：前提是函数 A 执行过
        if funcAExecuted  then
            log.df("安排 funcBTimer：%.2f 秒后执行函数 B", FUNC_B_DELAY)
            funcBTimer = hs.timer.doAfter(FUNC_B_DELAY, function()
                funcBTimer = nil
                log.df("funcBTimer 到期，执行函数 B")
                functionB()
                restorePreviousIME()
            end)
        else
            log.df("不安排函数 B (funcAExecuted=%s)",  tostring(funcAExecuted))
        end
    end
    return false
end)

-- ======== 生命周期 ========
function M.start()
    flagsWatcher:start()
    log.i("doubao_speak 已启动")
end

function M.stop()
    flagsWatcher:stop()
    keyWatcher:stop()
    cancelAllPending("doubao_speak 停止")
    log.i("doubao_speak 已停止")
end

-- 方便运行时调整日志级别：在 console 里执行
-- require("modules.right_cmd_long_press").setLogLevel("info")
function M.setLogLevel(level)
    log.setLogLevel(level)
    log.i("日志级别已切换为: " .. level)
end

M.start()

return M
