#!/usr/bin/env expect -f
# ─────────────────────────────────────────────────────────
# mwinit-auto.sh
# 自动输入 YubiKey PIN；触摸 key 仍需手动
#
# ⭐ 只有走完最后一步 interact 且 mwinit 退出码为 0 时,
#    才用 `hs -c` 回调 Hammerspoon 的 mwinit.markSuccess(),
#    由它写入 hs.settings 的"今天已运行"标记。
#    取消/失败一律不标记 —— 今天下次解锁还会重试。
# ─────────────────────────────────────────────────────────

set timeout 60

# ─── hs CLI：Hammerspoon 的命令行入口 ──────────────────
# 依赖 init.lua 里的 require("hs.ipc") 打开消息端口
set HS_BIN ""
foreach candidate {
    /opt/homebrew/bin/hs
    /usr/local/bin/hs
    /Applications/Hammerspoon.app/Contents/Frameworks/hs/hs
} {
    if {[file executable $candidate]} {
        set HS_BIN $candidate
        break
    }
}

# ─── 等用户按一个键（raw 模式读 1 字符）───────────────
proc waitAnyKey {prompt} {
    puts -nonewline $prompt
    flush stdout
    # -echo:不回显输入; < /dev/tty:强制作用于真正的终端(防止 stdin 被重定向时失效)
    exec stty raw -echo < /dev/tty
    set key [read stdin 1]
    exec stty -raw echo < /dev/tty
    puts ""   ;# 换行,让后续输出好看
    return $key
}

# ─── 0. 等待用户确认 ───────────────────────────────────
set key [waitAnyKey "按任意键开始 mwinit,按 n 取消: "]
if { $key eq "n" || $key eq "N"} {
    # 不标记 —— 今天下次解锁还会再问一次
    puts "已取消"
    exit 0
}

# 1. 从 Keychain 取出 PIN
if {[catch {
    set pin [exec security find-generic-password -a $env(USER) -s mwinit -w]
} err]} {
    puts stderr "❌ 无法从 Keychain 读取 PIN: $err"
    exit 1
}

# 2. 启动 mwinit
spawn mwinit --fido2

# 3. 等待 PIN 提示并发送
expect {
    -re "PIN.*key" { send -- "$pin\r" }
    timeout       { puts stderr "❌ 等待 PIN 提示超时"; exit 1 }
    eof           { puts stderr "❌ mwinit 意外退出"; exit 1 }
}
# 4. 把后续交互交还给用户（等待触摸 YubiKey）
#    interact 会把当前 tty 连接到 mwinit，直到它退出
interact

# ─── 5. interact 返回后：判断 mwinit 到底成没成 ────────
# interact 在 mwinit EOF/退出后会返回，脚本继续往下跑。
# 注意：interact 不会更新 $expect_out，所以只能靠退出码判断。
# wait 返回 {pid spawn_id os_error_flag value}
#   os_error_flag == 0  → value 是退出码
#   os_error_flag == -1 → value 是 errno，拿不到退出码
set exitStatus -1
if {[catch {wait} waitResult] == 0 && [lindex $waitResult 2] == 0} {
    set exitStatus [lindex $waitResult 3]
} else {
    puts stderr "⚠️  无法取到 mwinit 退出码: $waitResult"
}

# 兜底：退出码拿不到时，用 Midway cookie 的新鲜度判断
# （成功的 mwinit 一定会刷新 ~/.midway/cookie）
if {$exitStatus == -1} {
    set cookie $env(HOME)/.midway/cookie
    if {[file exists $cookie] && [expr {[clock seconds] - [file mtime $cookie]}] < 120} {
        puts "ℹ️  依据 ~/.midway/cookie 刚被刷新，判定为成功"
        set exitStatus 0
    }
}

if {$exitStatus == 0} {
    puts "✅ mwinit 登录成功，标记今日已完成"
    # 回调 Hammerspoon，由 Lua 侧写 hs.settings
    if {$HS_BIN eq ""} {
        puts stderr "❌ 找不到 hs CLI，无法标记。请在 Hammerspoon 控制台手动执行："
        puts stderr "   require(\"modules.mwinit\").markSuccess()"
    } elseif {[catch {exec $HS_BIN -c {require("modules.mwinit").markSuccess()}} out]} {
        puts stderr "❌ 通知 Hammerspoon 失败: $out"
    }
} else {
    # 不标记 —— 今天下次解锁会重试
    puts "❌ mwinit 未成功 (exit=$exitStatus)，今天下次解锁会重试"
    # 用 exec 启动时 expect 一退出窗口就没了，先停住让用户看清原因
    waitAnyKey "按任意键关闭窗口: "
}

# 主动退出，关闭 iTerm 窗口
# 注意：需要在 Lua 里用 write text "exec %s"
exit $exitStatus
