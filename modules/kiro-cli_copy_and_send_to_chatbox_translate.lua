local common = require("utils.common")
local window_control = require("utils.window_control")
local M = {}

function M.main()
    common.sequence({
      {0,  function() hs.eventtap.keyStrokes('/copy') end},
      {0.1,  function() hs.eventtap.keyStroke({}, 'return') end},
      {0.1,  function() window_control.focusChatboxThenExecute(common.CHATBOX_SESSION.TRANSLATOR, window_control.pasteClipboardToChatbox) end},
    })
end

return M
