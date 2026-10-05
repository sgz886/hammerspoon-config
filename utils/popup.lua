-- utils/popup.lua
-- 可复用的小弹窗（hs.webview 自绘）：多个选项按钮 / 只显示信息 + 关闭按钮
--
-- 用法：
--   popup.choose("dvvp", {
--     {label = "Phonetool",   onSelect = function() ... end},
--     {label = "Google 搜索", onSelect = function() ... end},
--   })
--   popup.message("UTC 时间", "2026/09/24 05:16:20 UTC")
--
-- 交互：鼠标点按钮；键盘 1..9 选对应选项，Esc 关闭，没选项时 Enter 也关闭
-- ⭐ 不阻塞主线程（不同于 hs.dialog.blockAlert），开着弹窗时 hotkey / ipc / timer 照常工作

local M = {}

local HANDLER = "popup"   -- JS 侧 window.webkit.messageHandlers.<HANDLER>
local WIDTH = 380

-- 同一时刻只留一个弹窗
-- current = { webview, options, prevApp }
local current = nil
-- 延后 delete 的 timer，存起来防 GC
local deferred, deferredSeq = {}, 0

local function defer(fn)
  deferredSeq = deferredSeq + 1
  local key = deferredSeq
  deferred[key] = hs.timer.doAfter(0, function()
    deferred[key] = nil
    fn()
  end)
end

local function escapeHtml(s)
  return (tostring(s):gsub("[&<>\"']", {
    ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;",
  }))
end

local function buildHtml(title, body, options, closeLabel)
  local buttons = {}
  for i, opt in ipairs(options) do
    buttons[#buttons + 1] = string.format(
      '<button class="opt" onclick="send(\'select\', %d)"><span class="key">%d</span>%s</button>',
      i, i, escapeHtml(opt.label))
  end

  return string.format([[
<!DOCTYPE html>
<html><head><meta charset="utf-8"><style>
  :root { color-scheme: light dark; }
  body { font: 14px -apple-system, "PingFang SC", sans-serif; margin: 0; padding: 16px 18px;
         -webkit-user-select: none; cursor: default; }
  h1 { font-size: 17px; margin: 0 0 10px; word-break: break-all; -webkit-user-select: text; }
  .body { font: 15px ui-monospace, Menlo, monospace; margin: 0 0 12px; word-break: break-all;
          -webkit-user-select: text; }
  .opt { display: block; width: 100%%; text-align: left; margin: 0 0 8px; padding: 9px 12px;
         font-size: 14px; border-radius: 8px; border: 1px solid #8884; background: #8881; }
  .opt:hover { background: #3478f633; }
  .key { display: inline-block; width: 18px; margin-right: 8px; color: #888; font-weight: 600; }
  .footer { text-align: right; margin-top: 6px; }
  .close { padding: 6px 16px; border-radius: 6px; border: 1px solid #8884; font-size: 13px; }
</style></head><body>
  <h1>%s</h1>
  %s
  %s
  <div class="footer"><button class="close" onclick="send('close')">%s</button></div>
<script>
  const optionCount = %d;
  function send(action, index) {
    window.webkit.messageHandlers.%s.postMessage({action: action, index: index || 0});
  }
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') { send('close'); return; }
    if (e.key === 'Enter' && optionCount === 0) { send('close'); return; }
    const n = parseInt(e.key, 10);
    if (n >= 1 && n <= optionCount) send('select', n);
  });
</script>
</body></html>]],
    escapeHtml(title),
    body and ('<div class="body">' .. escapeHtml(body) .. '</div>') or "",
    table.concat(buttons, "\n"),
    escapeHtml(closeLabel),
    #options,
    HANDLER)
end

-- 关掉当前弹窗
-- @param restoreFocus boolean  true = 把焦点还给弹窗前的 App（选了选项时不还，交给选项自己的动作）
local function closeCurrent(restoreFocus)
  local c = current
  if not c then return end
  current = nil
  -- ⚠️ 可能正处在这个 webview 自己的回调里，delete 挪到下一拍
  defer(function() c.webview:delete() end)
  if restoreFocus and c.prevApp then c.prevApp:activate() end
end

-- 弹窗居中在鼠标所在屏
local function frameOnMouseScreen(height)
  local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  local f = screen:frame()
  return {
    x = f.x + (f.w - WIDTH) / 2,
    y = f.y + (f.h - height) / 2.5,
    w = WIDTH,
    h = height,
  }
end

-- ============================================
-- show: 弹窗核心
-- @param spec table
--   title      string   标题（窗口标题栏 + 正文大字）
--   body       string?  正文（等宽字体，可选中复制）
--   options    table?   {{label = string, onSelect = function}, ...}，最多 9 个（键盘 1..9）
--   closeLabel string?  关闭按钮文字，默认 "关闭"
-- ============================================
function M.show(spec)
  closeCurrent(false)

  local options = spec.options or {}
  local closeLabel = spec.closeLabel or "关闭"
  local height = 110 + (spec.body and 36 or 0) + #options * 46

  local uc = hs.webview.usercontent.new(HANDLER)
  local wv = hs.webview.new(frameOnMouseScreen(height), {developerExtrasEnabled = false}, uc)
  local me = {webview = wv, options = options, prevApp = hs.application.frontmostApplication()}

  uc:setCallback(function(msg)
    if current ~= me then return end
    local body = msg.body or {}
    if body.action == "select" then
      local opt = options[body.index]
      closeCurrent(false)
      if opt and opt.onSelect then
        local ok, err = pcall(opt.onSelect)
        if not ok then
          print(string.format("[popup] ❌ 选项「%s」出错: %s", opt.label, err))
          hs.alert.show("❌ 执行失败: " .. tostring(opt.label))
        end
      end
    else
      closeCurrent(true)
    end
  end)

  wv:windowTitle(spec.title)
    :windowStyle(hs.webview.windowMasks.titled | hs.webview.windowMasks.closable)
    :level(hs.drawing.windowLevels.floating)
    -- ⭐ 跟着当前 Space 走，别被钉在创建时的 Space 上（见 design.md hs.alert 那条坑）
    :behavior(hs.drawing.windowBehaviors.canJoinAllSpaces)
    :allowTextEntry(true)   -- 能成为 key window，才收得到键盘
    :deleteOnClose(true)    -- 点标题栏关闭按钮时直接销毁
    :windowCallback(function(action)
      -- 点了标题栏的红色关闭按钮
      if action == "closing" and current == me then
        current = nil
        if me.prevApp then me.prevApp:activate() end
      end
    end)
    :html(buildHtml(spec.title, spec.body, options, closeLabel))
    :show()
    :bringToFront(true)

  current = me
  -- 把 Hammerspoon 拉到前台并聚焦弹窗，键盘 1/2/Esc 才有效
  defer(function()
    if current ~= me then return end
    hs.focus()
    local win = wv:hswindow()
    if win then win:focus() end
  end)
end

-- 语法糖：多选项
function M.choose(title, options)
  M.show({title = title, options = options})
end

-- 语法糖：只显示信息 + 关闭按钮
function M.message(title, body)
  M.show({title = title, body = body})
end

-- 手动关闭（比如外部想撤掉弹窗）
function M.close()
  closeCurrent(true)
end

return M
