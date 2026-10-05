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
--
-- ⭐ 性能（2026-10-05 实测后重写）：
--   · 全程只有【一个】webview，启动时 warmup() 建好并加载页面骨架，之后一直复用（hide / show），
--     每次弹窗只用 evaluateJavaScript 调 render(...) 换内容 —— 不再每次新建 WKWebView + 重新加载页面
--   · JS 渲染完、量好高度后回消息，Lua 这时才摆好 frame 再 show —— 窗口一出现内容就在，不会先白一下
--   · ⚠️ 别用 wv:hswindow() / hs.window:focus() 聚焦弹窗：它走 Accessibility 查询 Hammerspoon【自己】
--     的窗口，而回答这个查询的正是被占着的主线程，实测 80ms ~ 3.1s 不等，整段时间主线程卡死
--     （页面加载回调也跟着被推迟）。hs.focus() 激活 Hammerspoon 只要 1~5ms，show() 本身会让窗口成为 key window

local M = {}

local HANDLER = "popup"   -- JS 侧 window.webkit.messageHandlers.<HANDLER>
local WIDTH = 460
local TITLEBAR_H = 32       -- titled 窗口标题栏高度（28 实测会差几像素冒出滚动条）
local RENDER_TIMEOUT = 1.5  -- render 后这么久没回 rendered，就认为 webview 坏了，重建

-- 常驻的 webview
local wv, uc = nil, nil
local pageReady = false     -- 页面骨架是否加载完（render 函数可用）
local pendingPayload = nil  -- 页面还没加载完时先存着，loaded 之后补发

-- 当前弹窗：{ seq, options, prevApp, shown }
-- seq 用来丢掉旧弹窗迟到的消息
local current, seq = nil, 0
local renderGuard = nil     -- 存起来防 GC

-- ────────────────────────────────────────────
-- 页面骨架：内容全部由 render(spec) 用 textContent 填，不用拼 HTML，也就不用 escape
-- ────────────────────────────────────────────
local SHELL = [[
<!DOCTYPE html>
<html><head><meta charset="utf-8"><style>
  :root { color-scheme: light dark; }
  html, body { margin: 0; overflow: hidden; }
  body { font: 14px -apple-system, "PingFang SC", sans-serif; -webkit-user-select: none; cursor: default; }
  #root { padding: 16px 18px; }
  h1 { font-size: 17px; margin: 0 0 10px; word-break: break-all; -webkit-user-select: text; }
  .body { font: 15px ui-monospace, Menlo, monospace; margin: 0 0 12px; word-break: break-all;
          white-space: pre-wrap; line-height: 1.6; -webkit-user-select: text; }
  .opt { display: block; width: 100%; text-align: left; margin: 0 0 8px; padding: 9px 12px;
         font-size: 14px; border-radius: 8px; border: 1px solid #8884; background: #8881; }
  .opt:hover { background: #3478f633; }
  .key { display: inline-block; width: 18px; margin-right: 8px; color: #888; font-weight: 600; }
  .footer { text-align: right; margin-top: 6px; }
  .close { padding: 6px 16px; border-radius: 6px; border: 1px solid #8884; font-size: 13px; }
</style></head><body><div id="root"></div>
<script>
  let cur = { seq: 0, optionCount: 0 };
  function send(msg) { window.webkit.messageHandlers.]] .. HANDLER .. [[.postMessage(msg); }

  function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined) e.textContent = text;
    return e;
  }

  function render(spec) {
    // Lua 的空表 hs.json.encode 出来可能是 {}，统一成数组
    const options = Array.isArray(spec.options) ? spec.options : [];
    cur = { seq: spec.seq, optionCount: options.length };
    const root = document.getElementById('root');
    root.replaceChildren();
    root.appendChild(el('h1', null, spec.title));
    if (spec.body) root.appendChild(el('div', 'body', spec.body));
    options.forEach((label, i) => {
      const b = el('button', 'opt');
      b.appendChild(el('span', 'key', String(i + 1)));
      b.appendChild(document.createTextNode(label));
      b.onclick = () => send({ action: 'select', seq: cur.seq, index: i + 1 });
      root.appendChild(b);
    });
    const footer = el('div', 'footer');
    const close = el('button', 'close', spec.closeLabel);
    close.onclick = () => send({ action: 'close', seq: cur.seq });
    footer.appendChild(close);
    root.appendChild(footer);
    // ⚠️ 别用 requestAnimationFrame 等排版：窗口隐藏时它不触发（实测要等 show 之后才跑），
    //    而我们正是要先量好高度再 show。读 offsetHeight 会同步强制排版，隐藏时也准
    send({ action: 'rendered', seq: cur.seq, height: root.offsetHeight });
  }

  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' || (e.key === 'Enter' && cur.optionCount === 0)) {
      send({ action: 'close', seq: cur.seq }); return;
    }
    const n = parseInt(e.key, 10);
    if (n >= 1 && n <= cur.optionCount) send({ action: 'select', seq: cur.seq, index: n });
  });

  send({ action: 'loaded' });
</script>
</body></html>]]

-- 弹窗居中在鼠标所在屏
local function frameOnMouseScreen(contentHeight)
  local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  local f = screen:frame()
  local h = contentHeight + TITLEBAR_H
  return {x = f.x + (f.w - WIDTH) / 2, y = f.y + (f.h - h) / 2.5, w = WIDTH, h = h}
end

local function stopRenderGuard()
  if renderGuard then renderGuard:stop(); renderGuard = nil end
end

-- 收起当前弹窗（webview 不销毁，留着下次复用）
-- @param restoreFocus boolean  true = 把焦点还给弹窗前的 App（选了选项时不还，交给选项自己的动作）
local function hideCurrent(restoreFocus)
  local c = current
  if not c then return end
  current = nil
  stopRenderGuard()
  if wv then wv:hide() end
  if restoreFocus and c.shown and c.prevApp then c.prevApp:activate() end
end

local function sendRender(payload)
  if not pageReady then
    pendingPayload = payload
    return
  end
  wv:evaluateJavaScript("render(" .. hs.json.encode(payload) .. ")")
end

local createWebview   -- 前向声明：onMessage 里出错时要重建

local function onMessage(msg)
  local body = msg.body or {}
  local action = body.action

  if action == "loaded" then
    pageReady = true
    if pendingPayload then
      local p = pendingPayload
      pendingPayload = nil
      sendRender(p)
    end
    return
  end

  -- 下面都是针对某一次弹窗的消息，seq 对不上就是旧弹窗迟到的，丢掉
  local c = current
  if not c or body.seq ~= c.seq then return end

  if action == "rendered" then
    stopRenderGuard()
    c.shown = true
    wv:frame(frameOnMouseScreen(body.height or 120))
    wv:show():bringToFront(true)
    -- 把 Hammerspoon 拉到前台，键盘 1/2/Esc 才有效（别用 hswindow():focus()，见文件头）
    hs.focus()
  elseif action == "select" then
    local opt = c.options[body.index]
    hideCurrent(false)
    if opt and opt.onSelect then
      local ok, err = pcall(opt.onSelect)
      if not ok then
        print(string.format("[popup] ❌ 选项「%s」出错: %s", opt.label, err))
        hs.alert.show("❌ 执行失败: " .. tostring(opt.label))
      end
    end
  elseif action == "close" then
    hideCurrent(true)
  end
end

createWebview = function()
  if wv then wv:delete() end
  pageReady = false
  uc = hs.webview.usercontent.new(HANDLER)
  uc:setCallback(onMessage)
  wv = hs.webview.new(frameOnMouseScreen(120), {developerExtrasEnabled = false}, uc)
  -- ⚠️ 不给 closable：标题栏关闭会把 webview 关掉，没法复用；关闭走页面里的按钮 / Esc
  wv:windowStyle(hs.webview.windowMasks.titled)
    :level(hs.drawing.windowLevels.floating)
    -- ⭐ 跟着当前 Space 走，别被钉在创建时的 Space 上（见 design.md hs.alert 那条坑）
    :behavior(hs.drawing.windowBehaviors.canJoinAllSpaces)
    :allowTextEntry(true)   -- 能成为 key window，才收得到键盘
    :html(SHELL)
end

-- ============================================
-- warmup: 提前建好 webview 并加载骨架（init.lua 启动时调一次）
-- 不调也能用，只是第一次弹窗会慢一点
-- ============================================
function M.warmup()
  if not wv then createWebview() end
end

-- ============================================
-- show: 弹窗核心
-- @param spec table
--   title      string   标题（窗口标题栏 + 正文大字）
--   body       string?  正文（等宽字体，可选中复制，支持 \n）
--   options    table?   {{label = string, onSelect = function}, ...}，最多 9 个（键盘 1..9）
--   closeLabel string?  关闭按钮文字，默认 "关闭"
-- ============================================
function M.show(spec)
  -- 换内容前先收起旧的，免得看到旧内容闪一下
  local prevApp = current and current.prevApp or hs.application.frontmostApplication()
  hideCurrent(false)
  M.warmup()

  local options = spec.options or {}
  local labels = {}
  for i, opt in ipairs(options) do labels[i] = tostring(opt.label) end

  seq = seq + 1
  current = {seq = seq, options = options, prevApp = prevApp, shown = false}
  local payload = {
    seq = seq,
    title = tostring(spec.title or ""),
    body = spec.body and tostring(spec.body) or nil,
    options = labels,
    closeLabel = spec.closeLabel or "关闭",
  }

  wv:windowTitle(payload.title)
  sendRender(payload)

  -- 兜底：webview 的网页进程可能被系统回收 / 卡死，没回 rendered 就重建一次再发
  local mySeq = seq
  renderGuard = hs.timer.doAfter(RENDER_TIMEOUT, function()
    renderGuard = nil
    if not current or current.seq ~= mySeq or current.shown then return end
    print("[popup] ⚠️ render 超时，重建 webview")
    createWebview()
    sendRender(payload)
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
  hideCurrent(true)
end

return M
