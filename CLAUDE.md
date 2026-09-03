# CLAUDE.md

个人 macOS [Hammerspoon](https://www.hammerspoon.org/) 配置（Lua）。入口是 `init.lua`，没有构建步骤、没有测试框架、没有包管理器 —— 改完文件 reload 一下即生效。

## 目录结构

```
init.lua        入口：require 各模块 + 暴露给外部调用的全局变量
modules/        功能模块（一个功能一个文件）+ 快捷键注册
utils/          底层通用工具
Spoons/         空目录，本配置不使用任何 Spoon（无 hs.loadSpoon）
test.lua        ⚠️ 未跟踪的实验草稿，不是测试
test-step2.lua  ⚠️ 同上
1.log 2.log     未跟踪的旧控制台日志（doubao_speak 调试遗留）
```

### modules/

| 文件 | 作用 |
|---|---|
| `assign_shortcut_to_function.lua` | **唯一的快捷键注册处**。文件作用域直接 `hs.hotkey.bind` |
| `utils.lua` | 共享工具中枢：切换/聚焦 App、窗口布局、`sequence`、发送到 ChatBox |
| `obsidian_chatbox_management.lua` | `⌃⇧⌘Z`：按当前前台 App 三态切换，把 Obsidian + Chatbox 平铺到当前 Space |
| `kiro-cli_copy_and_send_to_chatbox_translate.lua` | `⌘⌥T`：在 Kiro CLI 里 copy，再丢给 ChatBox 的 translator |
| `mwinit.lua` + `mwinit-auto.sh` + `mwinit.md` | 每天自动跑一次 Amazon SSO 登录（见下文） |
| `unlock_watcher.lua` | `hs.caffeinate.watcher` 事件分发；mwinit 的唯一调用方 |
| `sleep_mute.lua` | 息屏静音、解锁 3 秒后恢复原音量（带 5 次读回重试） |
| `test.lua` | 音量/睡眠的手动测试台，作为全局 `test` 加载，在控制台调 `test.help()` |
| `doubao_speak.lua` | 长按右 Cmd 唤起豆包语音输入。**已在 init.lua 里注释掉**（commit `02e1892`） |
| `doubao_speak_github.lua` | 上面那个的早期实现，纯参考，从未被 require |

### utils/

| 文件 | 公开 API |
|---|---|
| `move_app_across_spaces.lua` | `M.focus_app_to_current_space(appName, opts)`、`M.move_front_app_one_space(opts)`。按住标题栏 + 连发 `Ctrl+fn+方向键` 把窗口拖过 Space |
| `get_cursor_selected_text.lua` | `M.getSelectedText()`、`M.alertSelectedText()`、`M.test()`。走 Accessibility API（`hs.axuielement` → `AXFocusedUIElement` → `AXSelectedText`） |
| `mylog.lua` | `M.new(id, level)` → `.e/.w/.i/.d/.v` + printf 变体 `.ef/.wf/.f/.df/.vf`。自己写的 `hs.logger` 替代品，带毫秒时间戳 |

## 代码约定

**模块形状**：一律 `local M = {} … function M.x() … return M`，私有函数用 `local function`。没有 OO、没有 metatable。

**require 路径**：从 `.hammerspoon` 根算的点号路径 —— `require("modules.utils")`、`require("utils.move_app_across_spaces")`。`hs.spaces` 例外，它在函数内部延迟 require。

**两种加载方式**（`init.lua` 里两种都有）：
- require 即自启：`sleep_mute`（`:87-88` 文件作用域启动 watcher）、`assign_shortcut_to_function`（文件作用域 bind）
- 显式启动：`require("modules.unlock_watcher").start()`

**`init.lua` 里的全局变量是故意的**（`test` / `cursorSelect` / `workflow` / `move_app`），供外部手势 App 通过 `hs.ipc` 调用 —— 这也是 `init.lua:2` 要 `require("hs.ipc")` 的原因。不要把它们改成 local。

**⚠️ GC 陷阱 —— 本仓库最重要的一条约定**：`hs.caffeinate.watcher`、`hs.timer.doAfter`、`hs.eventtap` 的返回值必须存到 module 级变量（或全局），否则会被 GC 掉，watcher/timer 静默失效。见 `unlock_watcher.lua:36-40`（`-- 不这么做的话会被 GC，watcher 就失效了！`）和 commit `aaeccf0`「修复了doAfter被垃圾回收」。写新代码时照做。

**`utils.sequence(steps)`**（`modules/utils.lua:112`）：本仓库编排「切窗口 + 敲键盘」时序的标准做法。

```lua
utils.sequence({
  {0,   function() hs.eventtap.keyStroke({"cmd"}, "c") end},
  {0.1, function() focus_app_to_current_space.focus_app_to_current_space("ChatBox") end},
  {0.3, function() hs.eventtap.keyStroke({"cmd"}, "v") end},
})
```
注意 **delay 是相对上一步的增量**，不是绝对时间。

**快捷键**：只加在 `modules/assign_shortcut_to_function.lua`。多个同类绑定优先用表驱动（该文件注释称之为「推荐做法」）：
```lua
local toggleAppBindings = { {mods = {"option"}, key = "space", app = "Chatbox"} }
```
现有绑定：`⌥Space` 切换 Chatbox、`⌃⇧⌘Z` Obsidian+Chatbox 布局、`⌘⌥T` Kiro CLI → 翻译。

**日志**：三种风格并存，改哪个文件就跟哪个文件的风格。主流是带模块前缀的 print：
```lua
print(string.format("[unlock_watcher] event: %s (%d)", eventName, event))
```
另有 `hs.logger.new(name, "info")`（`move_app_across_spaces.lua`，调试时把 `"info"` 改成 `"debug"`）和自研 `utils/mylog.lua`（`doubao_speak.lua`）。给用户看的反馈用带 emoji 的 `hs.alert.show`（✅ ❌ ⚠️ 🔊 👆）。

**注释和 commit**：注释用中文、标识符用英文。分隔块用 `-- ────` 或 `-- ====`，文档块用 `@param name type 说明` / `@return`。注释里常带 emoji（⭐ ✅ ❌ ⚠️ 🔑 ⏱ 🧪）。commit message 中文为主，前缀混用 `feat:` / `fix:` / `优化:` / `layout:`。

## 调试与 reload

**没有 `hs.pathwatcher`，也没有自动 reload** —— 改完必须手动生效：
```bash
hs -c 'hs.reload()'     # 或者菜单栏 Hammerspoon → Reload Config
```
`hs` CLI 在 `/opt/homebrew/bin/hs`（软链到 Hammerspoon.app 内），靠 `init.lua:2` 的 `require("hs.ipc")` 打开消息端口。reload 期间 `hs -c` 报 message port 失效是正常的。

在 Hammerspoon Console（或 `hs -c`）里直接调模块函数来测：
```lua
require("modules.unlock_watcher").handleEvent(hs.caffeinate.watcher.screensDidUnlock)  -- 模拟解锁
test.help()                                                                            -- 音量测试台
```

**持久状态**：全仓库只有一个 `hs.settings` key —— `mwinit.lastAutoRunDate`（`modules/mwinit.lua`），落盘在 `~/Library/Preferences/org.hammerspoon.Hammerspoon.plist`。其他模块的状态都是 module 级变量，reload 即清零（例如 `sleep_mute.lua:6` 的 `volumeBeforeSleep`）。

### 调试命令

**in terminal**

```bash
hs -c 'require("modules.utils").focusApp("Chatbox")'
```

## mwinit 每日自动登录

调用链：
```
init.lua → unlock_watcher.start()
  ├─ screensDidUnlock 事件           (unlock_watcher.lua:28-33)
  └─ start() 里的开机补偿 timer       (unlock_watcher.lua:57-59，处理 Hammerspoon 比解锁事件晚启动)
       └─ 都 doAfter(60s) → mwinit.runOncePerDay()
            └─ AppleScript 让 iTerm 跑 `exec ~/.hammerspoon/modules/mwinit-auto.sh`
                 └─ expect 自动填 PIN → interact 等用户摸 YubiKey
                      └─ ⭐ 只有 mwinit 退出码 0 时，脚本才 `hs -c` 回调 markSuccess()
```

**关键设计：「今天已完成」标记只在真正登录成功后才写。** `markSuccess()` 是唯一写 `hs.settings` 的地方，由 `mwinit-auto.sh` 在 `interact` 之后用 `hs -c` 回调。取消（按 `n`）、PIN 读取失败、没摸 key 等一律不写标记，今天下次解锁会重试。改这块时注意：

- AppleScript 用的是 `write text "exec ..."`，expect 退出后**没有 shell 残留**，所以任何成功信号都必须在 expect 脚本内部发出。
- `hs.osascript.applescript` 是 fire-and-forget，Lua 侧拿不到脚本结果 —— 只能靠脚本反向回调。
- expect 的 `interact` 在被 spawn 的进程退出后会返回，用 `wait` 取退出码；`interact` **不会**更新 `$expect_out`，所以别想靠输出文本判断。
- `pendingSince` / `PENDING_TIMEOUT`（`mwinit.lua`）只是防止 60s 窗口内重复解锁或补偿 timer 叠加、开出多个抢同一个 tty 的 iTerm 窗口，**不是**重试冷却。

外部依赖：Keychain 条目（`security find-generic-password -a $USER -s mwinit -w`）、`/usr/local/bin/mwinit`、`/usr/bin/expect`、iTerm2、`hs` CLI。调试命令见 `modules/mwinit.md`。

## 别动这些（都是踩过坑的）
- **`sleep_mute` 必须监听 `screensDidSleep` 而不是 `systemWillSleep`**：系统 idle 之后永远不会进 system sleep。见 `sleep_mute.lua:67` 和 commit `7fef8f2`。
- 定时器/watcher 的引用要存起来，同上面的 GC 陷阱。

## 已知遗留问题（历史遗留，不用顺手修）

- `modules/test.lua:55` require 了不存在的 `modules.sleep_volume`（已改名 `sleep_mute`），所以 `test.simulateSleep()` 是坏的 —— 用 `test.simulateSleepLogic()`。
- `modules/utils.lua:136` 给未声明的全局 `appName` 赋值，而且是死代码（App 名在 `:139` 写死了）。
- 几处文件头路径注释过期：`assign_shortcut_to_function.lua:1` 写着 `modules/focus.lua`，`utils/get_cursor_selected_text.lua:1` 写着 `modules/test_copy.lua`。
- 根目录 `test.lua` 和 `modules/test.lua` 同名但完全无关，别搞混。
