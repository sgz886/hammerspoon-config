-- 通用工具函数集合

local move_window = require("utils.move_window_to_space")

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
    move_window.focus_app(appName)
  end
end

-- ============================================
-- focusApp: 聚焦应用（不切换隐藏）
-- 如果已在最前 → 什么都不做
-- 否则 → 启动/切换到它
-- @param appName string  应用名（如 "Chatbox", "Obsidian"）
-- ============================================
function M.focusApp(appName)
  local frontApp = hs.application.frontmostApplication()
  if frontApp and frontApp:name() == appName then
    return
  end
  hs.application.launchOrFocus(appName)
  print(string.format("%s launchOrFocus",appName))
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

function M.moveWindow(unitRect)
  local win = hs.window.focusedWindow()
  if win then
    win:moveToUnit(unitRect)
  end
end

-- ============================================
-- moveAppWindow: 把指定应用的主窗口移动到指定位置
-- @param appName string    应用名
-- @param unitRect table    比例矩形 {x, y, w, h}（0~1）
-- @return boolean          是否成功
-- ============================================
function M.moveAppWindow(appName, unitRect)
  local app = hs.application.find(appName)
  if not app then
    print(string.format("[moveAppWindow] 应用未运行: %s", appName))
    return false
  end
  
  local win = app:mainWindow()
  if not win then
    print(string.format("[moveAppWindow] 应用无窗口: %s", appName))
    return false
  end
  
  win:moveToUnit(unitRect)
  print(string.format("[moveAppWindow] %s → %s", appName, hs.inspect(unitRect)))
  return true
end

-- ============================================
-- moveAppWindowEnsureRunning: 如果应用没运行就先启动再布局
-- @param appName string
-- @param unitRect table
-- @param delay number|nil   启动后等待秒数（默认 0.5）
-- ============================================
function M.moveAppWindowEnsureRunning(appName, unitRect, delay)
  delay = delay or 0.5
  local app = hs.application.find(appName)
  
  if app and app:mainWindow() then
    -- 已运行且有窗口 → 直接移动
    app:mainWindow():moveToUnit(unitRect)
    print(string.format("%s moveToUnit",appName))
  else
    -- 未运行 → 启动后延迟布局（等窗口出现）
    hs.application.launchOrFocus(appName)
    hs.timer.doAfter(delay, function()
      local a = hs.application.find(appName)
      if a and a:mainWindow() then
        a:mainWindow():moveToUnit(unitRect)
        print(string.format("%s moveToUnit",appName))
      end
    end)
  end
end

-- ============================================
-- sequence: 按顺序执行带延时的步骤
-- @param steps table  形如 {{delay, fn}, {delay, fn}, ...}
-- ============================================
function M.sequence(steps)
  local function runStep(i)
    if i > #steps then return end
    local step = steps[i]
    hs.timer.doAfter(step[1], function()
      step[2]()
      runStep(i + 1)
    end)
  end
  runStep(1)
end

local CHATBOX_APP = "Chatbox"

local session = {
  text_polish = "1",
  translator = "2",
}

-- ============================================
-- pasteClipboardToChatbox: 在 Chatbox 里切到指定 session → 新建对话 → 粘贴 → 发送
-- ⚠️ 不负责切换 App。调用前 Chatbox 必须【已经在前台】，否则这串按键会打到别的 App 上，
--    所以只在 move_window.focus_app 的 onReady 回调里调它。
-- @param sessionName string  text_polish , translator
-- ============================================
function M.pasteClipboardToChatbox(sessionName)
  M.sequence({
    {0.2, function() hs.eventtap.keyStroke({"cmd"}, session[sessionName]) end},
    {0.2, function() hs.eventtap.keyStroke({"cmd"}, "i") end},
    {0.1, function() hs.eventtap.keyStroke({"cmd"}, "v") end},
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
  move_window.focus_app(CHATBOX_APP, function()
    if execute then execute(sessionName) end
  end)
end

-- ============================================
-- copyToChatbox: 复制选中 → 切到 Chatbox → 粘贴发送
-- @param sessionName string  text_polish , translator
-- ============================================
function M.copyToChatbox(sessionName)
  M.sequence({
    {0,   function() hs.eventtap.keyStroke({"cmd"}, "c") end},
    {0.1, function() M.focusChatboxThenExecute(sessionName, M.pasteClipboardToChatbox) end},
  })
end

return M
