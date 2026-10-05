-- utils/browser.lua
-- 浏览器相关的薄封装

local M = {}

M.CHROME_APP = "Google Chrome"

-- 正在跑的 open 进程，存起来防 GC（见 design.md「GC 陷阱」）
local tasks, taskSeq = {}, 0

-- ============================================
-- openInNewChromeWindow: 新开一个 Chrome 窗口打开 url
-- ⭐ 走 `open -na "Google Chrome" --args --new-window <url>`：Chrome 已在跑时
--    也会转交给现有进程开新窗口，不会起第二个 Chrome
-- @param url string  完整 URL（调用方负责 encode）
-- ============================================
function M.openInNewChromeWindow(url)
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
  print(string.format("[browser] 新窗口打开: %s", url))
end

-- ============================================
-- encode: URL query 编码（空格 → %20 等）
-- ============================================
function M.encode(s)
  return hs.http.encodeForQuery(s)
end

return M
