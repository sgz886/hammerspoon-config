local M = {}

M.CHATBOX_APP = "Chatbox"
M.OBSIDIAN_APP = "Obsidian"

-- ============================================
-- Chatbox 的 session 名
-- ⭐ 这些值就是对外契约，外部手势 App / 终端直接传字符串进来：
--      hs -c "wgestures.sendToChatbox('text_polish')"
-- ⚠️ 仓库内部一律用 common.CHATBOX_SESSION.XXX 引用，不要再写裸字符串 ——
--    这样 "text_polish" 这个字面量全仓库只出现在下面这一处。
-- ============================================
M.CHATBOX_SESSION = {
  TEXT_POLISH = "text_polish",
  TRANSLATOR  = "translator",
}

-- session 名 → 在 Chatbox 里切过去的 ⌘+数字（= 侧边栏里的序号）
-- 键写成 CHATBOX_SESSION.XXX 而不是裸字符串，所以这张表的键不可能拼错
M.CHATBOX_SESSION_HOTKEY = {
  [M.CHATBOX_SESSION.TEXT_POLISH] = "1",
  [M.CHATBOX_SESSION.TRANSLATOR]  = "2",
}

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

return M