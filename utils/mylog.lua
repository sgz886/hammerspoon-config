local M = {}

-- Level name -> numeric severity. Higher number = more verbose.
local LEVELS = {
    nothing = 0,
    error   = 1,
    warn    = 2,
    info    = 3,
    debug   = 4,
    verbose = 5,
}

local function fmtTime()
    local t  = hs.timer.secondsSinceEpoch()
    local ms = math.floor((t % 1) * 1000)
    return string.format("%s.%03d", os.date("%H:%M:%S", math.floor(t)), ms)
end

local function toLevel(lvl)
    if type(lvl) == "number" then return lvl end
    return LEVELS[lvl] or LEVELS.info
end

function M.new(id, level)
    local self = {
        id    = id,
        level = toLevel(level or "debug"),
    }

    local function log(lvlNum, lvlName, ...)
        if lvlNum > self.level then return end          -- <-- the filter
        local args = { ... }
        for i, v in ipairs(args) do args[i] = tostring(v) end
        print(string.format("%s [%-5s] %s: %s",
            fmtTime(), lvlName, self.id, table.concat(args, " ")))
    end

    self.e  = function(...)      log(LEVELS.error,   "ERROR", ...) end
    self.w  = function(...)      log(LEVELS.warn,    "WARN",  ...) end
    self.i  = function(...)      log(LEVELS.info,    "INFO",  ...) end
    self.d  = function(...)      log(LEVELS.debug,   "DEBUG", ...) end
    self.v  = function(...)      log(LEVELS.verbose, "VERB",  ...) end

    self.ef = function(fmt, ...) log(LEVELS.error,   "ERROR", string.format(fmt, ...)) end
    self.wf = function(fmt, ...) log(LEVELS.warn,    "WARN",  string.format(fmt, ...)) end
    self.f  = function(fmt, ...) log(LEVELS.info,    "INFO",  string.format(fmt, ...)) end
    self.df = function(fmt, ...) log(LEVELS.debug,   "DEBUG", string.format(fmt, ...)) end
    self.vf = function(fmt, ...) log(LEVELS.verbose, "VERB",  string.format(fmt, ...)) end

    -- Allow changing level at runtime, mirroring hs.logger's API
    self.setLogLevel = function(lvl) self.level = toLevel(lvl) end
    self.getLogLevel = function()    return self.level end

    return self
end

return M
