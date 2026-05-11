#!/usr/bin/env expect -f
# ─────────────────────────────────────────────────────────
# mwinit-auto.sh
# 自动输入 YubiKey PIN；触摸 key 仍需手动
# ─────────────────────────────────────────────────────────

set timeout 60

# ─── 0. 等待用户确认 ───────────────────────────────────
puts -nonewline "按任意键开始 mwinit,按 n 取消: "
flush stdout
# 把终端切到 raw 模式,读 1 个字符后再恢复
exec stty raw -echo < /dev/tty  ;# -echo:不回显输入; < /dev/tty:强制作用于真正的终端(防止 stdin 被重定向时失效)
set key [read stdin 1]
exec stty -raw echo < /dev/tty
puts ""   ;# 换行,让后续输出好看
if { $key eq "n" || $key eq "N"} {
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
# 用户按完 YubiKey，mwinit 结束后，主动退出 shell
# 注意：需要在 Lua 里用 write text "exec %s"
