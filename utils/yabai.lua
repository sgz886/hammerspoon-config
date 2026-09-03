-- ============================================================
-- utils/yabai.lua
-- yabai CLI 的薄封装：只负责「拼命令 + 跑命令 + 解析 JSON + 报错」，不含任何业务逻辑。
-- ⭐ yabai v7 起不再需要 scripting addition，SIP 开着也能跨 space 移动窗口，
--    比 Hammerspoon 模拟鼠标 + 键盘那套快得多。
--
-- 测试:
--   hs -c 'hs.inspect(require("utils.yabai").query("--spaces", "--display", 1))'
--   hs -c 'require("utils.yabai").command("window", "--space", 5)'
-- ============================================================
local M = {}

-- yabai 可执行文件路径。装在别处的话，require 之后覆盖这个字段即可。
M.binary = "/opt/homebrew/bin/yabai"

-- ──────────── 内部工具 ────────────

-- 把单个参数包成 shell 安全的单引号形式
local function shellQuote(arg)
    return "'" .. (tostring(arg):gsub("'", [['\'']])) .. "'"
end

-- 拼出完整命令：/opt/homebrew/bin/yabai -m <args...>
local function buildCommand(args)
    local parts = { shellQuote(M.binary), "-m" }
    for _, arg in ipairs(args) do
        table.insert(parts, shellQuote(arg))
    end
    return table.concat(parts, " ")
end

-- 跑一条 yabai 命令（同步，单次 ~10ms）
-- @param args table  参数数组
-- @return string?  stdout（成功时）
-- @return string?  错误信息（失败时）
local function run(args)
    if not M.isAvailable() then
        return nil, string.format("找不到 yabai 可执行文件: %s", M.binary)
    end

    -- 第二个参数留空 = 不走登录 shell，省掉几十 ms
    local output, ok = hs.execute(buildCommand(args) .. " 2>&1")
    if not ok then
        return nil, string.format("yabai %s 失败: %s",
            table.concat(args, " "), (output or ""):gsub("%s+$", ""))
    end
    return output
end

-- ──────────── 公开 API ────────────

--- yabai 可执行文件是否存在
-- @return boolean
function M.isAvailable()
    return hs.fs.attributes(M.binary, "mode") == "file"
end

--- 执行 yabai 查询并解析 JSON
-- @param ... 查询参数，如 ("--spaces", "--display", 1)
-- @return table?   解析后的 Lua table
-- @return string?  错误信息
function M.query(...)
    local args = { "query", ... }
    local output, err = run(args)
    if not output then return nil, err end

    local decoded = hs.json.decode(output)
    if not decoded then
        return nil, string.format("yabai %s 的输出不是合法 JSON: %s",
            table.concat(args, " "), output)
    end
    return decoded
end

--- 执行会改状态的 yabai 命令
-- @param ... 命令参数，如 ("window", 1822, "--space", 5)
-- @return boolean  是否成功
-- @return string?  错误信息
function M.command(...)
    local output, err = run({ ... })
    if not output then return false, err end
    return true
end

return M
