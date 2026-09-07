## the debug

### 每日标记的写入时机

只有 `mwinit-auto.sh` 走完最后一步 `interact`、且 `mwinit` 退出码为 0 时，
脚本才会用 `hs -c` 回调 `mw.markSuccess()` 写入 `hs.settings["mwinit.lastAutoRunDate"]`。
按 `n` 取消、PIN 读取失败、没摸 YubiKey 等情况都不写标记，今天下次解锁会重试。

### in console
```bash
mw = require("modules.mwinit")
mw.mwinit()           -- 直接跑一次（不看标记）
mw.runOncePerDay()    -- 今天没成功过才跑
mw.status()           -- 看 today / lastRun / pendingSince
mw.markSuccess()      -- 手动标记今天已完成（脚本正常会自己调）
mw.resetDailyFlag()   -- 清标记，让下次解锁重新触发
```

### in terminal

#### 脚本回调用的命令（脚本内部执行的就是这一句）
```bash
hs -c 'require("modules.mwinit").markSuccess()'
hs -c 'require("modules.mwinit").mwinit()'
```
#### 手动复现 Lua 侧的启动方式

脚本直接作为 session 进程启动，不经过 login shell（所以没有 `Last login`、
没有重复回显，也不用等 zsh/oh-my-zsh/p10k 初始化的那 0.8~1.3s）。
`launch` 对已在运行的 iTerm 是 no-op，冷启动时又不会多冒一个空窗口；
`activate` 放在 create 之后，让 iTerm 真的拿到键盘焦点（否则窗口只是浮在最上层，
按键会进原来的前台 App）。

```bash
osascript <<'EOF'
tell application "iTerm"
    launch
    create window with default profile command "/Users/suguoz/.hammerspoon/modules/mwinit-auto.sh"
    activate
end tell
EOF
```

⚠️ `command` 必须是绝对路径且不含空格：不经过 shell，`~` 不会被展开，
iTerm 还会对它做 argv 拆分。

#### 验证 PATH 硬化（模拟 GUI 进程的精简 PATH）

绕过 shell 后没有 `path_helper`，PATH 只有 launchd 默认那几个目录，
而 `mwinit` 在 `/usr/local/bin` —— 脚本靠自己 `set env(PATH)` 补上。
在普通终端里这样跑就能复现那个环境：

```bash
env -i HOME=$HOME USER=$USER TERM=xterm-256color \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    /usr/bin/expect -f ~/.hammerspoon/modules/mwinit-auto.sh
```

应该能正常走到 `spawn /usr/local/bin/mwinit --fido2` → PIN → 摸 key。
若报 `couldn't execute mwinit` 就是 PATH 那段被改坏了。
