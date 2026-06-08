-- ============================================================
-- focus_app_to_current_space(appName, opts)
-- 把指定 app 的主窗口移动到「它所在屏幕当前显示的 space」，并聚焦。
-- 原理：按住标题栏不放，连续发送 Ctrl+fn+方向键，逐格把窗口拖到目标 space。
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
    local log    = hs.logger.new("focusApp", "debug")  -- 调试时改 "debug"

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
        local moveStart = hs.timer.secondsSinceEpoch()
        hs.timer.waitUntil(
            function()
                local p = hs.mouse.getRelativePosition()
                return (math.abs(p.x - safePoint.x) < 3 and math.abs(p.y - safePoint.y) < 3)
                    or (hs.timer.secondsSinceEpoch() - moveStart) > 0.5
            end,
            function()
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
            end,
            0.02
        )
    end)
end

return M
