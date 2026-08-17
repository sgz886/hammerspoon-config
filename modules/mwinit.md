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

### 脚本回调用的命令（脚本内部执行的就是这一句）
```bash
hs -c 'require("modules.mwinit").markSuccess()'
```

### in terminal
```bash
osascript <<'EOF'
tell application "iTerm"
    create window with default profile
    tell current session of current window
        write text "echo hello from applescript"
    end tell
end tell
EOF
```

```bash
osascript <<'EOF'
tell application "iTerm"
    create window with default profile
    tell current session of current window
        write text "exec ~/.hammerspoon/modules/mwinit-auto.sh"
    end tell
end tell
EOF
```
