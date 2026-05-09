## the debug

### in console
```bash
mw = require("modules.mwinit")
mw.mwinit()
mw.runOncePerDay()
mw.resetDailyFlag()
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
        write text "exec /Users/suguoz/bin/mwinit-auto.sh"
    end tell
end tell
EOF
```
