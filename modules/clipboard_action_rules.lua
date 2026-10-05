-- modules/clipboard_action_rules.lua
-- 选中文字 → 按模式分派动作 的【规则表】
--
-- ⭐ 加规则 / 改规则只改这个文件。流程（⌘C、trim、分派）在 modules/clipboard_action.lua
--
-- 每条规则：
--   name   string                      日志里显示的名字
--   match  function(text) -> captures  命中返回一个非 nil 值（会原样传给 action），不命中返回 nil
--   action function(text, captures)    用下面的动作工厂生成，也可以手写
-- 规则从上往下匹配，第一条命中的执行（顺序即优先级），最后一条 fallback 永远命中。

local browser = require("utils.browser")
local popup = require("utils.popup")

-- ────────────────────────────────────────────
-- URL 模板（%s = 规则的 captures 或原文）
-- ────────────────────────────────────────────
local URL = {
  CASE      = "https://command-center.support.aws.a2z.com/case-console#/cases/%s/correspondences",
  PHONETOOL = "https://atoz.amazon.work/phonetool/users/%s",
  TICKET    = "https://t.corp.amazon.com/%s/communication",
  HARBINGER = "https://command-center.support.aws.a2z.com/harbinger-notices#/%s/details/overview",
  GOOGLE    = "https://www.google.com/search?q=%s",
}

-- ────────────────────────────────────────────
-- 动作工厂：都返回 function(text, captures)
-- ────────────────────────────────────────────

-- 取 action 要用的值：match 返回字符串就用它，否则用原文
local function valueOf(text, captures)
  return type(captures) == "string" and captures or text
end

-- 新开 Chrome 窗口打开 template
-- @param encode boolean?  true = 先 URL 编码（搜索词之类的自由文本要开）
local function openUrl(template, encode)
  return function(text, captures)
    local v = valueOf(text, captures)
    if encode then v = browser.encode(v) end
    browser.openInNewChromeWindow(string.format(template, v))
  end
end

-- 弹窗让用户选，每个选项本身也是一个动作（可组合）
-- @param options {{label = string, action = 动作}, ...}
local function choose(options)
  return function(text, captures)
    local items = {}
    for i, opt in ipairs(options) do
      items[i] = {label = opt.label, onSelect = function() opt.action(text, captures) end}
    end
    popup.choose(valueOf(text, captures), items)
  end
end

-- 弹窗只显示一段信息 + 关闭按钮
-- @param title  string
-- @param render function(text, captures) -> string  要显示的内容
local function showMessage(title, render)
  return function(text, captures)
    popup.message(title, render(text, captures))
  end
end

-- ────────────────────────────────────────────
-- 小工具
-- ────────────────────────────────────────────

local EPOCH_MIN = 1230768000   -- 2009-01-01 00:00:00 UTC

-- 秒级时间戳是否「像真的」：2009 年以后、不超过现在 + 1 年
local function isPlausibleEpoch(sec)
  return sec >= EPOCH_MIN and sec <= os.time() + 365 * 24 * 3600
end

-- 10 位（秒）或 13 位（毫秒）数字串 → "yyyy/mm/dd hh:mm:ss[.mmm] UTC"
local function formatUtc(digits)
  local sec = tonumber(digits:sub(1, 10))
  local s = os.date("!%Y/%m/%d %H:%M:%S", sec)
  if #digits == 13 then s = s .. "." .. digits:sub(11, 13) end
  return s .. " UTC"
end

local function isDigits(s, ...)
  if not s:match("^%d+$") then return false end
  for _, n in ipairs({...}) do
    if #s == n then return true end
  end
  return false
end

-- ────────────────────────────────────────────
-- 规则表（顺序即优先级）
-- ────────────────────────────────────────────
return {
  {
    -- 15 位数字，前 10 位是 UNIX 时间戳。例：179020498000189
    name = "case_id",
    match = function(t)
      if isDigits(t, 15) and isPlausibleEpoch(tonumber(t:sub(1, 10))) then return t end
    end,
    action = openUrl(URL.CASE),
  },
  {
    -- 亚马逊邮箱，取 @ 前面的 alias。例：dvvp@amazon.com
    name = "employee_email",
    match = function(t) return t:lower():match("^([%w%._%-]+)@amazon%.com$") end,
    action = openUrl(URL.PHONETOOL),
  },
  {
    -- P / V 开头 + 7~10 位数字。例：P436629647、V2197861578
    name = "ticket_id",
    match = function(t)
      local digits = t:match("^[PV](%d+)$")
      if digits and #digits >= 7 and #digits <= 10 then return t end
    end,
    action = openUrl(URL.TICKET),
  },
  {
    -- UUID。例：61675881-580d-4603-948b-f51e08f9a8e7
    name = "harbinger_notice_id",
    match = function(t)
      local h = "%x%x%x%x"
      return t:match("^" .. h .. h .. "%-" .. h .. "%-" .. h .. "%-" .. h .. "%-" .. h .. h .. h .. "$")
    end,
    action = openUrl(URL.HARBINGER),
  },
  {
    -- UNIX 10 位（秒）/ 13 位（毫秒）时间戳。例：1790204980
    name = "timestamp",
    match = function(t) if isDigits(t, 10, 13) then return t end end,
    action = showMessage("UTC 时间", function(t) return formatUtc(t) end),
  },
  {
    -- 3~10 位纯小写字母：可能是 alias，也可能只是个英文单词，让用户选。例：dvvp
    name = "employee_alias",
    match = function(t) if #t >= 3 and #t <= 10 and t:match("^%l+$") then return t end end,
    action = choose({
      {label = "Phonetool",   action = openUrl(URL.PHONETOOL)},
      {label = "Google 搜索", action = openUrl(URL.GOOGLE, true)},
    }),
  },
  {
    -- 兜底：Google 搜索
    name = "fallback",
    match = function(t) return t end,
    action = openUrl(URL.GOOGLE, true),
  },
}
