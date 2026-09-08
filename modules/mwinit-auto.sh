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

# ─── 补 PATH ───────────────────────────────────────────
# ⚠️ 本脚本由 iTerm 的 `command` 参数直接启动，中间不经过任何 shell，
#    所以没有 path_helper —— PATH 只有 launchd 默认的
#    /usr/bin:/bin:/usr/sbin:/sbin（`launchctl getenv PATH` 是空的）。
#    security(/usr/bin) 和 stty(/bin) 够用，但 mwinit 在 /usr/local/bin，必须自己加。
set env(PATH) "/usr/local/bin:/opt/homebrew/bin:$env(PATH)"

# ─── 用户名：不经过 shell 时 USER 不保证有 ──────────────
set userName [expr {[info exists env(USER)] ? $env(USER) : [exec id -un]}]

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

# ─── 弹 Hammerspoon 提示 ───────────────────────────────
# ⭐ 提示必须从这里发，不能在 Lua 侧的 M.mwinit() 里发：
#    hs.alert 底层是 hs.canvas，默认 behavior 是 0（不含 canJoinAllSpaces /
#    moveToActiveSpace），所以 alert 会被钉死在「创建那一瞬间活动的那个 Space」上，
#    之后 Space 怎么切它都不动。而 hs.osascript.applescript 返回时 macOS 的
#    Space 切换还没走完（实测晚约 0.5s）—— iTerm 在别的 Space 时，
#    Lua 侧发的 alert 就留在旧 Space / 旧屏幕上，你根本看不见。
#    从脚本这里发的时候 iTerm 早就在前台了，Space 和屏幕都是对的。
#    `&` 后台跑：别让这次 hs 往返（~100ms+）卡在 interact 前面。
#    `>& /dev/null`：hs.alert.show 会回一个 UUID，不吞掉的话会吐到 mwinit 窗口里。
proc hsAlert {msg} {
    global HS_BIN
    if {$HS_BIN eq ""} { return }
    catch {exec $HS_BIN -c "hs.alert.show(\"$msg\", {textSize = 36, radius = 12}, 3)" >& /dev/null &}
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

# ─── mwinit 绝对路径 ───────────────────────────────────
# 显式探测，这样找不到时能给出人能看懂的提示，而不是 expect 的 couldn't execute
set MWINIT_BIN ""
foreach candidate {
    /usr/local/bin/mwinit
    /usr/local/amazon/bin/mwinit
    /opt/homebrew/bin/mwinit
} {
    if {[file executable $candidate]} {
        set MWINIT_BIN $candidate
        break
    }
}
if {$MWINIT_BIN eq ""} {
    puts stderr "❌ 找不到 mwinit 可执行文件"
    waitAnyKey "按任意键关闭窗口: "
    exit 1
}

# ─── 0. 等待用户确认 ───────────────────────────────────
hsAlert "\\u{1F446} 开始 mwinit login"
set key [waitAnyKey "按任意键开始 mwinit,按 n 取消: "]
if { $key eq "n" || $key eq "N"} {
    # 不标记 —— 今天下次解锁还会再问一次
    puts "已取消"
    exit 0
}

# 1. 从 Keychain 取出 PIN
if {[catch {
    set pin [exec security find-generic-password -a $userName -s mwinit -w]
} err]} {
    puts stderr "❌ 无法从 Keychain 读取 PIN: $err"
    exit 1
}

# 2. 启动 mwinit
spawn $MWINIT_BIN --fido2

# 3. 等待 PIN 提示并发送
expect {
    -re "PIN.*key" { send -- "$pin\r" }
    timeout       { puts stderr "❌ 等待 PIN 提示超时"; exit 1 }
    eof           { puts stderr "❌ mwinit 意外退出"; exit 1 }
}
# 4. PIN 已送出，接下来就该摸 key 了 —— 这时候才提示，时机才对
#    ⚠️ emoji 必须写成 Lua 的 \u{...} 转义，不能直接把字符写在这里：
#       macOS 自带的是 Tcl 8.5（内部 UCS-2），装不下 BMP 以外的字符 ——
#       👆 是 U+1F446，Tcl 会把它的 4 个 UTF-8 字节当成 4 个 Latin-1 字符，
#       出去时再各自编码一遍，Hammerspoon 收到的就是 `ð` + 3 个不可见控制字符。
#       写成转义序列后 Tcl 只搬运 ASCII，由 Lua 5.4 自己解码，字节才是对的。
#       （中文在 BMP 内，直接写没问题）
hsAlert "\\u{1F446} 请触摸 USB 安全密钥"

# 5. 把后续交互交还给用户（等待触摸 YubiKey）
#    interact 会把当前 tty 连接到 mwinit，直到它退出
interact

# ─── 6. interact 返回后：判断 mwinit 到底成没成 ────────
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
# 本脚本就是 session 的进程本身（Lua 侧用的是
# `create window with default profile command "..."`），
# 所以脚本一退出 session 就结束，窗口按 profile 的「When session ends」设置关闭。
exit $exitStatus
