-- ============================================================
-- 用 yabai 在 space 之间安排窗口。公开函数：
--   · focus_app(appName, onReady?, timeout?)  ⭐ 聚焦 App 的唯一入口（含连按保护 + 就绪等待）
--   · move_focused_window_with_direction(direction)          把当前聚焦窗口移到同屏左边 / 右边的 space，焦点留在原地
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

-- todo: replace with hammerspoon built-in
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


-- 失败的统一出口：控制台留日志，屏幕上给一眼能看懂的提示
local function fail(reason)
    print(string.format("[window_control] ❌ %s", reason))
    hs.alert.show("⚠️ " .. reason)
    return false, reason
end


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

-- ============================================
-- pasteClipboardToChatbox: 在 Chatbox 里切到指定 session → 新建对话 → 粘贴 → 发送
-- ⚠️ 不负责切换 App。调用前 Chatbox 必须【已经在前台】，否则这串按键会打到别的 App 上，
--    所以只在 M.focus_app 的 onReady 回调里调它。
-- @param sessionName string  text_polish , translator
-- ============================================
function M.pasteClipboardToChatbox(sessionName)
  common.sequence({
    {0.2, function() hs.eventtap.keyStroke({"cmd"}, common.CHATBOX_SESSION[sessionName]) end},
    {0.2, function() hs.eventtap.keyStroke({"cmd"}, "v") end},
    {0.2, function() hs.eventtap.keyStroke({"cmd"}, "return") end},
  })
end

-- ============================================
-- focusChatboxThenExecute: 聚焦 Chatbox，等它真正就绪后执行 execute(sessionName)
-- ⭐ execute 挂在 focus_app 的就绪回调里，不用固定延时去赌 Chatbox 什么时候起来 ——
--    App 被整个关掉过的话冷启动要好几秒。没能在超时时间内到前台，execute 就不会执行
--    （keyStroke 打到别的 App 上比什么都不做更糟，这条由 focus_app 保证）。
-- @param sessionName string   转发给 execute，见 session 表
-- @param execute function?    Chatbox 就绪后执行，签名 execute(sessionName)；不传就只聚焦
-- ============================================
function M.focusChatboxThenExecute(sessionName, execute)
  M.focus_app(common.CHATBOX_APP, function()
    if execute then execute(sessionName) end
  end)
end

-- ============================================
-- copyToChatbox: 复制选中 → 切到 Chatbox → 粘贴发送
-- @param sessionName string  text_polish , translator
-- ============================================
function M.copyToChatbox(sessionName)
  common.sequence({
    {0,   function() hs.eventtap.keyStroke({"cmd"}, "c") end},
    {0.1, function() M.focusChatboxThenExecute(sessionName, M.pasteClipboardToChatbox) end},
  })
end

return M
