-- ============================================================
-- utils/move_window_to_space.lua
-- 用 yabai 在 space 之间安排窗口。公开函数：
--   · focus_app(appName, onReady?, timeout?)  ⭐ 聚焦 App 的唯一入口（含连按保护 + 就绪等待）
--   · move_focused_window(direction)          把当前聚焦窗口移到同屏左边 / 右边的 space，焦点留在原地
--   · app_is_ready(appName)                   App 是否已在前台且有窗口，供调用方自己判断
-- 其余（focusAppToCurrentSpace 等）都是文件内私有，故意不暴露 —— 绕过 focus_app
-- 就没有连按保护和就绪等待了。
--
-- 共同前提：
--   ⭐ 移动交给 yabai，不模拟鼠标 / 键盘，所以快，也不会被 Mission Control 动画卡住
--      （yabai v7 起不需要 scripting addition，SIP 开着也能用）
--   ⚠️ 窗口永远不跨显示器 —— 只在它自己所在那块屏幕的 space 里挪
--   · 移动本身全同步；只有 focus_app 的 onReady 回调会起一个轮询 timer
--
-- 测试:
--   hs -c 'require("utils.move_window_to_space").focus_app("Obsidian")'
--   hs -c 'require("utils.move_window_to_space").move_focused_window("right")'
-- ============================================================
local yabai = require("utils.yabai")

local M = {}

-- 方向 → 在 space 列表里前进的步长
local DIRECTIONS = { left = -1, right = 1 }

-- 内置屏幕的 hs.screen:name() 特征。Hammerspoon 没有「是不是内置屏」的标志位
-- （hs.screen:getInfo() 返回 nil），只能认名字；系统语言不同名字也不同，中英文都收着。
local BUILTIN_SCREEN_PATTERNS = { "Built%-in", "内置" }

-- 等 App 到前台的上限（秒）和轮询间隔。冷启动 Electron 应用可能要好几秒
local READY_TIMEOUT = 5
local READY_POLL    = 0.05

-- ──────────── 通用内部工具 ────────────

local function invalidAppName(appName)
    return type(appName) ~= "string" or appName == ""
end

-- 失败的统一出口：控制台留日志，屏幕上给一眼能看懂的提示
local function fail(reason)
    print(string.format("[move_window_to_space] ❌ %s", reason))
    hs.alert.show("⚠️ " .. reason)
    return false, reason
end

-- 取当前聚焦窗口
-- @return table?   窗口信息（含 id / app / display / space）
-- @return string?  错误信息
local function getFocusedWindow()
    local win, err = yabai.query("--windows", "--window")
    -- ⚠️ 当前 space 空着的时候，yabai 是直接以非 0 退出码报错，而不是返回空对象
    if not win or not win.id then
        return nil, string.format("取不到当前聚焦窗口（这个 space 是空的？）%s",
            err and ("：" .. err) or "")
    end
    return win
end

-- 按 window id 取窗口信息（拿它的 display 和 space）
-- @return table?   窗口信息
-- @return string?  错误信息
local function getWindowInfo(windowId)
    local info, err = yabai.query("--windows", "--window", windowId)
    if not info or not info.id then
        return nil, string.format("yabai 查不到窗口 %s 的信息%s",
            tostring(windowId), err and ("：" .. err) or "")
    end
    return info
end

-- 取指定屏幕上的 space 列表，按 Mission Control 顺序排好
-- @param displayIndex number  屏幕序号（来自 window.display）
-- @return table?   space 数组
-- @return string?  错误信息
local function getSpacesOnDisplay(displayIndex)
    local spaces, err = yabai.query("--spaces", "--display", displayIndex)
    if not spaces then return nil, err end
    table.sort(spaces, function(a, b) return a.index < b.index end)
    return spaces
end

-- 原生全屏 space 不接受外来窗口（yabai 会直接报错），挪窗口时得先排掉
local function filterMovable(spaces)
    local result = {}
    for _, space in ipairs(spaces) do
        if not space["is-native-fullscreen"] then
            table.insert(result, space)
        end
    end
    return result
end

-- 挑出这块屏幕当前正在显示的那一格
local function findVisible(spaces)
    for _, space in ipairs(spaces) do
        if space["is-visible"] then return space end
    end
    return nil
end

-- 在 space 列表里找出 index 等于 spaceIndex 的那一格的位置
local function positionOf(spaces, spaceIndex)
    for pos, space in ipairs(spaces) do
        if space.index == spaceIndex then return pos end
    end
    return nil
end

-- yabai 的 display index 是不是内置屏？
-- 走 uuid 对到 hs.screen 再看名字 —— yabai 的 display uuid 和 hs.screen:getUUID() 是同一个值，
-- 所以不用硬编码 space 号，加减 space / 插拔显示器都不影响。
-- @return boolean?  是 / 不是；判断不了返回 nil
-- @return string?   判断不了的原因
local function isBuiltinDisplay(displayIndex)
    local display, err = yabai.query("--displays", "--display", displayIndex)
    if not display or not display.uuid then
        return nil, string.format("查不到屏幕 %s 的信息%s",
            tostring(displayIndex), err and ("：" .. err) or "")
    end

    for _, screen in ipairs(hs.screen.allScreens()) do
        if screen:getUUID() == display.uuid then
            local name = screen:name() or ""
            for _, pattern in ipairs(BUILTIN_SCREEN_PATTERNS) do
                if name:find(pattern) then return true end
            end
            return false
        end
    end
    return nil, string.format("hs.screen 里找不到 uuid %s", display.uuid)
end

-- ============================================================
-- 聚焦窗口 → 左 / 右边的 space
-- ============================================================

--- 把当前聚焦窗口移到同屏左边 / 右边的 space（焦点留在原地）
-- 到边缘时在本屏内循环：第 1 格往左 → 最后 1 格，最后 1 格往右 → 第 1 格。
-- 绕圈的那一下会弹 alert —— 焦点留在原地，窗口"凭空"跑到另一头很容易让人懵。
-- @param direction string  "left" 或 "right"
-- @return boolean  是否成功
-- @return string?  失败原因
function M.move_focused_window(direction)
    local step = DIRECTIONS[direction]
    if not step then
        return fail(string.format("方向只能是 left 或 right，收到 '%s'", tostring(direction)))
    end

    local win, winErr = getFocusedWindow()
    if not win then return fail(winErr) end

    local allSpaces, spacesErr = getSpacesOnDisplay(win.display)
    if not allSpaces then return fail(spacesErr) end

    local spaces = filterMovable(allSpaces)
    if #spaces < 2 then
        return fail(string.format("屏幕 %d 上只有 %d 个可用 space，无处可去", win.display, #spaces))
    end

    local currentPos = positionOf(spaces, win.space)
    if not currentPos then
        return fail(string.format("窗口所在 space %s 不在可移动列表里（全屏 space？）", tostring(win.space)))
    end

    -- 本屏内循环：先转成 0-based 再取模，回到 1-based
    local targetPos = (currentPos - 1 + step) % #spaces + 1
    local target    = spaces[targetPos]

    -- 这一步是不是绕了一圈（从一头跳到另一头）
    local wrapped = (step > 0 and currentPos == #spaces)
                 or (step < 0 and currentPos == 1)

    local ok, cmdErr = yabai.command("window", win.id, "--space", target.index)
    if not ok then return fail(cmdErr) end

    print(string.format("[move_window_to_space] ✅ '%s' 已从 space %d 移到 space %d（屏幕 %d，方向 %s）",
        win.app or "?", win.space, target.index, win.display, direction))

    if wrapped then
        local msg
        if step > 0 then
            msg = string.format("🔄 已到最右一格，绕回第 1 格（space %d → %d）", win.space, target.index)
        else
            msg = string.format("🔄 已到最左一格，绕到最后 1 格（space %d → %d）", win.space, target.index)
        end
        hs.alert.show(msg)
        print("[move_window_to_space] " .. msg)
    end

    return true
end

-- ============================================================
-- 指定 App → 它所在屏幕正在显示的 space
-- ============================================================

-- 按 App 名找运行中的应用（忽略大小写的精确匹配）
-- ⚠️ 别用 hs.application.get()：App 名匹配不上时它会退回按「窗口标题」找，
--    而且 application.lua:169-172 把 app 追加进了还装着 window 的同一个表里，
--    于是第 1 个返回值是 hs.window 而不是 hs.application，调 :mainWindow() 直接报错。
--    实际踩法：Obsidian 没开，但编辑器开着 obsidian_chatbox_management.lua 这种标题的窗口。
local function getRunningApp(appName)
    local wanted = appName:lower()
    for _, app in ipairs(hs.application.runningApplications()) do
        local name = app:name()
        if name and name:lower() == wanted then return app end
    end
    return nil
end

-- 把窗口挪到「它所在屏幕正在显示的 space」，然后聚焦
-- ⭐ 顺序很关键：先挪窗口、后聚焦。反过来的话 macOS 会先切到窗口原来那个 space（带动画），
--    老实现正是被这一点逼着「focus 之前先把目标 space 记下来」的。
local function pullWindowIntoView(win, appName)
    local id = win:id()
    if not id then return fail(string.format("'%s' 的窗口拿不到 id", appName)) end

    local info, infoErr = getWindowInfo(id)
    if not info then return fail(infoErr) end

    local spaces, spacesErr = getSpacesOnDisplay(info.display)
    if not spaces then return fail(spacesErr) end

    local visible = findVisible(spaces)
    if not visible then
        return fail(string.format("屏幕 %d 上找不到正在显示的 space", info.display))
    end

    if visible.index ~= info.space then
        if visible["is-native-fullscreen"] then
            return fail(string.format("屏幕 %d 正在显示的 space %d 是原生全屏，放不进窗口",
                info.display, visible.index))
        end
        local ok, cmdErr = yabai.command("window", id, "--space", visible.index)
        if not ok then return fail(cmdErr) end
        print(string.format("[move_window_to_space] '%s' space %d → %d（屏幕 %d）",
            appName, info.space, visible.index, info.display))
    end

    -- 窗口已经落在可见 space 上，这时聚焦不会触发切 space 动画
    local app = win:application()
    if app and app:isHidden() then app:unhide() end
    win:focus()

    print(string.format("[move_window_to_space] ✅ 已聚焦 '%s'（space %d，屏幕 %d）",
        appName, visible.index, info.display))
    return true
end

-- 把指定 App 的窗口拉到「它所在屏幕正在显示的 space」并聚焦
-- App 被隐藏了也能唤出来。没运行、或者窗口被 ⌘W 关掉时，交给 launchOrFocus 就行 ——
-- ⭐ 新窗口一定会落在某块屏幕当前显示的 space 上，本来就不需要我们再挪一次。
-- ⚠️ 私有：连按保护和就绪等待都在 focus_app 里，绕过它直接调这条路会丢掉那两层保护，
--    所以只给 focus_app 用，不对外暴露。
-- @param appName string  应用名，如 "Obsidian"
-- @return boolean  是否成功
-- @return string?  失败原因
local function focusAppToCurrentSpace(appName)
    if invalidAppName(appName) then
        return fail(string.format("appName 必须是非空字符串，收到 '%s'", tostring(appName)))
    end

    local app = getRunningApp(appName)
    local win = app and app:mainWindow()
    if win then return pullWindowIntoView(win, appName) end

    print(string.format("[move_window_to_space] '%s' 没有窗口，交给 launchOrFocus", appName))
    if not hs.application.launchOrFocus(appName) then
        return fail(string.format("启动不了 '%s'（App 名字对吗？）", appName))
    end

    hs.alert.show(string.format("⏳ 正在启动 %s…", appName))
    return true
end

-- ============================================================
-- 首选入口 focus_app + 「等 App 真的到前台」
-- ============================================================

-- 各 App 正在跑的就绪等待 timer
-- ⚠️ 必须存成 module 级变量，不然会被 GC，等待静默失效（见 unlock_watcher.lua 的同类注释）
local readyWaits = {}

--- App 是不是已经就绪：在前台 + 有窗口
-- ⭐ 「在前台」才是关键 —— hs.eventtap.keyStroke 是发给前台 App 的，
--    只判断「窗口出现了」的话，键盘事件可能还打在旧的前台 App 身上。
-- @param appName string
-- @return boolean
function M.app_is_ready(appName)
    if invalidAppName(appName) then return false end
    local front = hs.application.frontmostApplication()
    if not front then return false end
    local name = front:name()
    if not name or name ~= appName then return false end
    return front:mainWindow() ~= nil
end

-- 等 App 就绪，就绪后执行 onReady（onReady 可以是 nil —— 那这就只是一次「等它起来」的守卫）
-- readyWaits[appName] 有值 = 这个 App 正在等就绪，focus_app 靠它拦掉连按
-- ⚠️ 超时【不会】回调 —— 不然后续 keystroke 会打到别的 App 身上，那比什么都不做更糟
local function whenAppReady(appName, onReady, timeout)
    timeout = timeout or READY_TIMEOUT
    local deadline = hs.timer.secondsSinceEpoch() + timeout

    readyWaits[appName] = hs.timer.waitUntil(
        function()
            return M.app_is_ready(appName) or hs.timer.secondsSinceEpoch() > deadline
        end,
        function()
            readyWaits[appName] = nil
            if not M.app_is_ready(appName) then
                fail(string.format("等了 %.0f 秒 '%s' 还是没到前台%s",
                    timeout, appName, onReady and "，后续动作已取消" or ""))
                return
            end
            print(string.format("[move_window_to_space] ✅ '%s' 已就绪", appName))
            if onReady then onReady() end
        end,
        READY_POLL)
end

--- 聚焦指定 App —— 对外首选入口
--   · App 有窗口且窗口在【内置屏】上 → 直接 launchOrFocus，让 macOS 自己切过去，窗口不动
--   · 其余情况（窗口在外接屏 / App 没运行 / 窗口被关了）→ 走 focus_app_to_current_space
-- 每次调用都会盯着这个 App 直到它真的在前台且有窗口（最多等 timeout 秒），期间：
--   · ⭐ 同一个 App 的重复调用一律忽略 —— 冷启动要好几秒，用户看不到窗口就会连按快捷键
--   · 传了 onReady 的话，就绪后才执行它；冷启动时后续的 keyStroke 得挂在这里，别用固定延时去赌
-- @param appName string    应用名，如 "Obsidian"
-- @param onReady function? App 就绪后执行；超时则不执行，只报错
-- @param timeout number?   等待上限，默认 READY_TIMEOUT 秒
-- @return boolean  聚焦动作本身是否成功（不代表 App 已经就绪）
-- @return string?  失败原因
function M.focus_app(appName, onReady, timeout)
    if invalidAppName(appName) then
        return fail(string.format("appName 必须是非空字符串，收到 '%s'", tostring(appName)))
    end

    -- 上一次调用还在等这个 App 就绪 → 这次是连按，直接丢掉
    if readyWaits[appName] then
        print(string.format("[move_window_to_space] 还在等 '%s' 就绪，忽略这次调用", appName))
        hs.alert.show("还在等" .. appName.. "就绪，忽略这次调用")
        return true
    end

    local ok, err
    local app = getRunningApp(appName)
    local win = app and app:mainWindow()
    local info = win and win:id() and getWindowInfo(win:id())

    -- 判断不了内置屏的时候不报错，直接落到通用路径
    if info and isBuiltinDisplay(info.display) then
        print(string.format("[move_window_to_space] '%s' 在内置屏（space %s），直接 launchOrFocus",
            appName, tostring(info.space)))
        if hs.application.launchOrFocus(appName) then
            ok = true
        else
            ok, err = fail(string.format("聚焦不了 '%s'", appName))
        end
    else
        ok, err = focusAppToCurrentSpace(appName)
    end

    -- 聚焦成功就盯着它到就绪：既是 onReady 的触发条件，也是下一次连按的拦截依据
    if ok then whenAppReady(appName, onReady, timeout) end
    return ok, err
end

return M
