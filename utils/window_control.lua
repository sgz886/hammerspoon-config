-- ============================================================
-- 用 yabai 在 space 之间安排窗口。公开函数：
--   · focus_app(appName, onReady?, timeout?)  ⭐ 聚焦 App 的唯一入口（含连按保护 + 就绪等待）
--   · move_focused_window_with_direction(direction)          把当前聚焦窗口移到同屏左边 / 右边的 space，焦点留在原地
--   · switch_current_space(direction, method?, onDone?) 把焦点切到【鼠标所在那块屏】左边 / 右边那一格 space（自带边缘判断 + 复查补发）
--   · swap_space_and_app(direction)           把当前 space 跟同屏左边 / 右边那一格【整批互换窗口】，焦点跟着自己的窗口走
--   · app_is_ready(appName)                   App 是否已在前台且有窗口，供调用方自己判断
-- 其余（focusAppToCurrentSpace 等）都是文件内私有，故意不暴露 —— 绕过 focus_app
-- 就没有连按保护和就绪等待了。
--
-- 共同前提：
--   ⭐ 移动交给 yabai，不模拟鼠标 / 键盘，所以快，也不会被 Mission Control 动画卡住
--      （yabai v7 起不需要 scripting addition，SIP 开着也能用）
--   ⚠️ 窗口永远不跨显示器 —— 只在它自己所在那块屏幕的 space 里挪
--   · 移动本身全同步；只有 focus_app 的就绪等待会起 timer（轮询 + 沉降各一个）
--
-- 测试:
--   hs -c 'require("utils.window_control").focus_app("Obsidian")'
--   hs -c 'require("utils.window_control").move_focused_window_with_direction("right")'
-- ============================================================

-- import
local yabai = require("utils.yabai")
local common = require("utils.common")

-- ──────────── local variable ────────────
-- ⭐ 沉降期（秒）：窗口出现 ≠ 里面的组件加载完了。Electron 之类的 App 窗口先画出来，
--    输入框 / 快捷键响应还要再等一会儿，这时候发按键会打空。所以检测到就绪后再缓一下。
local READY_SETTLE = 0.75

-- 方向 → 在 space 列表里前进的步长
local DIRECTIONS = { left = -1, right = 1 }

-- 内置屏幕的 hs.screen:name() 特征。Hammerspoon 没有「是不是内置屏」的标志位
-- （hs.screen:getInfo() 返回 nil），只能认名字；系统语言不同名字也不同，中英文都收着。
local BUILTIN_SCREEN_PATTERNS = { "Built%-in", "内置" }

-- 等 App 到前台的上限（秒）和轮询间隔。冷启动 Electron 应用可能要好几秒
local READY_TIMEOUT = 5
local READY_POLL    = 0.05

-- ──────────── 通用内部工具 ────────────
-- 通用工具函数集合


-- 失败的统一出口：控制台留日志，屏幕上给一眼能看懂的提示
local function fail(reason)
    print(string.format("[window_control] ❌ %s", reason))
    hs.alert.show("⚠️ " .. reason)
    return false, reason
end

local function invalidAppName(appName)
    return type(appName) ~= "string" or appName == ""
end

-- ============================================
-- getRunningApp: 按 App 名找运行中的应用（忽略大小写的精确匹配）—— 全仓库唯一一份
-- ⚠️ 别用 hs.application.get() / find()：App 名匹配不上时它们会退回按「窗口标题」找，
--    返回的第 1 个值可能是 hs.window 而不是 hs.application，接着调 :mainWindow() 直接报错。
--    实际踩法：Obsidian 没开，但编辑器开着 obsidian_chatbox_management.lua 这种标题的窗口。
-- @param appName string
-- @return hs.application?  找不到返回 nil
-- ============================================
local function getRunningApp(appName)
  local wanted = appName:lower()
  for _, app in ipairs(hs.application.runningApplications()) do
    local name = app:name()
    if name and name:lower() == wanted then return app end
  end
  return nil
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

-- yabai 的 display index → 对应的 hs.screen 对象
-- ⭐ 靠 uuid 对上：yabai 的 display uuid 和 hs.screen:getUUID() 是同一个值，
--    所以不用硬编码屏幕号，插拔显示器都不影响。
-- @return table?   hs.screen 对象
-- @return string?  对不上的原因
local function screenForDisplay(displayIndex)
    local display, err = yabai.query("--displays", "--display", displayIndex)
    if not display or not display.uuid then
        return nil, string.format("查不到屏幕 %s 的信息%s",
            tostring(displayIndex), err and ("：" .. err) or "")
    end

    for _, screen in ipairs(hs.screen.allScreens()) do
        if screen:getUUID() == display.uuid then return screen end
    end
    return nil, string.format("hs.screen 里找不到 uuid %s", display.uuid)
end

-- yabai 的 display index 是不是内置屏？
-- @return boolean?  是 / 不是；判断不了返回 nil
-- @return string?   判断不了的原因
local function isBuiltinDisplay(displayIndex)
    local screen, err = screenForDisplay(displayIndex)
    if not screen then return nil, err end

    local name = screen:name() or ""
    for _, pattern in ipairs(BUILTIN_SCREEN_PATTERNS) do
        if name:find(pattern) then return true end
    end
    return false
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

-- 各 App 正在跑的就绪等待 timer
-- ⚠️ 必须存成 module 级变量，不然会被 GC，等待静默失效（见 unlock_watcher.lua 的同类注释）
local readyWaits = {}

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
        print(string.format("[window_control] '%s' space %d → %d（屏幕 %d）",
            appName, info.space, visible.index, info.display))
    end

    -- 窗口已经落在可见 space 上，这时聚焦不会触发切 space 动画
    local app = win:application()
    if app and app:isHidden() then app:unhide() end
    win:focus()

    print(string.format("[window_control] ✅ 已聚焦 '%s'（space %d，屏幕 %d）",
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

    print(string.format("[window_control] '%s' 没有窗口，交给 launchOrFocus", appName))
    if not hs.application.launchOrFocus(appName) then
        return fail(string.format("启动不了 '%s'（App 名字对吗？）", appName))
    end

    hs.alert.show(string.format("⏳ 正在启动 %s…", appName))
    return true
end

-- 等 App 就绪，就绪后执行 onReady（onReady 可以是 nil —— 那这就只是一次「等它起来」的守卫）
-- 两个阶段：
--   ① 轮询等「到前台 + 有窗口」，最多 timeout 秒
--   ② 沉降 settle 秒等组件加载，然后复查一次，才算真就绪。settle 为 0 就跳过这一步
-- readyWaits[appName] 有值 = 这个 App 还在①或②里，focus_app 靠它拦掉连按 ——
-- 所以沉降期结束前锁一直握着，别提前清掉。
-- ⚠️ 超时 / 沉降期里又跑到后台，都【不会】回调 —— keystroke 打到别的 App 身上比什么都不做更糟
-- @param settle number?  沉降秒数，0 或省略表示不沉降
local function whenAppReady(appName, onReady, timeout, settle)
    timeout = timeout or READY_TIMEOUT
    settle  = settle or 0
    local deadline = hs.timer.secondsSinceEpoch() + timeout

    -- 放锁 + 报错的统一出口
    local function abort(reason)
        readyWaits[appName] = nil
        fail(reason .. (onReady and "，后续动作已取消" or ""))
    end

    -- 真就绪：放锁 + 回调
    local function finish()
        readyWaits[appName] = nil
        print(string.format("[window_control] ✅ '%s' 已就绪", appName))
        if onReady then onReady() end
    end

    local waitTimer
    waitTimer = hs.timer.waitUntil(
        function()
            return app_is_ready(appName) or hs.timer.secondsSinceEpoch() > deadline
        end,
        function()
            if waitTimer then waitTimer:stop() end
            if not app_is_ready(appName) then
                abort(string.format("等了 %.0f 秒 '%s' 还是没到前台", timeout, appName))
                return
            end

            -- 窗口本来就在（只是切了个前台）→ 组件早加载好了，不用等
            if settle <= 0 then return finish() end

            -- ② 窗口是刚新建的，里面的组件未必加载完，再缓一下
            print(string.format("[window_control] '%s' 窗口是新建的，再等 %.1fs 让组件加载完",
                appName, settle))
            readyWaits[appName] = hs.timer.doAfter(settle, function()
                if not app_is_ready(appName) then
                    abort(string.format("'%s' 在这 %.1fs 里又离开了前台", appName, settle))
                    return
                end
                finish()
            end)
        end,
        READY_POLL)
    readyWaits[appName] = waitTimer
end

-- 取当前聚焦窗口（纯 Hammerspoon，不起 yabai 子进程）
-- ⭐ display / space 仍然是 yabai 口径的序号，因为调用方（getSpacesOnDisplay /
--    yabai.command）还得拿它们去跟 yabai 对话。换算依据：
--    hs.spaces.data_managedDisplaySpaces() 和 yabai 读的是同一份 CGS 数据
--    （SLSCopyManagedDisplaySpaces），连顺序都一样 —— 于是
--      · yabai display index = 该屏幕在这个数组里的位置
--      · yabai space index   = 该 space 在「所有屏幕拉平后」的位置（全屏 space 也算一格）
-- ⭐ 不按 UUID 找屏幕，而是先定位 space、再取「装着它的那个 display」的下标 ——
--    某些机型上 data 里主屏的 "Display Identifier" 是字符串 "Main" 而不是 UUID，
--    按 UUID 匹配会扑空。
-- @return table?   窗口信息（含 id / app / display / space）
-- @return string?  错误信息
local function getFocusedWindow()
    local win = hs.window.focusedWindow()
    local id = win and win:id()
    -- ⚠️ 点一下桌面（或当前 space 空着）时，focusedWindow() 不返回 nil，而是返回 Finder 的
    --    桌面元素（role = AXScrollArea，:id() == 0）。Lua 里 0 是真值，光判 `not id` 拦不住，
    --    会一路把 `yabai window 0 --space N` 发出去，报 "could not locate the window to act on"。
    --    真窗口的 CGWindowID 一定 > 0，所以这里按数值卡。
    if type(id) ~= "number" or id <= 0 then
        return nil, "当前没有聚焦任何窗口（点到桌面了？还是这个 space 是空的？）"
    end

    local screen = win:screen()
    if not screen then
        return nil, string.format("拿不到窗口 %d 所在的屏幕", id)
    end

    -- 聚焦窗口一定在「它所在屏幕正在显示的那格 space」上
    local spaceId = hs.spaces.activeSpaceOnScreen(screen)
    if not spaceId then
        return nil, string.format("拿不到屏幕 '%s' 正在显示的 space", screen:name() or "?")
    end

    local displays = hs.spaces.data_managedDisplaySpaces()
    if type(displays) ~= "table" then
        return nil, "hs.spaces 取不到 CGS 的 display/space 数据"
    end

    local displayIndex, spaceIndex, counter = nil, nil, 0
    for i, display in ipairs(displays) do
        for _, space in ipairs(display.Spaces or {}) do
            counter = counter + 1
            if space.ManagedSpaceID == spaceId or space.id64 == spaceId then
                displayIndex, spaceIndex = i, counter
                break
            end
        end
        if spaceIndex then break end
    end
    if not spaceIndex then
        return nil, string.format("space %s 不在 hs.spaces 的数据里", tostring(spaceId))
    end

    local app = win:application()
    return {
        id      = id,
        app     = app and app:name(),
        display = displayIndex,
        space   = spaceIndex,
    }
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

-- 取某一格 space 上「搬得动」的窗口
-- 一律【无视】以下几类，它们留在原地都没有实际影响：
--   · is-sticky —— 本来就在每一格 space 上（实测本机 Typeless 的状态窗就是），搬它反而会把它钉死到一格
--   · is-minimized / is-hidden —— 看不见的窗口，用户也不会在意它归哪一格
--   · is-native-fullscreen —— 自己独占一格 space
-- 上面这几类静默跳过，不打日志（数量多、又是常态，刷屏没意义）。
-- ⚠️ can-move / has-ax-reference 为假的窗口 yabai 是真的动不了：实测
--    `yabai -m window 20062 --space 11` → "could not locate the window to act on!"。
--    这类窗口只打一行日志、不弹 alert —— 实测都是各 App 的无标题隐形辅助窗口
--    （Hammerspoon / 活动监视器都有），提示用户没有意义。
-- @param spaceIndex number
-- @return table?   搬得动的窗口数组
-- @return string?  错误信息
local function movableWindowsOnSpace(spaceIndex)
    local windows, err = yabai.query("--windows", "--space", spaceIndex)
    if not windows then return nil, err end

    local result = {}
    for _, win in ipairs(windows) do
        if win["is-sticky"] or win["is-minimized"] or win["is-hidden"]
            or win["is-native-fullscreen"] then
            -- 静默无视
        elseif win["can-move"] == false or win["has-ax-reference"] == false then
            print(string.format("[window_control] space %d 上的 '%s'(%s) yabai 搬不动，无视",
                spaceIndex, win.app or "?", tostring(win.id)))
        else
            table.insert(result, win)
        end
    end
    return result
end

-- 把一批窗口搬到指定 space，返回搬失败的个数
-- ⭐ 单个窗口失败不中断：交换到一半 return 会留下「一半在这格一半在那格」的烂状态，
--    不如把能搬的都搬完，最后统一报数。
-- @return number  失败个数
local function moveWindowsToSpace(windows, spaceIndex)
    local failed = 0
    for _, win in ipairs(windows) do
        local ok, err = yabai.command("window", win.id, "--space", spaceIndex)
        if not ok then
            failed = failed + 1
            print(string.format("[window_control] ⚠️ '%s'(%s) 搬到 space %d 失败：%s",
                win.app or "?", tostring(win.id), spaceIndex, err or "?"))
        end
    end
    return failed
end

-- 找同一块屏幕上紧邻的那一格 space —— 边缘判断的唯一一份实现
-- ⭐ yabai 的 space index 是【跨屏拉平】的（比如 display 1 = 1..6、display 2 = 7..9），
--    所以「space 6 的右边」必须是 nil 而不是 space 7。只在本屏的 space 列表里找就天然满足，
--    不用去比 display 号。（顺带：yabai 的 space --focus next 是会跨屏的，实测 7 → 8，
--    所以那条路必须靠这个函数先把边缘挡住。）
-- @param displayIndex number  屏幕序号
-- @param spaceIndex number    起点 space 的 index
-- @param step number          -1 / +1，来自 DIRECTIONS
-- @return table?   邻居 space；【到边缘返回 nil 且不带错误】，调用方据此决定「什么都不做」
-- @return string?  错误信息（只有查询失败 / 起点不在列表里才有）
local function adjacentSpaceOnDisplay(displayIndex, spaceIndex, step)
    local spaces, err = getSpacesOnDisplay(displayIndex)
    if not spaces then return nil, err end

    local pos = positionOf(spaces, spaceIndex)
    if not pos then
        return nil, string.format("space %s 不在屏幕 %s 的 space 列表里",
            tostring(spaceIndex), tostring(displayIndex))
    end
    return spaces[pos + step]
end

-- 「要操作的那一格 space」= 鼠标所在那块屏幕正在显示的那一格
-- ⭐ 按【鼠标】而不是【键盘焦点】定位：双显示器下人把鼠标移到另一块屏，想操作的就是那一块，
--    但键盘焦点还留在原来那块屏上。yabai 的 `--space`（不带参数）给的是【焦点】那一格，
--    用它会操作错屏幕；`--space mouse` 给的才是鼠标那块屏正在显示的那一格（实测过，
--    连 hs.mouse 程序化移动的鼠标也跟得上）。
-- ⚠️ 鼠标那块屏查不出来时退回焦点那一格，别直接失败。
-- @return table?   space（含 index / id / display / is-native-fullscreen）
-- @return table?   它所在的 hs.screen 对象（复查「切过去了没有」要用）
-- @return string?  错误信息
local function spaceUnderMouse()
    local space, err = yabai.query("--spaces", "--space", "mouse")
    if not space or not space.index then
        print(string.format("[window_control] 查不到鼠标所在屏幕的 space%s，退回焦点那一格",
            err and ("：" .. err) or ""))
        local fallback, fbErr = yabai.query("--spaces", "--space")
        if not fallback or not fallback.index then
            return nil, nil, string.format("查不到当前 space%s", fbErr and ("：" .. fbErr) or "")
        end
        space = fallback
    end

    -- 找出这一格所在的 hs.screen
    -- ⭐ 直接问 hs.spaces「哪块屏现在显示的就是它」—— 纯 CGS 调用，不起子进程（yabai 的每次
    --    query 都是一个同步 hs.execute，会卡住 Hammerspoon 主线程，能省就省）。
    --    space 一定是它那块屏正在显示的那一格（不管是鼠标那块还是退回的焦点那块），所以必然命中。
    -- ⚠️ 不用 hs.mouse.getCurrentScreen()：万一上面退回了焦点那一格，鼠标那块屏就不是它所在的屏了。
    for _, screen in ipairs(hs.screen.allScreens()) do
        if hs.spaces.activeSpaceOnScreen(screen) == space.id then return space, screen end
    end

    -- 兜底：CGS 那边对不上就走 uuid（多一次 yabai 查询）
    local screen, screenErr = screenForDisplay(space.display)
    if not screen then return nil, nil, screenErr end
    return space, screen
end

-- 定位「鼠标那块屏 + 它正显示的那一格 + 那个方向的邻居」——【全程不起子进程】
-- ⭐ 为什么不复用上面的 spaceUnderMouse / adjacentSpaceOnDisplay：那两个走 yabai.query，
--    而 yabai.query 是同步 hs.execute（fork 一个 shell + yabai 进程），实测一次要 37~43ms；
--    hs.spaces 走 CGS，实测 activeSpaceOnScreen 2.7ms、spacesForScreen 0.8ms、focusedSpace ~0ms。
--    ⚠️ Hammerspoon 是单线程的：切 space 是快捷键触发的高频动作，主线程被卡住的那段时间里
--       hs.ipc 会直接拒掉请求（控制台刷 "hs.ipc: Instance of [...] already recursing,
--       refusing request."），hotkey / eventtap / 其他 timer 也一起停摆。所以这条路径上
--       能用 hs.spaces 就别用 yabai。（换窗口那条路绕不开 yabai，那边照旧。）
-- ⭐ hs.spaces.spacesForScreen 给的顺序就是 Mission Control 顺序，也就是 yabai 的 index 顺序
--    （实测 display 1 逐项对上：{3,4,7,6,1104,5,8} ↔ index 1..7），所以「邻居」就是数组里
--    前一个 / 后一个；只在本屏的数组里取，天然不会串到隔壁显示器。
-- @param step number  -1 / +1，来自 DIRECTIONS
-- @return table?   { screen, ids, pos, currentId, targetId }；targetId 为 nil = 到边缘了
-- @return string?  错误信息
local function neighborSpaceUnderMouse(step)
    local screen = hs.mouse.getCurrentScreen()
    if not screen then return nil, "拿不到鼠标所在的屏幕" end

    local ids = hs.spaces.spacesForScreen(screen)
    if type(ids) ~= "table" or #ids == 0 then
        return nil, string.format("拿不到屏幕 '%s' 上的 space 列表", screen:name() or "?")
    end

    local currentId = hs.spaces.activeSpaceOnScreen(screen)
    if not currentId then
        return nil, string.format("拿不到屏幕 '%s' 正在显示的 space", screen:name() or "?")
    end

    local pos
    for i, id in ipairs(ids) do
        if id == currentId then pos = i break end
    end
    if not pos then
        return nil, string.format("space %s 不在屏幕 '%s' 的列表里",
            tostring(currentId), screen:name() or "?")
    end

    return {
        screen    = screen,
        count     = #ids,
        pos       = pos,
        currentId = currentId,
        targetId  = ids[pos + step],   -- 越界 = 到边缘，nil
    }
end

-- space id → yabai 的 space index
-- ⚠️ 要起一个 yabai 子进程（~40ms），所以只在真的要用 yabai 命令的时候才调 —— 别放进
--    公共路径，更别放进轮询回调里
-- @return number?   index
-- @return string?   错误信息
local function yabaiIndexForSpace(spaceId)
    local spaces, err = yabai.query("--spaces")
    if not spaces then return nil, err end
    for _, space in ipairs(spaces) do
        if space.id == spaceId then return space.index end
    end
    return nil, string.format("yabai 里找不到 space id %s", tostring(spaceId))
end

-- 方向 → yabai 的 space 选择子
local SPACE_SEL = { left = "prev", right = "next" }

-- 发系统按键时，相邻两个事件之间隔多久（秒）
-- ⚠️ 这个间隔不能省：四个事件一口气 post 出去的话，ctrl 的 flagsChanged 还没生效方向键就到了，
--    结果是「space 没切」+「系统嘟一声」（方向键漏到前台 App 身上，它不认就 NSBeep）。
local KEY_EVENT_GAP = 0.02

-- space 交换 / 切换的状态：连按保护标志 + timer 引用
-- ⚠️ 必须是 module 级变量：① timer 存这儿防 GC，不然回调静默不执行（见 unlock_watcher.lua
--    的同类注释、commit aaeccf0）；② busy 拦住按住快捷键连发 —— 切 space 的系统动画没走完时，
--    yabai 读到的「聚焦 space」和窗口归属都还是旧的，这时候再来一次就会拿着过期状态乱搬。
--    实测过：两次交换隔 2 秒，第二次仍然读到旧状态，搬出来的结果是错的。
local spaceSwap = { busy = false, timers = {} }

-- 把「切一格 space」这个动作发出去 —— 只管发，不判断边缘、也不复查结果。
-- ⚠️ 私有：边缘判断和「切没切成」的复查都在 M.switch_current_space 里，
--    绕过它直接发就会串到隔壁显示器（"yabai" 模式）或者静默失败。
-- @param direction string  "left" 或 "right"（"shortcut" 模式下正好就是方向键的键名）
-- @param method string    "shortcut" 或 "yabai"（调用方已经校验过）
-- @param nb table         neighborSpaceUnderMouse 的结果（要 currentId / targetId / screen）
--
-- ⭐⭐ 两种方式「作用在哪块屏」的规则完全不同，都是实测出来的，这也是这个函数唯一的复杂点：
--   · yabai `space --focus <index>` —— 认的是【明确的 space index】，跟哪块屏有焦点无关，
--     所以永远打在对的那块屏上。⚠️ 但 Mission Control 活动时直接报
--     "cannot focus space because mission-control is active."（rc=1）。
--     ⚠️ 这里【不能】用 prev / next：它们是相对【键盘焦点那一格】算的，鼠标在另一块屏时会切错屏；
--        而且它们还会跨显示器（实测 display 1 最后一格 --focus next 直接跳到 display 2 第一格）。
--   · ⌃← / ⌃→ 系统快捷键 —— 打在哪块屏取决于当时的状态：
--       · Mission Control 活动时 → 跟【鼠标】所在那块屏走（实测：鼠标在 disp2、焦点在 disp1，
--         disp2 的 space 动了，disp1 没动）
--       · Mission Control 没开时 → 跟【键盘焦点】所在那块屏走（实测同样的摆位，动的是 disp1）
--     ⚠️ 不能用 hs.eventtap.keyStroke 发：它走的是「把修饰键 flag 合并进方向键事件」那条捷径
--        （见 hs.eventtap.event.newKeyEvent 的 Notes），实测这种合并事件在 MC 活动时被直接丢掉
--        （发给 Dock 进程也一样无效）。必须按 Apple 文档的正规写法，把 ctrl 的 flagsChanged
--        单独发出来，事件之间还要留 KEY_EVENT_GAP。
--     ⚠️ 前提：系统设置 → 键盘 → 键盘快捷键 → 调度中心里「移到左边/右边一个空间」要开着，
--        关掉的话按键被静默丢弃。
--
-- ⭐ 于是 "shortcut" 模式下按目标屏是不是焦点屏分两条路：
--     · 是焦点屏 → 直接发按键，MC 开着关着都对
--     · 不是焦点屏 → 先试 yabai（MC 没开时它能成，正好补上「按键会打到焦点屏」这个坑）；
--       它报 mission-control is active 就说明 MC 开着，这时再发按键 —— 按键跟鼠标走，也是对的
-- @return boolean  命令有没有发出去（≠ space 真的切了，切没切由调用方复查）
local function postSpaceSwitch(direction, method, nb)
    -- ⚠️ 只有这条分支才需要 yabai 的 index，所以 id → index 的换算放在这里【按需】做，
    --    别提到外面去 —— 那是一个 ~40ms 的子进程，走按键那条路根本用不上
    local function focusByIndex()
        local index, idxErr = yabaiIndexForSpace(nb.targetId)
        if not index then
            print(string.format("[window_control] 换不出 space %s 的 yabai index：%s",
                tostring(nb.targetId), tostring(idxErr)))
            return false
        end

        local ok, err = yabai.command("space", "--focus", index)
        if not ok then
            print(string.format("[window_control] yabai 切到 space %d 没成：%s",
                index, tostring(err)))
        end
        return ok
    end

    -- 四个按键事件用 timer 串起来发
    -- ⚠️ 千万【别】用 hs.timer.usleep 卡着等：Hammerspoon 是单线程的，卡住的这几十毫秒里
    --    hs.ipc 收到的请求会被直接拒掉（控制台刷
    --    "hs.ipc: Instance of [...] already recursing, refusing request."），
    --    hotkey / eventtap / 其他 timer 也一起停摆。doAfter 串发是等效的，而且不占主线程。
    local function pressArrow()
        local ev = hs.eventtap.event
        local steps = {
            function() ev.newKeyEvent(hs.keycodes.map.ctrl, true):post() end,
            function() ev.newKeyEvent(direction, true):post() end,
            function() ev.newKeyEvent(direction, false):post() end,
            function() ev.newKeyEvent(hs.keycodes.map.ctrl, false):post() end,
        }
        local function send(i)
            steps[i]()
            if i >= #steps then return end
            -- ⚠️ timer 存进 spaceSwap.timers 防 GC
            spaceSwap.timers.keys = hs.timer.doAfter(KEY_EVENT_GAP, function() send(i + 1) end)
        end
        send(1)
        return true
    end

    if method == "yabai" then return focusByIndex() end

    -- 键盘焦点是不是就在目标那块屏上？
    -- ⭐ currentId 就是那块屏正在显示的那一格，所以「焦点那一格 == currentId」⇔「焦点就在这块屏」。
    --    用 hs.spaces.focusedSpace() 判断而不是查 yabai —— 它读 CGS，实测 ~0ms，不阻塞主线程。
    if hs.spaces.focusedSpace() ~= nb.currentId then
        print(string.format(
            "[window_control] 目标在屏幕 '%s'，但键盘焦点不在这块屏 —— ⌃%s 会打到焦点那块屏，先试 yabai",
            nb.screen:name() or "?", direction == "right" and "→" or "←"))
        if focusByIndex() then return true end
        print("[window_control] yabai 没成（Mission Control 开着？），改发按键 —— MC 下按键跟鼠标走")
    end

    return pressArrow()
end

-- 切 space 的默认方式（见 postSpaceSwitch）。
-- ⭐ 默认 "shortcut"：Mission Control 活动时只有它管用。不需要在 MC 里用的话
--    改成 "yabai" 更快更准，也可以在调用时单次指定。
local SPACE_SWITCH_METHOD = "shortcut"

-- 等「space 真的切过去了」的上限和轮询间隔（秒）
-- ⚠️ 别改成固定延时后一次性判断 —— 实测 hs.spaces.focusedSpace() 要【约 1.0s】才反映出新的 space
--    （比动画本身慢不少）。之前写死 0.5s 就判定「没切成功」，于是补发 ⌃→，一次交换连跳 3 格
--    （4 → 7），跳到屏幕边缘那下 ⌃→ 没人接，就是那声「嘟」。所以这里改成轮询到真的切过去为止。
local SPACE_SWITCH_TIMEOUT = 2.5
local SPACE_SWITCH_POLL    = 0.05

-- 切 space 最多发几次按键。轮询到超时才算真的丢了，这时补发一次；再不成就放弃，
-- 别一直发 —— 系统快捷键被关掉的话，每发一次就嘟一声
local SPACE_SWITCH_MAX_TRY = 2


local M = {}


-- ============================================
-- toggleApp: 切换应用显示状态
-- 如果目标应用已在最前 → 隐藏
-- 否则 → 启动/切换到它
-- 
-- @param appName string  应用名（如 "Chatbox", "Obsidian"）
-- ============================================
function M.toggleApp(appName)
  local frontApp = hs.application.frontmostApplication()
  if frontApp and frontApp:name() == appName then
    frontApp:hide()
    print(string.format("%s hide",appName))
  else
    M.focus_app(appName)
  end
end

-- ============================================
-- toggleAppByBundleID: 用 Bundle ID 切换（更可靠）
-- ============================================
function M.toggleAppByBundleID(bundleID)
  local frontApp = hs.application.frontmostApplication()
  if frontApp and frontApp:bundleID() == bundleID then
    frontApp:hide()
  else
    hs.application.launchOrFocusByBundleID(bundleID)
  end
end

-- ============================================
-- setAppLayout: 把指定应用的主窗口移动到指定位置
-- @param appName string    应用名
-- @param unitRect table    比例矩形 {x, y, w, h}（0~1）
-- @return boolean          是否成功
-- ============================================
function M.setAppLayout(appName, unitRect)
  local app = getRunningApp(appName)
  if not app then
    print(string.format("[setAppLayout] 应用未运行: %s", appName))
    return false
  end
  
  local win = app:mainWindow()
  if not win then
    print(string.format("[setAppLayout] 应用无窗口: %s", appName))
    return false
  end
  
  win:moveToUnit(unitRect)
  print(string.format("[setAppLayout] %s → %s", appName, hs.inspect(unitRect)))
  return true
end

-- ============================================
-- setAppLayoutPartialUnit: 按屏幕比例调整窗口，只改传了的那几项
-- ⭐ 传 nil 的那一项保持窗口原状 —— 比如「只把宽度改成屏幕中间 1/3，高度不动」
--    是 moveToUnit 表达不了的（它四项全设）。
-- @param appName string  应用名
-- @param unit table      { x = 0~1, y = 0~1, w = 0~1, h = 0~1 }，可以只给其中几项
-- @return boolean        是否成功
-- ============================================
function M.setAppLayoutPartialUnit(appName, unit)
  local app = getRunningApp(appName)
  local win = app and app:mainWindow()
  if not win then
    print(string.format("[setAppLayoutPartialUnit] 拿不到 %s 的窗口", appName))
    return false
  end

  -- screen:frame() 是不含菜单栏 / Dock 的可用区域，和 moveToUnit 用的是同一个基准
  local sf = win:screen():frame()
  local f  = win:frame()

  -- 注意：Lua 里 0 是真值，所以 x = 0 / y = 0 也能正常走 unit 分支
  win:setFrame({
    x = unit.x and (sf.x + sf.w * unit.x) or f.x,
    y = unit.y and (sf.y + sf.h * unit.y) or f.y,
    w = unit.w and (sf.w * unit.w)        or f.w,
    h = unit.h and (sf.h * unit.h)        or f.h,
  })
  print(string.format("[setAppLayoutPartialUnit] %s → %s", appName, hs.inspect(unit)))
  return true
end

--- App 是不是已经就绪：在前台 + 有窗口
-- ⭐ 「在前台」才是关键 —— hs.eventtap.keyStroke 是发给前台 App 的，
--    只判断「窗口出现了」的话，键盘事件可能还打在旧的前台 App 身上。
-- ⚠️ 这是个同步谓词，会被轮询每 READY_POLL 秒调一次，所以里面不能有任何等待。
--    「窗口出现后再缓 READY_SETTLE 秒」那层在 whenAppReady 里做。
-- @param appName string
-- @return boolean
function app_is_ready(appName)
    if invalidAppName(appName) then return false end
    local front = hs.application.frontmostApplication()
    if not front then return false end
    local name = front:name()
    if not name or name ~= appName then return false end
    return front:mainWindow() ~= nil
end

--- 聚焦指定 App —— 对外首选入口
--   · App 有窗口且窗口在【内置屏】上 → 直接 launchOrFocus，让 macOS 自己切过去，窗口不动
--   · 其余情况（窗口在外接屏 / App 没运行 / 窗口被关了）→ 走 focus_app_to_current_space
-- 每次调用都会盯着这个 App 直到它真的在前台且有窗口（最多等 timeout 秒），期间：
--   · ⭐ 只有【窗口是新建的】那次（进来时 App 没窗口）才额外沉降 READY_SETTLE 秒等组件加载；
--     App 本来就开着、只是切前台 / 挪 space 的话，组件早好了，不多等一毫秒
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
        print(string.format("[window_control] 还在等 '%s' 就绪，忽略这次调用", appName))
        hs.alert.show("还在等" .. appName.. "就绪，忽略这次调用")
        return true
    end

    local ok, err
    local app = getRunningApp(appName)
    local win = app and app:mainWindow()
    local info = win and win:id() and getWindowInfo(win:id())

    -- ⭐ 现在没窗口 = 待会儿那个窗口是新建的，需要沉降等组件加载；
    --    已经有窗口就只是切前台 / 挪 space，不用等。
    local settle = win and 0 or READY_SETTLE

    -- 判断不了内置屏的时候不报错，直接落到通用路径
    if info and isBuiltinDisplay(info.display) then
        print(string.format("[window_control] '%s' 在内置屏（space %s），直接 launchOrFocus",
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
    if ok then whenAppReady(appName, onReady, timeout, settle) end
    return ok, err
end

--- 把当前聚焦窗口移到同屏左边 / 右边的 space（焦点留在原地）
-- 到边缘时在本屏内循环：第 1 格往左 → 最后 1 格，最后 1 格往右 → 第 1 格。
-- 绕圈的那一下会弹 alert —— 焦点留在原地，窗口"凭空"跑到另一头很容易让人懵。
-- @param direction string  "left" 或 "right"
-- @return boolean  是否成功
-- @return string?  失败原因
function M.move_focused_window_with_direction(direction)
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

    print(string.format("[window_control] ✅ '%s' 已从 space %d 移到 space %d（屏幕 %d，方向 %s）",
        win.app or "?", win.space, target.index, win.display, direction))

    if wrapped then
        local msg
        if step > 0 then
            msg = string.format("🔄 已到最右一格，绕回第 1 格（space %d → %d）", win.space, target.index)
        else
            msg = string.format("🔄 已到最左一格，绕到最后 1 格（space %d → %d）", win.space, target.index)
        end
        hs.alert.show(msg)
        print("[window_control] " .. msg)
    end

    return true
end

--- 把焦点切到【鼠标所在那块屏幕】上左边 / 右边那一格 space
-- ⭐ 认【鼠标】不认键盘焦点：双显示器下把鼠标移到另一块屏，操作的就是那一块（见 neighborSpaceUnderMouse）。
-- ⭐ 自带边缘判断：本屏那个方向已经没有 space 了就什么都不做（提示一句）。所以外部可以直接调，
--    不用自己先算边界 —— 尤其是 yabai 那条路，它的 prev/next 会跨显示器，全靠这里挡住。
-- ⭐ 发出去之后会【轮询复查】到真的切过去为止，超时才补发（最多 SPACE_SWITCH_MAX_TRY 次）——
--    实测 hs.spaces.focusedSpace() 要约 1.0s 才反映出新 space，用固定延时判断会误判成失败、
--    然后补发按键连跳好几格，跳到边缘那下按键没人接还会「嘟」一声。
-- ⚠️ 因此这个函数是【异步】的：返回值只代表「有没有发起」，切没切成看 onDone。
-- @param direction string    "left" 或 "right"
-- @param method string?      "shortcut"（默认 SPACE_SWITCH_METHOD）或 "yabai"，见 postSpaceSwitch
-- @param onDone function?    收尾回调，签名 onDone(landed:boolean)：
--                            landed = true 真的切过去了；false = 到边缘没切 / 发了几次都没切成
-- @return boolean  是否发起成功（到边缘也算成功，此时 onDone(false) 会被调用）
-- @return string?  失败原因
function M.switch_current_space(direction, method, onDone)
    method = method or SPACE_SWITCH_METHOD

    local step = DIRECTIONS[direction]
    if not step then
        return fail(string.format("方向只能是 left 或 right，收到 '%s'", tostring(direction)))
    end
    if method ~= "shortcut" and method ~= "yabai" then
        return fail(string.format("切 space 的方式只能是 shortcut 或 yabai，收到 '%s'",
            tostring(method)))
    end

    local nb, nbErr = neighborSpaceUnderMouse(step)
    if not nb then return fail(nbErr) end

    if not nb.targetId then
        -- ⭐ 这条路不切 space，所以 alert 当场弹是安全的
        --    （切完再弹会被钉死在旧的那格上，见 CLAUDE.md「别动这些」）
        local msg = string.format("已经是屏幕 '%s' 的%s一格（第 %d/%d 格），不切",
            nb.screen:name() or "?", step > 0 and "最右" or "最左", nb.pos, nb.count)
        print("[window_control] " .. msg)
        hs.alert.show("🔚 " .. msg)
        if onDone then onDone(false) end
        return true
    end

    -- 上一次的复查还挂着就先停掉，免得两个 waitUntil 打架（也顺手避免 timer 泄漏）
    if spaceSwap.timers.switch then
        spaceSwap.timers.switch:stop()
        spaceSwap.timers.switch = nil
    end

    -- ⭐ 复查的是「目标那块屏现在显示的是不是 target」，用 hs.spaces.activeSpaceOnScreen(screen)：
    --    · 不用 hs.spaces.focusedSpace() —— 那是【键盘焦点】那一格。鼠标在另一块屏时它根本不是
    --      我们要看的那一格，会永远判定失败、然后一直补发，把另一块屏一格一格推着走。
    --    · 不用 yabai 查 —— 它在刚切完的一瞬间会返回旧值（实测滞后），MC 活动时更是查不了。
    --      hs.spaces 直接读 CGS，MC 开着也读得到（实测）。
    -- ⚠️ timer 必须存进 spaceSwap.timers，不然会被 GC（见文件里其他同类注释）
    -- ⚠️ 轮询回调里只许放 hs.spaces 这种 ~0ms 的调用，别放 yabai.query（一次 40ms，
    --    50ms 一跳的话主线程基本被占满，hs.ipc 会一直拒请求）
    local function attempt(nth)
        postSpaceSwitch(direction, method, nb)

        local deadline = hs.timer.secondsSinceEpoch() + SPACE_SWITCH_TIMEOUT
        local function arrived()
            return hs.spaces.activeSpaceOnScreen(nb.screen) == nb.targetId
        end

        spaceSwap.timers.switch = hs.timer.waitUntil(
            function() return arrived() or hs.timer.secondsSinceEpoch() > deadline end,
            function()
                if spaceSwap.timers.switch then spaceSwap.timers.switch:stop() end

                if arrived() then
                    if onDone then onDone(true) end
                    return
                end

                if nth >= SPACE_SWITCH_MAX_TRY then
                    print(string.format(
                        "[window_control] ⚠️ 发了 %d 次也没切到屏幕 '%s' 的第 %d 格，放弃"
                        .. "（系统设置 → 键盘 → 键盘快捷键 → 调度中心里"
                        .. "「移到左边/右边一个空间」是不是被关掉了？）",
                        nth, nb.screen:name() or "?", nb.pos + step))
                    if onDone then onDone(false) end
                    return
                end

                print(string.format("[window_control] ⚠️ %.1fs 内没切过去，补发第 %d 次",
                    SPACE_SWITCH_TIMEOUT, nth + 1))
                attempt(nth + 1)
            end,
            SPACE_SWITCH_POLL)
    end

    attempt(1)
    return true
end

--- 把 focused screen 的当前 space 跟同屏左边 / 右边那一格【整批互换窗口】，焦点跟着自己的窗口走
-- ⭐ 为什么是「互换窗口」而不是真的重排 space：本机 SIP 是开着的，而 yabai 的
--    `space --move` / `space --swap` 属于 scripting addition 功能，SIP 开着时会被直接忽略
--    （yabai 原话：requires System Integrity Protection to be partially disabled）。
-- ⚠️ 到边界【不绕圈】，直接什么都不做。整格内容绕圈之后没人能看懂 Mission Control 变成了什么样
--    （move_focused_window_with_direction 会绕圈，那是因为它只挪一个窗口，别照抄）
-- ⚠️ 只在窗口自己那块屏幕的 space 里换，跟本文件其他函数一样不跨显示器
-- ⚠️ 前提：系统设置里「根据最近使用情况自动重新排列空间」必须关掉（mru-spaces = 0），
--    否则 space index 会自己漂移，本函数和 move_focused_window_with_direction 都会变得不可预测
-- @param direction string  "left" 或 "right"
-- @return boolean  是否成功（到边界的空操作也算成功）
-- @return string?  失败原因
function M.swap_space_and_app(direction)
    -- ⭐ 连按保护：上一次的切 space 动画没走完就再来一次，会读到过期状态把窗口搬乱（实测过）
    if spaceSwap.busy then
        print("[window_control] 上一次 space 交换还没走完，忽略这次调用")
        return true
    end

    local step = DIRECTIONS[direction]
    if not step then
        return fail(string.format("方向只能是 left 或 right，收到 '%s'", tostring(direction)))
    end

    -- ⭐ 这里【不用】getFocusedWindow()：它要求当前有聚焦窗口，而空 space、点到桌面都拿不到。
    --    「把两格 space 换一下」跟当前有没有窗口无关。
    -- ⭐ 必须和 switch_current_space 用【同一个】定位方式（都按鼠标那块屏）——
    --    一个按鼠标、一个按键盘焦点的话，双屏下会出现「在 A 屏搬窗口、切的却是 B 屏」的错乱。
    local current, _, curErr = spaceUnderMouse()
    if not current then return fail(curErr) end

    -- ⭐ 边缘判断全交给 adjacentSpaceOnDisplay：它只在本屏的 space 列表里找邻居，
    --    所以 display 1 的最后一格往右、display 2 的第一格往左都是 nil（不会串到隔壁屏幕去）
    local target, targetErr = adjacentSpaceOnDisplay(current.display, current.index, step)
    if targetErr then return fail(targetErr) end
    if not target then
        local msg = string.format("已经是屏幕 %d 的%s一格，没得换",
            current.display, step > 0 and "最右" or "最左")
        print("[window_control] " .. msg)
        hs.alert.show("🔚 " .. msg)
        return true
    end

    -- ⚠️ 别用 filterMovable 把全屏格滤掉再取邻居 —— 那样「右边」的含义会跳过全屏格，
    --    跟 Mission Control 里看到的顺序不一致，比直接报错更让人困惑
    if current["is-native-fullscreen"] or target["is-native-fullscreen"] then
        return fail(string.format("space %d / %d 里有原生全屏，收不了外来窗口，换不了",
            current.index, target.index))
    end

    -- ⭐ 两边都先查完再动手：边查边搬会把刚搬过去的窗口又搬回来
    local curWins, curWinsErr = movableWindowsOnSpace(current.index)
    if not curWins then return fail(curWinsErr) end
    local targetWins, targetWinsErr = movableWindowsOnSpace(target.index)
    if not targetWins then return fail(targetWinsErr) end

    -- ⭐ 原聚焦窗口直接从快照里挑 has-focus 的那个，不用 hs.window.focusedWindow()——
    --    点到桌面时后者返回的是 Finder 的桌面元素（id == 0），拿它去 focus 会聚焦到 Finder。
    --    空 space / 点了桌面时这里就是 nil，跳过重新聚焦即可。
    local focusedId
    for _, win in ipairs(curWins) do
        if win["has-focus"] then focusedId = win.id break end
    end

    -- ⚠️ alert 必须在切 space【之前】发：hs.alert 底层是 hs.canvas，默认 behavior 为 0，
    --    会被钉死在「创建那一瞬间活动的那格 space」上，切过去就看不见了（见 CLAUDE.md）
    local msg = string.format("🔄 space %d ⇄ %d（%d ⇄ %d 个窗口）",
        current.index, target.index, #curWins, #targetWins)
    hs.alert.show(msg)
    print("[window_control] " .. msg)

    spaceSwap.busy = true

    -- 先把眼前这格搬空、再把邻居搬进来 —— 视觉上是「一批换一批」；
    -- 反过来会出现两批窗口短暂叠在同一格上
    local failed = moveWindowsToSpace(curWins, target.index)
        + moveWindowsToSpace(targetWins, current.index)

    print(string.format(
        "[window_control] ✅ 已交换 space %d ⇄ %d（屏幕 %d，方向 %s，搬失败 %d）",
        current.index, target.index, current.display, direction, failed))

    -- 收尾：真正搬失败的（不是上面那些「无视」的）如实报一声，并放掉连按保护
    local function finish()
        spaceSwap.busy = false
        if failed > 0 then
            hs.alert.show(string.format("⚠️ 有 %d 个窗口没搬动，详见控制台", failed))
        end
    end

    -- 切完 space、动画走完之后要做的收尾：抢回焦点 + 放锁
    local function refocusAndFinish()
        -- focusedId 为 nil = 交换前那一格没有聚焦窗口（空 space / 点了桌面），只切格子就够了
        if focusedId then
            local fok, fErr = yabai.command("window", "--focus", focusedId)
            if not fok then
                print(string.format("[window_control] ⚠️ 重新聚焦窗口 %s 失败：%s",
                    tostring(focusedId), tostring(fErr)))
            end
        end
        finish()
    end

    -- 焦点跟着自己的窗口走 —— 它们现在在 target 那一格。
    -- ⭐ 当前格没有窗口（或没有搬得动的窗口）时【照样切过去】：跟有窗口时保持一致，
    --    「按右就是去右边那一格」这条规则不留例外。
    -- ⭐ 边缘判断 + 复查补发都在 switch_current_space 里，这里只管收尾。
    --    它会再查一次当前 space（多一个 ~10ms 子进程）—— 换来的是那个函数可以独立对外用，值。
    -- ⚠️ 它没发起成功的话 onDone 不会被调用，所以这里得自己兜一下，
    --    否则 spaceSwap.busy 永远放不掉，后面所有交换都会被连按保护拦死。
    if not M.switch_current_space(direction, SPACE_SWITCH_METHOD, refocusAndFinish) then
        refocusAndFinish()
    end

    return true
end

-- ============================================
-- resolveSessionHotkey: session 名 → ⌘+数字
-- ⚠️ sessionName 是外部输入（wgestures / hs -c 手敲），认不出来就当场报错，
--    别让 nil 一路漏到 keyStroke 里 —— 那会切完 App 才炸，现场只剩「什么也没发生」。
-- @param sessionName string
-- @return string?  认不出来返回 nil（已提示用户）
-- ============================================
local function resolveSessionHotkey(sessionName)
  local hotkey = common.CHATBOX_SESSION_HOTKEY[sessionName]
  if not hotkey then
    local valid = {}
    for name in pairs(common.CHATBOX_SESSION_HOTKEY) do table.insert(valid, name) end
    table.sort(valid)
    fail(string.format("未知的 Chatbox session: %s（可用：%s）",
                       tostring(sessionName), table.concat(valid, ", ")))
    return nil
  end
  return hotkey
end

-- ============================================
-- pasteClipboardToChatbox: 在 Chatbox 里切到指定 session → 新建对话 → 粘贴 → 发送
-- ⚠️ 不负责切换 App。调用前 Chatbox 必须【已经在前台】，否则这串按键会打到别的 App 上，
--    所以只在 M.focus_app 的 onReady 回调里调它。
-- @param sessionName string  见 common.CHATBOX_SESSION
-- ============================================
function M.pasteClipboardToChatbox(sessionName)
  -- ⭐ 先取好 hotkey 再进 sequence：查表放到 timer 回调里的话，按键那一步还能失败一次
  local hotkey = resolveSessionHotkey(sessionName)
  if not hotkey then return end

  common.sequence({
    {0.2, function() hs.eventtap.keyStroke({"cmd"}, hotkey) end},
    {0.1, function() hs.eventtap.keyStroke({"cmd"}, "i") end},
    {0.1, function() hs.eventtap.keyStroke({"cmd"}, "v") end},
    {0.2, function() hs.eventtap.keyStroke({"cmd"}, "return") end},
  })
end

-- ============================================
-- focusChatboxThenExecute: 聚焦 Chatbox，等它真正就绪后执行 execute(sessionName)
-- ⭐ execute 挂在 focus_app 的就绪回调里，不用固定延时去赌 Chatbox 什么时候起来 ——
--    App 被整个关掉过的话冷启动要好几秒。没能在超时时间内到前台，execute 就不会执行
--    （keyStroke 打到别的 App 上比什么都不做更糟，这条由 focus_app 保证）。
-- @param sessionName string   转发给 execute，见 common.CHATBOX_SESSION
-- @param execute function?    Chatbox 就绪后执行，签名 execute(sessionName)；不传就只聚焦
-- ============================================
function M.focusChatboxThenExecute(sessionName, execute)
  -- ⭐ 校验放在切 App 之前：名字错了就什么都别做，省得切过去再失败
  if not resolveSessionHotkey(sessionName) then return end

  M.focus_app(common.CHATBOX_APP, function()
    if execute then execute(sessionName) end
  end)
end

-- ============================================
-- copyToChatbox: 复制选中 → 切到 Chatbox → 粘贴发送
-- ⭐ 外部入口（wgestures.sendToChatbox）就打在这里，sessionName 是字符串
-- @param sessionName string  见 common.CHATBOX_SESSION
-- ============================================
function M.copyToChatbox(sessionName)
  common.sequence({
    {0,   function() hs.eventtap.keyStroke({"cmd"}, "c") end},
    {0.1, function() M.focusChatboxThenExecute(sessionName, M.pasteClipboardToChatbox) end},
  })
end

return M
