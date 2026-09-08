local M = {}

M.CHATBOX_APP = "Chatbox"
M.OBSIDIAN_APP = "Obsidian"

M.CHATBOX_SESSION = {
  text_polish = "1",
  translator = "2",
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