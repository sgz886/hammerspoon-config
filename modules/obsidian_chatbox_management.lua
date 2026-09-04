local utils = require("modules.utils")
local cursorSelection = require("utils.get_cursor_selected_text")
local move_window = require("utils.move_window_to_space")

-- 平铺用的比例矩形
local OBSIDIAN_RECT = { 1 / 3, 1 / 2, 1 / 3, 1 / 2 }
local CHATBOX_RECT  = { 0, 0, 1 / 3, 1 }

local CHATBOX_SESSION = "text_polish"

local function setAppLayout(appName, unitRect)
  utils.moveAppWindowEnsureRunning(appName, unitRect)
end

-- Chatbox 就绪后的两种收尾动作。签名都对齐 focusChatboxThenExecute 的 execute(sessionName)，
-- 所以能直接按引用传过去，不用包闭包。（layoutChatbox 用不到 sessionName，Lua 会忽略多余实参）
local function layoutChatbox()
  setAppLayout("Chatbox", CHATBOX_RECT)
end

local function layoutChatboxAndSend(sessionName)
  layoutChatbox()
  utils.pasteClipboardToChatbox(sessionName)
end

local M = {}
function M.main()
  local app = hs.application.frontmostApplication()
  local name = app and app:name() or ""

  if name ~= "Obsidian" then
    move_window.focus_app("Obsidian")
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

  -- 2) Obsidian 就位
  setAppLayout("Obsidian", OBSIDIAN_RECT)

  -- 3) 切到 Chatbox。布局总要做，发送只在真有选中时才做，都挂在就绪回调里
  local onChatboxReady = needSendTextToChatbox and layoutChatboxAndSend or layoutChatbox
  utils.focusChatboxThenExecute(CHATBOX_SESSION, onChatboxReady)
end

return M