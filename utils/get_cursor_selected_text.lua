-- modules/test_copy.lua
-- Test module for detecting selected text in the focused window
-- using the macOS Accessibility API via hs.axuielement.

local M = {}

local axuielement = require("hs.axuielement")

--- Get the currently selected text in the focused UI element of the frontmost app.
-- @return string|nil  The selected text, or nil if nothing is selected / not supported.
-- @return string|nil  An error/diagnostic message when the result is nil.
function M.alertSelectedText()
    local app = hs.application.frontmostApplication()
    if not app then
        return nil, "No frontmost application"
    end

    local axApp = axuielement.applicationElement(app)
    if not axApp then
        return nil, "Could not get AX element for app: " .. app:name()
    end

    local focused = axApp:attributeValue("AXFocusedUIElement")
    if not focused then
        return nil, "No focused UI element in " .. app:name()
    end

    local selected = focused:attributeValue("AXSelectedText")
    if selected == nil then
        return nil, "App '" .. app:name() .. "' does not expose AXSelectedText"
    end
    if selected == "" then
        return nil, "No text selected"
    end

    return selected
end

function M.getSelectedText()
    local app = hs.application.frontmostApplication()
    if not app then
        return nil
    end
    local axApp = axuielement.applicationElement(app)
    if not axApp then
        return nil
    end
    local focused = axApp:attributeValue("AXFocusedUIElement")
    if not focused then
        return nil
    end
    return focused:attributeValue("AXSelectedText")
end

--- Test helper: shows an alert with the result.
function M.test()
    local text, err = M.alertSelectedText()
    local app = hs.application.frontmostApplication()
    local appName = app and app:name() or "unknown"

    if text then
        print(string.format("[test_copy] App: %s | Selected: %q", appName, text))
        hs.alert.show("Selected in " .. appName .. ":\n" .. text:sub(1, 100))
    else
        print(string.format("[test_copy] App: %s | No selection (%s)", appName, err or "unknown"))
        hs.alert.show("No selection in " .. appName .. "\n(" .. (err or "?") .. ")")
    end
end

--- Bind a hotkey to run the test. Default: Cmd+Alt+T
function M.bindHotkey(mods, key)
    mods = mods or {"cmd", "alt"}
    key  = key  or "t"
    hs.hotkey.bind(mods, key, function() M.test() end)
    print(string.format("[test_copy] Hotkey bound: %s+%s", table.concat(mods, "+"), key))
end

return M
