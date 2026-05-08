-- ============================================
-- Right Command -> switch IME -> double tap Left Option
-- 放到 ~/.hammerspoon/init.lua
-- 版本：保持当前可用行为，只修监听容易失效的问题
-- ============================================
local log = hs.logger.new("RightCmdIME", "debug")
local alert = hs.alert

-- 目标输入法
local TARGET_INPUT_SOURCE = "豆包输入法"
-- local TARGET_INPUT_SOURCE = "com.bytedance.inputmethod.doubaoime"

-- 右侧 Command 按下后，多久再执行双击左 Option（秒）
local OPTION_PRESS_DELAY = 0.6

-- 两次 Option 点击之间的间隔（秒）
local OPTION_DOUBLE_TAP_INTERVAL = 0.18

-- 松开右 Command 后，延迟多久恢复原输入法（秒）
local RESTORE_IME_DELAY = 1.0

-- 物理按键 keycode
local KEYCODE_RIGHT_CMD = 54

-- 状态变量
local previousInputSource = nil
local rightCmdIsDown = false
local optionPressTimer = nil
local restoreImeTimer = nil

local function nowSource()
    local method = hs.keycodes.currentMethod()
    if method ~= nil then
        return {
            kind = "method",
            value = method
        }
    end

    local layout = hs.keycodes.currentLayout()
    if layout ~= nil then
        return {
            kind = "layout",
            value = layout
        }
    end

    return nil
end

local function debugCurrentInputState(prefix)
    log.df("[%s] currentMethod   = %s", prefix, tostring(hs.keycodes.currentMethod()))
    log.df("[%s] currentLayout   = %s", prefix, tostring(hs.keycodes.currentLayout()))
    log.df("[%s] currentSourceID = %s", prefix, tostring(hs.keycodes.currentSourceID()))
end

local function tapLeftOptionOnce()
    hs.eventtap.event.newKeyEvent(hs.keycodes.map.alt, true):post()
    hs.eventtap.event.newKeyEvent(hs.keycodes.map.alt, false):post()
end

local function doubleTapLeftOption()
    log.df("开始模拟双击左 Option")
    tapLeftOptionOnce()

    hs.timer.doAfter(OPTION_DOUBLE_TAP_INTERVAL, function()
        tapLeftOptionOnce()
        log.df("已完成双击左 Option")
    end)
end

local function cancelOptionTimer()
    if optionPressTimer then
        optionPressTimer:stop()
        optionPressTimer = nil
        log.df("已取消待执行的 Option 定时器")
    end
end

local function cancelRestoreImeTimer()
    if restoreImeTimer then
        restoreImeTimer:stop()
        restoreImeTimer = nil
        log.df("已取消待执行的输入法恢复定时器")
    end
end

local function switchToTargetIME()
    local current = nowSource()
    previousInputSource = current

    -- 如果有输入法 XD
    if current == nil then
        log.df("无法识别当前输入来源，跳过记录")
    end

    debugCurrentInputState("before switch")

    if current ~= nil and current.kind == "method" and current.value == TARGET_INPUT_SOURCE then
        log.df("当前已经是目标输入法，无需切换: %s", TARGET_INPUT_SOURCE)
        return
    end

    local ok = hs.keycodes.setMethod(TARGET_INPUT_SOURCE)
    log.df("切换到目标输入法: %s, 结果: %s", TARGET_INPUT_SOURCE, tostring(ok))

    -- debugCurrentInputState("after switch")
end

local function restorePreviousIME()
    if not previousInputSource then
        log.df("没有记录到之前的输入来源，跳过恢复")
        return
    end

    local old = previousInputSource

    log.df("准备恢复之前输入来源: kind=%s, value=%s", tostring(old.kind), tostring(old.value))

    if old ~= nil and old.value == TARGET_INPUT_SOURCE then
    log.df("当前已经是目标输入法，无需切换: %s", TARGET_INPUT_SOURCE)
        return
    end

    -- debugCurrentInputState("before restore")
    local ok = false

    if old.kind == "method" then
        ok = hs.keycodes.setMethod(old.value)
        log.df("恢复之前输入法 method: %s, 结果: %s", tostring(old.value), tostring(ok))

    elseif old.kind == "layout" then
        ok = hs.keycodes.setLayout(old.value)
        log.df("恢复之前键盘布局 layout: %s, 结果: %s", tostring(old.value), tostring(ok))
    else
        -- 被玩坏了才可能走到这里，让我看看是哪个小伙伴这么坏！！
        log.df("未知的输入来源类型，无法恢复: %s", hs.inspect(old))
    end

    -- debugCurrentInputState("after restore")
    previousInputSource = nil
end

local function scheduleRestorePreviousIME()
    cancelRestoreImeTimer()

    restoreImeTimer = hs.timer.doAfter(RESTORE_IME_DELAY, function()
        restoreImeTimer = nil
        log.df("延迟 %.2f 秒后，开始恢复之前输入法", RESTORE_IME_DELAY)
        restorePreviousIME()
    end)

    log.df("已安排 %.2f 秒后恢复之前输入法", RESTORE_IME_DELAY)
end

local function onRightCmdDown()
    if rightCmdIsDown then
        log.df("右 Command 已处于按下状态，忽略重复事件")
        return
    end

    rightCmdIsDown = true
    log.df("检测到右 Command 按下")

    -- 新一轮开始时，取消上一次尚未执行的恢复动作
    cancelRestoreImeTimer()

    switchToTargetIME()

    cancelOptionTimer()
    optionPressTimer = hs.timer.doAfter(OPTION_PRESS_DELAY, function()
        optionPressTimer = nil

        if rightCmdIsDown then
            log.df("延迟结束，右 Command 仍按着，准备双击左 Option")
            doubleTapLeftOption()
        else
            log.df("延迟结束时右 Command 已松开，不再双击左 Option")
        end
    end)
end

local function onRightCmdUp()
    if not rightCmdIsDown then
        log.df("右 Command 当前并非按下状态，忽略松开事件")
        return
    end

    rightCmdIsDown = false
    log.df("检测到右 Command 松开")

    cancelOptionTimer()
    doubleTapLeftOption()

    -- 延迟恢复原输入法
    scheduleRestorePreviousIME()
end

-- 核心修复 1：只要检测到 rightcmd 的 flagsChanged，
-- 就根据内部状态翻转，而不是依赖 flags.cmd
local function handleRightCmdFlagsChanged(event)
    local keycode = event:getKeyCode()
    local flags = event:getFlags()

    if keycode ~= KEYCODE_RIGHT_CMD then
        return false
    end

    -- log.df("flagsChanged: keycode=%s, cmd=%s, alt=%s, shift=%s, ctrl=%s, rightCmdIsDown=%s", tostring(keycode),
    --     tostring(flags.cmd), tostring(flags.alt), tostring(flags.shift), tostring(flags.ctrl), tostring(rightCmdIsDown))

    if rightCmdIsDown then
        onRightCmdUp()
    else
        onRightCmdDown()
    end

    return false
end

-- 核心修复 2：避免回调异常导致 watcher 看起来“死掉”
local function safeEventHandler(event)
    local ok, result = xpcall(function()
        return handleRightCmdFlagsChanged(event)
    end, debug.traceback)

    if not ok then
        log.ef("eventtap 回调报错:\n%s", tostring(result))
        return false
    end

    return result
end

-- 放到全局，尽量避免 reload / GC 等边缘情况
_G.rightCmdWatcher = hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, safeEventHandler)

_G.rightCmdWatcher:start()

alert.show("RightCmdIME 脚本已启动")
log.i(string.format("目标输入法: %s", TARGET_INPUT_SOURCE))
log.i(string.format("右 Command keycode=%d", KEYCODE_RIGHT_CMD))
log.i(string.format("恢复输入法延迟=%.2f 秒", RESTORE_IME_DELAY))
