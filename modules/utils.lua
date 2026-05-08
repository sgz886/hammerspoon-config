-- 通用工具函数集合

local M = {}

-- ============================================
-- toggleApp: 切换应用显示状态
-- 如果目标应用已在最前 → 隐藏
-- 否则 → 启动/切换到它
-- 
-- @param appName string  应用名（如 "Chatbox"）
-- ============================================
function M.toggleApp(appName)
  local frontApp = hs.application.frontmostApplication()
  if frontApp and frontApp:name() == appName then
    frontApp:hide()
    print(string.format("%s hide",appName))
  else
    hs.application.launchOrFocus(appName)
    print(string.format("%s launchOrFocus",appName))
  end
end

-- ============================================
-- focusApp: 聚焦应用（不切换隐藏）
-- 如果已在最前 → 什么都不做
-- 否则 → 启动/切换到它
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

-- ============================================
-- sendSelectionToApp: 复制选中 → 切换应用 → 粘贴发送
-- @param appName string  目标应用名
-- ============================================
function M.sendSelectionToApp(appName)
  M.sequence({
    {0,   function() hs.eventtap.keyStroke({"cmd"}, "c") end},
    {0.1, function() hs.application.launchOrFocus(appName) end},
    {0.3, function() hs.eventtap.keyStroke({"cmd"}, "2") end},
    {0.2, function() hs.eventtap.keyStroke({"cmd"}, "I") end},
    {0.2, function() hs.eventtap.keyStroke({"cmd"}, "v") end},
    {0.2, function() hs.eventtap.keyStroke({"cmd"}, "return") end},
  })
end






return M
