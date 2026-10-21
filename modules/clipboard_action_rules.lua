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
  RAW       = "%s",   -- captures 本身就是完整 URL
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

-- 用系统默认方式打开（等价 terminal 里 `open <URL>`：目录进 Finder，文件用默认 app）
-- ⭐ hs.urlevent.openURL 走 NSWorkspace，非阻塞，也不用像 hs.task 那样防 GC
local function openDefault()
  return function(text, captures)
    local v = valueOf(text, captures)
    if not hs.urlevent.openURL(v) then
      print(string.format("[clipboard_action] ❌ 打开失败: %s", v))
      hs.alert.show("❌ 打开失败")
    end
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

-- 取时间戳的小数部分：13 位取后 3 位，"10 位.1~3 位" 取小数点后，纯 10 位返回 nil
local function fractionOf(ts)
  local frac = ts:match("^%d%d%d%d%d%d%d%d%d%d%.?(%d*)$")
  if frac and frac ~= "" then return frac end
end

-- 10 位（秒）/ 13 位（毫秒）/ 10 位.1~3 位小数 → "yyyy/mm/dd hh:mm:ss[.xxx] UTC"
local function formatUtc(digits)
  local sec = tonumber(digits:sub(1, 10))
  local s = os.date("!%Y/%m/%d %H:%M:%S", sec)
  local frac = fractionOf(digits)
  if frac then s = s .. "." .. frac end
  return s .. " UTC"
end

-- 同上，但换成 tz 时区的本地时间 → "yyyy/mm/dd hh:mm:ss[.xxx] UTC+10 (AEST)"
-- ⭐ 交给 macOS 的 /bin/date + TZ 环境变量去算，夏令时由系统时区库判断，不自己写规则
-- @param tz string  IANA 时区名，如 "Australia/Melbourne"
local function formatInZone(digits, tz)
  local sec = tonumber(digits:sub(1, 10))
  local out = hs.execute(string.format("TZ=%q /bin/date -r %d '+%%Y/%%m/%%d %%H:%%M:%%S|%%z|%%Z'", tz, sec))
  local time, offset, abbr = (out or ""):match("^(.-)|([+-]%d%d%d%d)|(%S+)")
  if not time then return "（" .. tz .. " 时间转换失败）" end

  local frac = fractionOf(digits)
  if frac then time = time .. "." .. frac end
  -- "+1000" → "UTC+10"，"+0530" → "UTC+5:30"
  local sign, hh, mm = offset:match("([+-])(%d%d)(%d%d)")
  local utcOffset = "UTC" .. sign .. tonumber(hh) .. (mm ~= "00" and (":" .. mm) or "")
  return string.format("%s %s (%s)", time, utcOffset, abbr)
end

-- 长得像文件名的「TLD(Top-Level Domain)」，不当网址（init.lua、notes.txt 之类继续走 Google）
local FILE_EXTS = {}
for ext in ("lua md txt json log sh zsh py js ts yaml yml toml csv tsv html htm xml pdf png jpg jpeg gif zip gz tar conf cfg ini"):gmatch("%S+") do
  FILE_EXTS[ext] = true
end

-- 3 位以上的 TLD 只认这些常见通用顶级域名（2 位的当国家域名 .au .cn 放行）
-- ⭐ 不能只看长度：cloudwatch.describealarms 这种 API 名也是「字母.字母」
local GENERIC_TLDS = {}
for tld in ("com net org edu gov mil int info biz name pro mobi app dev xyz top site online tech cloud store shop blog news live work page"):gmatch("%S+") do
  GENERIC_TLDS[tld] = true
end

-- 像网址就原样返回（不补协议，交给 Chrome 处理），否则 nil
-- 例：https://www.sbs.com.au/、www.sbs.com.au、sbs.com.au/news?x=1、192.168.1.100:6880/#
local function toWebUrl(t)
  if t:find("%s") then return nil end
  if t:lower():match("^https?://.") then return t end

  local host, rest = t:match("^([%w%.%-]+)(.*)$")
  if not host or not (rest == "" or rest:match("^[/:?#]")) then return nil end
  if host:find("%.%.") or host:match("^[%.%-]") or host:match("[%.%-]$") then return nil end

  -- IPv4 host（每段 0~255）
  local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if a then
    for _, n in ipairs({a, b, c, d}) do
      if #n > 3 or tonumber(n) > 255 then return nil end
    end
    return t
  end

  local tld = host:match("%.(%a%a+)$")
  if not tld then return nil end
  tld = tld:lower()
  if FILE_EXTS[tld] then return nil end
  if #tld > 2 and not GENERIC_TLDS[tld] then return nil end
  --return "https://" .. t
  return t
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
    match = function(t) return t:match("^(%l+)@amazon%.com$") end,
    action = openUrl(URL.PHONETOOL),
  },
  {
    -- 大写字母 开头 + 7~10 位数字。例：P436629647、V2197861578,
    name = "ticket_id",
    match = function(t)
      local digits = t:match("^%u(%d+)$")
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
    -- 本地文件 / 目录 URL，用默认方式打开。例：file:///Users/suguoz/cases/178952091500411/se/
    name = "file_url",
    match = function(t) if t:match("^file:///%S*$") then return t end end,
    action = openDefault(),
  },
  {
    -- 网址，http/https 开头、裸域名或 IPv4，原样交给 Chrome。例：https://www.sbs.com.au/、sbs.com.au、192.168.1.1
    name = "web_url",
    match = toWebUrl,
    action = openUrl(URL.RAW),
  },
  {
    -- UNIX 10 位（秒）/ 13 位（毫秒）/ 10 位加 1~3 位小数 时间戳。例：1790204980、1790204980.123
    name = "timestamp",
    match = function(t)
      if isDigits(t, 10, 13) or t:match("^%d%d%d%d%d%d%d%d%d%d%.%d%d?%d?$") then return t end
    end,
    action = showMessage("时间戳转换", function(t)
      return "UTC:    " .. formatUtc(t) .. "\n"
          .. "墨尔本: " .. formatInZone(t, "Australia/Melbourne")
    end),
  },
  {
    -- 3~8 位纯小写字母：可能是 alias，也可能只是个英文单词，让用户选。例：dvvp
    name = "employee_alias",
    match = function(t) if #t >= 3 and #t <= 8 and t:match("^%l+$") then return t end end,
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
