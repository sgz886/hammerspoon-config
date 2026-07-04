local utils = require("modules.utils")
local M = {}

function M.main()
    utils.sequence({
      {0,  function() hs.eventtap.keyStrokes('/copy') end},
      {0.1,  function() hs.eventtap.keyStroke({}, 'return') end},
      {0,  function() utils.sendSelectionToChatBoxSession("translator") end},
    })
end

return M
