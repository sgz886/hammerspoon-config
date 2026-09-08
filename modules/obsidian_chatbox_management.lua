local common = require("utils.common")
local window_control = require("utils.window_control")
local cursorSelection = require("utils.get_cursor_selected_text")

-- 平铺用的比例矩形
-- Obsidian 只约束横向：贴在屏幕正中间那 1/3，纵向（y / 高度）保持窗口原状，
-- 所以用的是「部分 unit」这种键值形式，不是 moveToUnit 的四元组。
local OBSIDIAN_UNIT = { x = 1 / 3, w = 1 / 3 }
local CHATBOX_RECT  = { 0, 0, 1 / 3, 1 }


local function setAppLayout(appName, unitRect)
  window_control.setAppLayout(appName, unitRect)
end

-- Chatbox 就绪后的两种收尾动作。签名都对齐 focusChatboxThenExecute 的 execute(sessionName)，
-- 所以能直接按引用传过去，不用包闭包。（layoutChatbox 用不到 sessionName，Lua 会忽略多余实参）
local function layoutChatbox()
  setAppLayout(common.CHATBOX_APP, CHATBOX_RECT)
end

local function layoutChatboxAndSend(sessionName)
  layoutChatbox()
  window_control.pasteClipboardToChatbox(sessionName)
end

local M = {}
function M.main()
  local app = hs.application.frontmostApplication()
  local name = app and app:name() or ""

  if name ~= common.OBSIDIAN_APP then
    window_control.focus_app(common.OBSIDIAN_APP)
    return
  end

  -- ── name == Obsidian ──────────────────────────────
  -- 1) 趁 Obsidian 还在前台，读它的选中文本。选中了就直接塞进剪贴板 ——
  --    文本已经在手上，用 hs.pasteboard 比按 ⌘C 更确定，不用等 App 响应。
  local text = cursorSelection.getSelectedText()
  local needSendTextToChatbox = text ~= nil and text ~= ""
  if needSendTextToChatbox then
    hs.pasteboard.setContents(text)
    print(string.format("[obsidian_chatbox] 选中 %d 字，已写入剪贴板", #text))
  else
    print("[obsidian_chatbox] 没有选中文本，只做布局")
  end

  -- 2) Obsidian 就位（只调宽度和横向位置，高度不动）
  window_control.setAppLayoutPartialUnit(common.OBSIDIAN_APP, OBSIDIAN_UNIT)

  -- 3) 切到 Chatbox。布局总要做，发送只在真有选中时才做，都挂在就绪回调里
  local onChatboxReady = needSendTextToChatbox and layoutChatboxAndSend or layoutChatbox
  window_control.focusChatboxThenExecute(common.CHATBOX_SESSION.TEXT_POLISH, onChatboxReady)
end

return M
