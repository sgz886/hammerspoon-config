-- modules/clipboard_action.lua
-- 选中文字 → ⌘C → trim → 按模式分派动作
-- ⭐ 外部入口：wgestures.clipboardAction()（init.lua），WGestures 里用 `hs -q -c 'wgestures.clipboardAction()'`
-- ⭐ 规则在 modules/clipboard_action_rules.lua，这里只管流程

local rules = require("modules.clipboard_action_rules")

local M = {}

local COPY_TIMEOUT = 0.6   -- 等 ⌘C 写进剪贴板的最长时间（秒）

-- 等剪贴板的两个 timer，存起来防 GC；waitUntil 非 nil 也就是「正在等」的锁
local copyTimers = {waitUntil = nil, guard = nil}

local function stopCopyTimers()
  for k, t in pairs(copyTimers) do
    t:stop()
    copyTimers[k] = nil
  end
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ============================================
-- match: 返回命中的规则（第二个返回值是 captures）
-- ⭐ 控制台测规则用：require("modules.clipboard_action").match("dvvp").name
-- ============================================
function M.match(text)
  for _, rule in ipairs(rules) do
    local captures = rule.match(text)
    if captures ~= nil then return rule, captures end
  end
end

-- ============================================
-- dispatch: 对一段（已 trim 的）文本执行命中规则的动作
-- ============================================
function M.dispatch(text)
  local rule, captures = M.match(text)
  if not rule then return end
  print(string.format("[clipboard_action] 命中规则 %s: %q", rule.name, text))
  local ok, err = pcall(rule.action, text, captures)
  if not ok then
    print(string.format("[clipboard_action] ❌ 规则 %s 执行出错: %s", rule.name, err))
    hs.alert.show("❌ 规则 " .. rule.name .. " 执行出错")
  end
end

-- 读剪贴板 → trim → dispatch
-- @param emptyMsg string  剪贴板里没有文字时的提示
local function dispatchClipboard(emptyMsg)
  local text = trim(hs.pasteboard.getContents() or "")
  if text == "" then
    hs.alert.show(emptyMsg)
    return
  end
  M.dispatch(text)
end

-- ============================================
-- run: 主入口。⌘C 复制前台选中 → 等剪贴板变化 → trim → dispatch
-- ⭐ 用 changeCount 判断「真的复制到了」，而不是固定延时
-- ⭐ 超时剪贴板也没变（多半是没选中文字）时，不放弃，拿剪贴板里现有的内容照样走规则 ——
--    方便先在别处复制好，再来触发
-- ============================================
function M.run()
  -- 连发保护：上一次还在等剪贴板，静默丢掉（见 design.md 的 ipc 崩溃那节）
  if copyTimers.waitUntil then return end

  local before = hs.pasteboard.changeCount()
  hs.eventtap.keyStroke({"cmd"}, "c")

  -- ⚠️ waitUntil 的谓词抛错 = 整个等待静默死掉，所以谓词 pcall + 另配兜底 timer
  copyTimers.waitUntil = hs.timer.waitUntil(function()
    local ok, changed = pcall(function() return hs.pasteboard.changeCount() ~= before end)
    return ok and changed
  end, function()
    stopCopyTimers()
    dispatchClipboard("⚠️ 选中的内容不是文字")
  end, 0.02)

  copyTimers.guard = hs.timer.doAfter(COPY_TIMEOUT, function()
    stopCopyTimers()
    print("[clipboard_action] ⚠️ ⌘C 之后剪贴板没变化，改用剪贴板现有内容")
    hs.alert.show("⚠️ 可能未选择文字,继续使用剪贴板执行动态行为")
    dispatchClipboard("⚠️ 剪贴板里也没有文字")
  end)
end

return M
