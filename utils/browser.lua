-- utils/browser.lua
-- 浏览器相关的薄封装

local M = {}

M.CHROME_APP = "Google Chrome"

-- 正在跑的 open 进程，存起来防 GC（见 design.md「GC 陷阱」）
local tasks, taskSeq = {}, 0

-- 兜底：`open -na "Google Chrome" --args --new-window <url>`
-- ⚠️ 慢：-n 每次都新起一个完整的 Chrome 进程，它再把 URL 转交给已在跑的 Chrome 后退出。
--    空闲后 Chrome 框架被换出内存 + Falcon 等端点安全软件扫描新进程，冷的时候要 5 秒以上
local function openViaOpenCommand(url)
  taskSeq = taskSeq + 1
  local key = taskSeq
  local task = hs.task.new("/usr/bin/open", function(exitCode, _, stdErr)
    tasks[key] = nil
    if exitCode ~= 0 then
      print(string.format("[browser] ❌ open 失败 (%d): %s", exitCode, stdErr or ""))
      hs.alert.show("❌ 打开 Chrome 失败")
    end
  end, {"-na", M.CHROME_APP, "--args", "--new-window", url})
  tasks[key] = task
  task:start()
end

-- 让已在跑的 Chrome 自己新建窗口（Apple Event，不起新进程），返回 false = 需要回退 open -na
-- ⭐ 首次会弹「Hammerspoon 想要控制 Google Chrome」，要允许（系统设置 → 隐私与安全性 → 自动化）
-- ⚠️ hs.osascript 是同步的，timeout 防 Chrome 卡死时把 Hammerspoon 主线程一起卡住
local function openViaAppleScript(url)
  local escaped = url:gsub("\\", "\\\\"):gsub('"', '\\"')
  local ok, _, err = hs.osascript.applescript(string.format([[
    with timeout of 3 seconds
      tell application "%s"
        set w to make new window
        set URL of active tab of w to "%s"
        activate
      end tell
    end timeout
  ]], M.CHROME_APP, escaped))
  if ok then return true end
  -- ⚠️ 超时（-1712）只是不等了，Chrome 多半还会照做；这时再 open -na 会多开一个窗口，
  --    而且 Chrome 真卡死的话 open -na 转交过去也一样卡，所以超时不回退
  if err and err.OSAScriptErrorNumberKey == -1712 then
    print("[browser] ⚠️ AppleScript 超时，不回退 open -na（避免重复开窗口）")
    return true
  end
  print(string.format("[browser] ⚠️ AppleScript 打开失败，改用 open -na: %s", hs.inspect(err)))
  return false
end

-- ============================================
-- openInNewChromeWindow: 新开一个 Chrome 窗口打开 url
-- ⭐ Chrome 在跑就走 AppleScript（快），没在跑或失败再走 open -na（会顺带启动 Chrome）
-- @param url string  完整 URL（调用方负责 encode）
-- ============================================
function M.openInNewChromeWindow(url)
  print(string.format("[browser] 新窗口打开: %s", url))
  if hs.application.get(M.CHROME_APP) and openViaAppleScript(url) then return end
  openViaOpenCommand(url)
end

-- ============================================
-- encode: URL query 编码（空格 → %20 等）
-- ============================================
function M.encode(s)
  return hs.http.encodeForQuery(s)
end

return M
