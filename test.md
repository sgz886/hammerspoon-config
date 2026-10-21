### 查看某个程序的 ID
在 Console 里执行这段，**给自己 3 秒切到目标应用**：
```lua
hs.timer.doAfter(3, function()
  local app = hs.application.frontmostApplication()
  hs.alert.show("名字: " .. app:name() .. "\nBundle: " .. app:bundleID(), 5)
  print("Name:", app:name())
  print("BundleID:", app:bundleID())
end)
```

### sendToChatBox

```bash
hs -c "wgestures.sendToChatbox('translator')"
hs -c "wgestures.sendToChatbox('text_polish')"
```

### window control
```bash
hs -c 'require("utils.window_control").focus_app("Obsidian")'
hs -c 'require("utils.window_control").move_focused_window_with_direction("right")'
hs -c 'require("utils.window_control").swap_space_and_app("right")'
hs -c 'require("utils.window_control").switch_current_space("right", "yabai")'
```

### clipboard action（选中文字 → 按模式分派）
```bash
hs -q -c 'wgestures.clipboardAction()'   # WGestures 里绑这条；终端里直接跑的话前台是终端本身
```
控制台里测规则 / 动作（不走 ⌘C）：
```lua
for _, s in ipairs{"179020498000189","dvvp","dvvp@amazon.com","P436629647","V2197861578",
  "61675881-580d-4603-948b-f51e08f9a8e7","1790204980","1790204980123","hello world"} do
  print(s, require("modules.clipboard_action").match(s).name) end

require("modules.clipboard_action").dispatch("dvvp")            -- 弹选择框
require("modules.clipboard_action").dispatch("1790204980123")   -- 弹 UTC 时间
hs.timer.doAfter(3, require("modules.clipboard_action").run)    -- 3 秒内切到别的 App 选中文字
```
terminal里测试 new window
```bash
hs -c 'require("utils.browser").openInNewChromeWindow("https://www.google.com")'
```