-- tests/clipboard_action_rules_test.lua
-- clipboard action 规则表的匹配测试：只测「哪条规则命中」，不执行动作（不开 Chrome、不弹窗）
--
-- 运行：tests/run.sh   （要 Hammerspoon 在跑，借它的 Lua 环境，但不走 ⌘C / 端到端）
-- ⭐ 加用例：往下面 CASES 里加一行 {输入, 期望命中的规则名[, 期望 captures]}

-- 每次都重新加载规则，改完规则不用重载 Hammerspoon 就能测
package.loaded["modules.clipboard_action_rules"] = nil
package.loaded["modules.clipboard_action"] = nil
local match = require("modules.clipboard_action").match

local CASES = {
  -- case_id：15 位数字，前 10 位是合理的时间戳
  {"179020498000189", "case_id"},
  {"178952091500411", "case_id"},
  {"999999999900000", "fallback"},          -- 前 10 位时间戳不合理

  -- employee_email：captures 是 @ 前面的 alias
  {"dvvp@amazon.com", "employee_email", "dvvp"},
  {"Dvvp@amazon.com", "fallback"},          -- alias 只认小写
  {"dvvp@gmail.com", "fallback"},

  -- ticket_id：大写字母 + 7~10 位数字
  {"P436629647", "ticket_id"},
  {"V2197861578", "ticket_id"},
  {"D528065303", "ticket_id"},
  {"E528065303", "ticket_id"},
  {"P1234567", "ticket_id"},                -- 7 位
  {"p1234567", "fallback"},
  {"P123456", "fallback"},                  -- 6 位，太短
  {"P12345678901", "fallback"},             -- 11 位，太长

  -- harbinger_notice_id：UUID
  {"61675881-580d-4603-948b-f51e08f9a8e7", "harbinger_notice_id"},
  {"61675881-580D-4603-948B-F51E08F9A8E7", "harbinger_notice_id"},

  -- file_url
  {"file:///Users/suguoz/cases/178952091500411/se/", "file_url"},

  -- web_url：http(s)、裸域名、IPv4
  {"https://www.sbs.com.au/", "web_url"},
  {"HTTPS://EXAMPLE.COM", "web_url"},
  {"http://localhost:8080", "web_url"},
  {"http://192.168.1.1:8080", "web_url"},
  {"www.sbs.com.au", "web_url"},
  {"sbs.com.au", "web_url"},
  {"sbs.com.au/news?x=1", "web_url"},
  {"www.google.com", "web_url"},
  {"aws.dev/x", "web_url"},
  {"amazon.work", "web_url"},
  {"foo.io", "web_url"},
  {"192.168.1.1", "web_url"},
  {"192.168.1.1:80", "web_url"},
  {"192.168.1.100:6880/", "web_url"},
  {"192.168.1.100:6880/#", "web_url"},
  -- 不是网址
  {"cloudwatch.describealarms", "fallback"}, -- 3 位以上的 TLD 只认常见通用顶级域名
  {"init.lua", "fallback"},                  -- 文件名
  {"notes.txt", "fallback"},
  {"256.1.1.1", "fallback"},                 -- IPv4 每段 0~255
  {"a..b.com", "fallback"},

  -- timestamp：10 位秒 / 13 位毫秒 / 10 位 + 1~3 位小数
  {"1790204980", "timestamp"},
  {"1790204980123", "timestamp"},
  {"1790204980.1", "timestamp"},
  {"1790204980.123", "timestamp"},
  {"1790204980.1234", "fallback"},          -- 小数超过 3 位

  -- employee_alias：3~8 位纯小写字母
  {"dvvp", "employee_alias"},
  {"abc", "employee_alias"},
  {"abcdefgh", "employee_alias"},
  {"ab", "fallback"},
  {"abcdefghi", "fallback"},            -- 9 位
  {"Dvv", "fallback"},

  -- fallback：Google 搜索
  {"hello world", "fallback"},
}

local passed, failures = 0, {}
for _, c in ipairs(CASES) do
  local input, wantRule, wantCaptures = c[1], c[2], c[3]
  local rule, captures = match(input)
  local gotRule = rule and rule.name or "nil"
  if gotRule == wantRule and (wantCaptures == nil or captures == wantCaptures) then
    passed = passed + 1
  else
    failures[#failures + 1] = string.format("  ❌ %q → %s (captures %s)，期望 %s%s", input, gotRule,
      tostring(captures), wantRule, wantCaptures and (" (captures " .. wantCaptures .. ")") or "")
  end
end

local lines = {string.format("clipboard_action_rules: %d/%d 通过", passed, #CASES)}
for _, f in ipairs(failures) do lines[#lines + 1] = f end
lines[#lines + 1] = #failures == 0 and "✅ 全部通过" or string.format("❌ %d 个失败", #failures)
return table.concat(lines, "\n")
