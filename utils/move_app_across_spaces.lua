-- ============================================================
-- focus_app_to_current_space(appName, opts)
-- 把指定 app 的主窗口移动到「它所在屏幕当前显示的 space」，并聚焦。
-- 原理：按住标题栏不放，连续发送 Ctrl+fn+方向键，逐格把窗口拖到目标 space。
-- 测试: require("utils.move_app_across_spaces").focus_app_to_current_space("Obsidian")
--
-- @param appName string  应用名，如 "Obsidian"
-- @param opts    table?   可选配置：
--     focusDelay   focus 后等待窗口可见的时间（默认 0.5）
--     keyInterval  每次发方向键之间的间隔（默认 0.15）
--     stepTimeout  单格移动的超时（默认 1.5）
--     downDelay    mouseDown 后等待按住状态建立的时间（默认 0.1）
-- ============================================================
local M = {}
function M.focus_app_to_current_space(appName, opts)
    opts = opts or {}
    local FOCUS_DELAY  = opts.focusDelay  or 0.3
    local KEY_INTERVAL = opts.keyInterval or 0.15
    local STEP_TIMEOUT = opts.stepTimeout or 1.5
    local DOWN_DELAY   = opts.downDelay   or 0.1

    local spaces = require "hs.spaces"
    local hsee   = hs.eventtap.event
    local log    = hs.logger.new("focusApp", "info")  -- 调试时改 "debug"

    -- ---------- 内部工具 ----------
    local function getUserSpaces(screen)
        local list = (spaces.allSpaces() or {})[screen:getUUID()]
        if not list then return nil end
        local result = {}
        for _, spc in ipairs(list) do
            if spaces.spaceType(spc) == "user" then
                table.insert(result, spc)
            end
        end
        return result
    end

    local function indexOf(list, val)
        for i, v in ipairs(list) do if v == val then return i end end
        return nil
    end

    local function currentSpace(win)
        local s = spaces.windowSpaces(win)
        return (s and s[1]) or nil
    end

    -- ---------- 主流程 ----------
    local app = hs.application.get(appName)
    if not app then
        hs.application.launchOrFocus(appName)
        log.f("'%s' 未运行，已启动；请窗口出现后再次执行", appName)
        return
    end

    local win = app:mainWindow()
    if not win then log.ef("'%s' 没有主窗口", appName); return end

    -- 【关键】focus 之前，先读「app 所在屏幕当前显示的 space」= 目标
    local targetSpace = spaces.activeSpaceOnScreen(win:screen():id())
    log.df("目标 space（%s 所在屏幕当前显示）: %s", appName, tostring(targetSpace))

    hs.application.launchOrFocus(appName)

    hs.timer.doAfter(FOCUS_DELAY, function()
        local app2 = hs.application.get(appName)
        local win2 = app2 and app2:mainWindow()
        if not win2 then log.ef("focus 后 '%s' 没有主窗口", appName); return end

        local userSpaces = getUserSpaces(win2:screen())
        if not userSpaces then log.e("取不到 user space 列表"); win2:focus(); return end

        local srcIdx = indexOf(userSpaces, currentSpace(win2))
        local dstIdx = indexOf(userSpaces, targetSpace)
        log.df("有序列表 %s | 源=%s 目标=%s",
            hs.inspect(userSpaces), tostring(srcIdx), tostring(dstIdx))

        if not srcIdx or not dstIdx then
            log.w("源或目标 space 不在同屏列表中，仅聚焦"); win2:focus(); return
        end
        if srcIdx == dstIdx then
            log.df("'%s' 已在目标 space", appName); win2:focus(); return
        end

        local dir   = (dstIdx > srcIdx) and "right" or "left"
        local steps = math.abs(dstIdx - srcIdx)
        log.df("方向 %s, 步数 %d", dir, steps)

        local savedCursor = hs.mouse.getRelativePosition()
        local zoomPoint   = hs.geometry(win2:zoomButtonRect())
        local safePoint   = zoomPoint:move({-5, -5}).topleft

        local function finish(ok, msg)
            hsee.newMouseEvent(hsee.types.leftMouseUp, safePoint):post()
            hs.mouse.setRelativePosition(savedCursor)
            win2:focus()
            if ok then log.df("✅ '%s' 已移动到目标 space 并聚焦", appName)
            else       log.wf("⚠️ %s", msg or "移动失败") end
        end

        -- 移动鼠标到标题栏并确认到位，再按下（全程不松手）
        hs.mouse.setRelativePosition(safePoint)
        hs.timer.doAfter(0.05, function()        -- ← 替掉整个 waitUntil（跨屏/重app 给 0.05 缓冲）
            log.df("⏱ 鼠标已移动 (固定延时)")
            hsee.newMouseEvent(hsee.types.leftMouseDown, safePoint):post()
            local function sendOneKey(remaining)
                if remaining <= 0 then finish(true); return end
                local before = currentSpace(win2)
                hs.eventtap.keyStroke({"ctrl", "fn"}, dir, 0)
                local t0 = hs.timer.secondsSinceEpoch()
                hs.timer.waitUntil(
                    function()
                        local now = currentSpace(win2)
                        return ((now ~= nil) and (now ~= before))
                            or (hs.timer.secondsSinceEpoch() - t0) > STEP_TIMEOUT
                    end,
                    function()
                        local now = currentSpace(win2)
                        if now ~= nil and now ~= before then
                            log.df("  ↳ 第 %d 格完成 (%s -> %s)",
                                steps - remaining + 1, tostring(before), tostring(now))
                            hs.timer.doAfter(KEY_INTERVAL, function()
                                sendOneKey(remaining - 1)
                            end)
                        else
                            finish(false, string.format("第%d格超时，窗口 space=%s",
                                steps - remaining + 1, tostring(now)))
                        end
                    end,
                    0.03
                )
            end
            hs.timer.doAfter(DOWN_DELAY, function() sendOneKey(steps) end)
        end)
    end)
end

-- ============================================================
-- move_front_app_one_space(opts)
-- 把「最前端 app」的主窗口移动 1 个 space：
--   · 若它在所在屏幕的第 1 格 → 往右移 1 格
--   · 否则 → 往左移 1 格
-- 移动后用原生 Ctrl+方向键把屏幕切回原来的 space（无 Mission Control 动画）。
-- 测试: require("utils.move_app_across_spaces").move_front_app_one_space()
--
-- @param opts table?  可选配置：
--     keyDelay     mouseDown 后等待按住状态建立的时间（默认 0.1）
--     stepTimeout  单格移动超时（默认 1.5）
--     backDelay    松手后到切回 space 之间的间隔（默认 0.2）
-- ============================================================
function M.move_front_app_one_space(opts)
    opts = opts or {}
    local KEY_DELAY    = opts.keyDelay    or 0.1
    local STEP_TIMEOUT = opts.stepTimeout or 1.5
    local BACK_DELAY   = opts.backDelay   or 0.2

    local spaces = require "hs.spaces"
    local hsee   = hs.eventtap.event
    local log    = hs.logger.new("moveFrontApp", "info")  -- ⏱ 临时设 debug 以便看时间日志

    -- ⏱ 计时起点 + 打点辅助函数
    local T0 = hs.timer.secondsSinceEpoch()
    local function mark(label)
        log.df("⏱ [%6.3f s] %s", hs.timer.secondsSinceEpoch() - T0, label)
    end
    mark("函数进入")

    -- ---------- 内部工具 ----------
    local function getUserSpaces(screen)
        local list = (spaces.allSpaces() or {})[screen:getUUID()]
        if not list then return nil end
        local result = {}
        for _, spc in ipairs(list) do
            if spaces.spaceType(spc) == "user" then
                table.insert(result, spc)
            end
        end
        return result
    end

    local function indexOf(list, val)
        for i, v in ipairs(list) do if v == val then return i end end
        return nil
    end

    local function currentSpace(win)
        local s = spaces.windowSpaces(win)
        return (s and s[1]) or nil
    end

    -- ---------- 主流程 ----------
    local app = hs.application.frontmostApplication()
    if not app then log.e("找不到最前端 app"); return end
    mark("取得 frontmost app")

    local win = app:mainWindow()
    if not win then log.ef("'%s' 没有主窗口", app:name()); return end
    mark("取得 mainWindow")

    local screen      = win:screen()
    local originSpace = spaces.activeSpaceOnScreen(screen:id())
    mark("取得 screen + originSpace")

    local userSpaces = getUserSpaces(screen)
    if not userSpaces then log.e("取不到 user space 列表"); return end
    mark("getUserSpaces 完成")

    local srcIdx = indexOf(userSpaces, currentSpace(win))
    if not srcIdx then log.w("窗口当前 space 不在同屏列表中，终止"); return end
    mark("currentSpace + indexOf 完成 (srcIdx=" .. tostring(srcIdx) .. ")")

    -- 第 1 格往右，其余往左
    local dir = (srcIdx == 1) and "right" or "left"
    log.df("最前端 app='%s' 在第 %d 格, 原 space=%s, 方向=%s",
        app:name(), srcIdx, tostring(originSpace), dir)

    -- 边界检查：确保目标方向有 space 可去
    if dir == "right" and srcIdx >= #userSpaces then
        log.w("已是最右一格，右边没有 space，终止"); return
    end
    if dir == "left" and srcIdx <= 1 then
        log.w("已是最左一格，左边没有 space，终止"); return
    end

    local savedCursor = hs.mouse.getRelativePosition()
    local zoomPoint   = hs.geometry(win:zoomButtonRect())
    local safePoint   = zoomPoint:move({-1, -1}).topleft
    mark("算出 safePoint，准备移动鼠标")

    -- 切回原 space（方案B：反方向原生 Ctrl+方向键，无 Mission Control 动画）+ 收尾
    local function finish(ok, msg)
        hsee.newMouseEvent(hsee.types.leftMouseUp, safePoint):post()
        hs.mouse.setRelativePosition(savedCursor)

        if ok then
            hs.timer.doAfter(BACK_DELAY, function()
                local backDir = (dir == "right") and "left" or "right"
                hs.eventtap.keyStroke({"ctrl", "fn"}, backDir, 0)
                mark("已切回原 space (完成)")
                log.df("✅ '%s' 已移动 1 格，并已切回原 space", app:name())
            end)
        else
            log.wf("⚠️ %s", msg or "移动失败")
        end
    end

    -- 移动鼠标到标题栏并确认到位，再按下（全程不松手）
    hs.mouse.setRelativePosition(safePoint)
    hs.timer.doAfter(0.03, function()   -- 屏内移动，30ms 足够生效
        mark("鼠标已移动 (固定延时) → 准备 mouseDown")
        hsee.newMouseEvent(hsee.types.leftMouseDown, safePoint):post()
        mark("mouseDown 已发出")

        hs.timer.doAfter(KEY_DELAY, function()
            mark("KEY_DELAY 结束 → 准备发方向键")
            local before = currentSpace(win)
            hs.eventtap.keyStroke({"ctrl", "fn"}, dir, 0)
            mark("方向键已发出 (窗口应开始移动)")

            local t0 = hs.timer.secondsSinceEpoch()
            hs.timer.waitUntil(
                function()
                    local now = currentSpace(win)
                    return ((now ~= nil) and (now ~= before))
                        or (hs.timer.secondsSinceEpoch() - t0) > STEP_TIMEOUT
                end,
                function()
                    local now = currentSpace(win)
                    if now ~= nil and now ~= before then
                        mark("窗口已落到新 space")
                        log.df("  ↳ 窗口已移动 (%s -> %s)", tostring(before), tostring(now))
                        finish(true)
                    else
                        finish(false, string.format("移动超时，窗口 space=%s", tostring(now)))
                    end
                end,
                0.03
            )
        end)
    end)

end



return M
