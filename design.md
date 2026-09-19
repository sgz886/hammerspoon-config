# CLAUDE.md

个人 macOS [Hammerspoon](https://www.hammerspoon.org/) 配置（Lua）。入口是 `init.lua`，没有构建步骤、没有测试框架、没有包管理器 —— 改完文件 reload 一下即生效。

## 目录结构

```
init.lua        入口：require 各模块 + 暴露给外部调用的全局变量（wgestures 等）
modules/        功能模块（一个功能一个文件）+ 快捷键注册
utils/          底层通用工具
test.md         手动调试用的 hs -c 命令备忘（改公开函数名时记得同步）
Spoons/         空目录，本配置不使用任何 Spoon（无 hs.loadSpoon）
```

### modules/

| 文件 | 作用 |
|---|---|
| `assign_shortcut_to_function.lua` | **唯一的快捷键注册处**。文件作用域直接 `hs.hotkey.bind` |
| `obsidian_chatbox_management.lua` | `⌃⌘Z`：按当前前台 App 三态切换，把 Obsidian + Chatbox 平铺到当前 Space |
| `kiro-cli_copy_and_send_to_chatbox_translate.lua` | `⌘⌥T`：在 Kiro CLI 里 copy，再丢给 Chatbox 的 translator |
| `mwinit.lua` + `mwinit-auto.sh` + `mwinit_test.md` | 每天自动跑一次 Amazon SSO 登录（见下文） |
| `unlock_watcher.lua` | `hs.caffeinate.watcher` 事件分发；mwinit 的唯一调用方 |
| `sleep_mute.lua` | 息屏静音、解锁 3 秒后恢复原音量（带 5 次读回重试） |
| `test.lua` | 音量/睡眠的手动测试台，作为全局 `test` 加载，在控制台调 `test.help()` |
| `doubao_speak.lua` | 长按右 Cmd 唤起豆包语音输入。**已在 init.lua 里注释掉**（commit `02e1892`） |
| `doubao_speak_github.lua` | 上面那个的早期实现，纯参考，从未被 require |

### utils/

| 文件 | 公开 API |
|---|---|
| `yabai.lua` | `M.query(...)`（跑 `yabai -m query …` 并解析 JSON）、`M.command(...)`、`M.isAvailable()`、`M.binary`。**全仓库唯一和 yabai 说话的地方**，薄封装，不含业务逻辑 |
| `window_control.lua` | 窗口 / space 编排中枢（见下面「window_control 的公开 API」） |
| `common.lua` | `M.sequence(steps)`、`M.CHATBOX_APP` / `M.OBSIDIAN_APP`、`M.CHATBOX_SESSION` + `M.CHATBOX_SESSION_HOTKEY` |
| `get_cursor_selected_text.lua` | `M.getSelectedText()`、`M.alertSelectedText()`、`M.test()`。走 Accessibility API（`hs.axuielement` → `AXFocusedUIElement` → `AXSelectedText`） |
| `mylog.lua` | `M.new(id, level)` → `.e/.w/.i/.d/.v` + printf 变体 `.ef/.wf/.f/.df/.vf`。自己写的 `hs.logger` 替代品，带毫秒时间戳 |

### window_control 的公开 API

| 函数 | 作用 |
|---|---|
| `focus_app(appName, onReady?, timeout?)` | ⭐ 聚焦 App 的唯一入口（含连按保护 + 就绪等待 + 沉降期） |
| `toggleApp(appName)` / `toggleAppByBundleID(id)` | 已在最前就隐藏，否则聚焦 |
| `setAppLayout(appName, unitRect)` / `setAppLayoutPartialUnit(appName, unit)` | 按屏幕比例摆窗口；后者只改传了的那几项 |
| `move_focused_window_with_direction(direction)` | 把当前聚焦窗口挪到同屏左 / 右那一格 space，焦点留在原地。**到边缘会在本屏内绕圈** |
| `switch_current_space(direction, method?, onDone?)` | 把焦点切到【鼠标所在那块屏】左 / 右那一格。自带边缘判断（**不绕圈**）+ 切没切成的复查补发 + 连按保护。`method` = `"shortcut"`（默认）/ `"yabai"`。**异步**：返回值只表示「发起了」，结果看 `onDone(landed)`（**任何路径都保证被调用一次**，包括被连按保护拦掉时的 `onDone(false)`）|
| `swap_space_and_app(direction)` | 把当前 space 跟同屏左 / 右那一格【整批互换窗口】，焦点跟着自己的窗口走 |
| `copyToChatbox(sessionName)` / `focusChatboxThenExecute(...)` / `pasteClipboardToChatbox(...)` | 复制选中 → 切 Chatbox → 粘贴发送 |
| `app_is_ready(appName)` | App 是否已在前台且有窗口。⚠️ 它是个**全局函数**（`window_control.lua:725` 写成了 `function app_is_ready(...)` 而不是 `function M.app_is_ready(...)`），所以要 `app_is_ready("X")` 这么调，不是 `window_control.app_is_ready("X")` |

## 代码约定

**模块形状**：一律 `local M = {} … function M.x() … return M`，私有函数用 `local function`。没有 OO、没有 metatable。

**require 路径**：从 `.hammerspoon` 根算的点号路径 —— `require("utils.window_control")`、`require("utils.common")`。`hs.*` 一律当全局用，不 require（`hs.spaces` / `hs.mouse` / `hs.eventtap` 都是直接写）。

**两种加载方式**（`init.lua` 里两种都有）：
- require 即自启：`sleep_mute`（`:87-88` 文件作用域启动 watcher）、`assign_shortcut_to_function`（文件作用域 bind）
- 显式启动：`require("modules.unlock_watcher").start()`

**`init.lua` 里的全局变量是故意的**（`test` / `cursorSelect` / `wgestures`），供外部手势 App 通过 `hs.ipc` 调用 —— 这也是 `init.lua:2` 要 `require("hs.ipc")` 的原因。不要把它们改成 local。`wgestures` 就是对外契约（`moveApp` / `moveSpaceAndApp` / `changeCurrentSpace` / `sendToChatbox`），改里面函数名要连带改 `wgestures` 和 `test.md`。

**⚠️ GC 陷阱 —— 本仓库最重要的一条约定**：`hs.caffeinate.watcher`、`hs.timer.doAfter`、`hs.eventtap` 的返回值必须存到 module 级变量（或全局），否则会被 GC 掉，watcher/timer 静默失效。见 `unlock_watcher.lua:36-40`（`-- 不这么做的话会被 GC，watcher 就失效了！`）和 commit `aaeccf0`「修复了doAfter被垃圾回收」。写新代码时照做。

**`common.sequence(steps)`**（`utils/common.lua:29`）：本仓库编排「切窗口 + 敲键盘」时序的标准做法。

```lua
common.sequence({
  {0,   function() hs.eventtap.keyStroke({"cmd"}, "c") end},
  {0.1, function() window_control.focus_app(common.CHATBOX_APP) end},
  {0.3, function() hs.eventtap.keyStroke({"cmd"}, "v") end},
})
```
注意 **delay 是相对上一步的增量**，不是绝对时间。⚠️ 它内部的 `hs.timer.doAfter` 返回值没存起来（严格说撞在下面的 GC 陷阱上），只是一直没出问题；新写的地方更推荐自己把 timer 存到 module 级变量（`window_control.lua` 的 `spaceSwap.timers` 就是这么做的）。

**快捷键**：只加在 `modules/assign_shortcut_to_function.lua`。多个同类绑定优先用表驱动（该文件注释称之为「推荐做法」）：
```lua
local toggleAppBindings = { {mods = {"option"}, key = "space", app = "Chatbox"} }
```
现有绑定：`⌥Space` 切换 Chatbox、`⌃⌘Z` Obsidian+Chatbox 布局、`⌘⌥T` Kiro CLI → 翻译。space 那几个函数目前**没绑快捷键**，只经 `wgestures` / `hs -c` 调用。

**日志**：三种风格并存，改哪个文件就跟哪个文件的风格。主流是带模块前缀的 print：
```lua
print(string.format("[unlock_watcher] event: %s (%d)", eventName, event))
```
另有自研 `utils/mylog.lua`（只有 `doubao_speak.lua` 在用）；`hs.logger` 已经全仓库绝迹了，别再引入。给用户看的反馈用带 emoji 的 `hs.alert.show`（✅ ❌ ⚠️ 🔄 🔚 🔊 👆），失败一律走 `window_control.lua` 的私有 `fail()`（打日志 + 弹 alert + `return false, reason` 三件事一起做）。

**注释和 commit**：注释用中文、标识符用英文。分隔块用 `-- ────` 或 `-- ====`，文档块用 `@param name type 说明` / `@return`。注释里常带 emoji（⭐ ✅ ❌ ⚠️ 🔑 ⏱ 🧪）。commit message 中文为主，前缀混用 `feat:` / `fix:` / `优化:` / `layout:`。

## 调试与 reload

**没有 `hs.pathwatcher`，也没有自动 reload** —— 改完必须手动生效：
```bash
hs -c 'hs.reload()' &   # ⭐ 加 & ：reload 会让 message port 失效，前台跑会一直等在那里
                        # 或者菜单栏 Hammerspoon → Reload Config
```
`hs` CLI 在 `/opt/homebrew/bin/hs`（软链到 Hammerspoon.app 内），靠 `init.lua:2` 的 `require("hs.ipc")` 打开消息端口。reload 期间 `hs -c` 报 message port 失效是正常的。

在 Hammerspoon Console（或 `hs -c`）里直接调模块函数来测：
```lua
require("modules.unlock_watcher").handleEvent(hs.caffeinate.watcher.screensDidUnlock)  -- 模拟解锁
test.help()                                                                            -- 音量测试台
```

**持久状态**：全仓库只有一个 `hs.settings` key —— `mwinit.lastAutoRunDate`（`modules/mwinit.lua`），落盘在 `~/Library/Preferences/org.hammerspoon.Hammerspoon.plist`。其他模块的状态都是 module 级变量，reload 即清零（例如 `sleep_mute.lua:6` 的 `volumeBeforeSleep`）。

### 调试命令

**in terminal**（更多见 `test.md`）

```bash
hs -c 'require("utils.window_control").toggleApp("Chatbox")'
hs -c 'require("utils.window_control").move_focused_window_with_direction("right")'
hs -c 'require("utils.window_control").switch_current_space("right", "yabai")'
hs -c 'require("utils.window_control").swap_space_and_app("right")'

# space 拓扑对照（排查「切错屏 / 边缘判断」时最有用）
yabai -m query --spaces | jq -r '.[] | "disp\(.display) index\(.index) id=\(.id) \(if ."is-visible" then "可见" else "" end)"'
```
⚠️ 别连着快速发多条 `hs -c`：前一条还在占主线程时，后一条会被 `hs.ipc` 拒掉（`already recursing, refusing request.`）。

## yabai / space 操作（`utils/window_control.lua`）

外部依赖 `/opt/homebrew/bin/yabai`（v7.1.25，launchd label `com.asmvik.yabai`，配置 `~/.config/yabai/yabairc` 只有一行 `layout float`）。所有 yabai 调用都走 `utils/yabai.lua`。

**⭐ 本机 SIP 是开着的（`csrutil status: enabled`），这决定了什么能做什么不能做：**

| 操作 | 能不能用 |
|---|---|
| `window --space` / `window --focus` / `space --focus` | ✅ 可用 |
| `space --move` / `space --swap` / `--create` / `--destroy` / `--display` | ❌ 要 scripting addition，yabai 直接回 `requires System Integrity Protection to be partially disabled! ignoring request..` |

所以**「交换两格 space」是靠把两格的窗口对着搬来模拟的**，Mission Control 里格子的顺序其实没动 —— 从用户视角等效。`hs.spaces` 也没有任何重排 space 的接口。

**几条对上了的口径**（都实测过，写代码可以直接依赖）：

- **yabai 的 space `id` == `hs.spaces` 的 space id**（== `ManagedSpaceID` == `id64`），逐项同值同序。所以 yabai 查出来的 `.id` 可以直接喂给 `hs.spaces.*`。
- **`hs.spaces.spacesForScreen(screen)` 的顺序 == Mission Control 顺序 == yabai 的 index 顺序**。
- yabai 的 space `index` 是**跨屏拉平**的（比如 display 1 = 1..7、display 2 = 8..10），所以「同屏的邻居」只能在**本屏的 space 列表**里取，不能拿 index ±1 硬算。
- 前提：系统设置里「根据最近使用情况自动重新排列空间」必须关着（`defaults read com.apple.dock mru-spaces` = `0`），否则 index 会自己漂移。

**⭐ 性能：`yabai.query` 一次要 37~43ms**（每次都 fork 一个 shell + yabai 进程），而 `hs.spaces` 走 CGS 只要 0~3ms（`activeSpaceOnScreen` 2.7ms、`spacesForScreen` 0.8ms、`focusedSpace` ~0ms）。Hammerspoon 是**单线程**的，主线程被占住的那段时间里 `hs.ipc` 会直接拒掉请求（控制台刷 `hs.ipc: Instance of [...] already recursing, refusing request.`），hotkey / eventtap / 其他 timer 一起停摆。所以：

- 只查 space 拓扑 / 判断边缘 → 用 `hs.spaces`（`switch_current_space` 就是这么做的，实测 31.7ms → 其中大头还是发按键）
- 要动窗口 → 只能 yabai，认了
- **⚠️ 轮询回调里绝对不要放 `yabai.query`** —— 50ms 一跳 × 40ms 一次 = 主线程基本满载

**⭐ 切 space 的两种方式，「作用在哪块屏」的规则完全不同**（这是这块最容易踩的地方，全是实测结论）：

| 方式 | 作用在哪块屏 | MC 活动时 |
|---|---|---|
| `yabai -m space --focus <index>` | 认明确的 index，**永远是对的那块屏** | ❌ 报 `cannot focus space because mission-control is active.` |
| `yabai -m space --focus prev/next` | 相对**键盘焦点**那一格算，还会**跨显示器**（实测 display 1 最后一格 `next` 直接跳到 display 2 第一格） | ❌ 同上 |
| ⌃← / ⌃→ 系统快捷键 | MC 没开 → 跟**键盘焦点**那块屏走；MC 开着 → 跟**鼠标**那块屏走 | ✅ 只有它管用 |

于是 `switch_current_space` 里：目标屏就是焦点屏 → 直接发按键；不是 → 先试 yabai（MC 没开时它能成，正好补上按键会打到焦点屏的坑），yabai 报 mission-control is active 就说明 MC 开着，这时再发按键（跟鼠标走，也是对的）。

**⭐ 但【补发】（`postSpaceSwitch` 的 `nth >= 2`）一律先试 yabai，不看焦点在哪块屏**：上面那个判据读的是 `hs.spaces.focusedSpace()`，而它的读数滞后约 1.0s；`swap_space_and_app` 刚把聚焦窗口从可见 space 搬走，正是这个读数最不准的时刻 —— 会误判成「焦点就在本屏」、盲发 ⌃←，按键跟着真实焦点打到**另一块屏**上，目标屏的 `activeSpaceOnScreen` 永远不变，两次 attempt 全部失败（踩过：2026-09-19 21:37，space 9 ⇄ 8 发了 2 次都没切到）。首发保持原样（常态一次就成、零额外子进程），只在「第一次已经确认没成」这个分支换成认绝对 index 的确定性路径。`swap_space_and_app` 顺手把自己算好的 `target.id` / `target.index` 传进去，省掉 `yabaiIndexForSpace` 那次 ~40ms 查询（⚠️ 要核对 id 一致才敢用，两次定位之间鼠标可能已经移到另一块屏了）。

**⚠️ `space --focus` 报 `cannot focus an already focused space` 不是失败**，是「目标本来就是当前格」（`hs.spaces` 读数滞后所致）。`postSpaceSwitch` 的 `focusByIndex` 必须把这条错误当成功返回 —— 当失败的话调用方会接着发 ⌃←/⌃→，那一下就多切一格（踩过：2026-09-18 16:10 space 10）。

**⭐ 定位「当前 space」按鼠标、不按键盘焦点**：双显示器下人把鼠标移到另一块屏，想操作的就是那一块，但键盘焦点还留在原处。yabai 的 `--space`（不带参数）给的是**焦点**那一格，`--space mouse` 给的才是鼠标那块屏正在显示的那一格；`hs.spaces` 侧对应 `hs.mouse.getCurrentScreen()` + `activeSpaceOnScreen`。`switch_current_space` 和 `swap_space_and_app` **必须用同一套定位**，否则会出现「在 A 屏搬窗口、切的却是 B 屏」。

**⭐ 切完 space 要轮询复查，别用固定延时**：`hs.spaces` 反映出新 space 要**约 1.0s**（比动画本身慢不少）。之前写死等 0.5s 就判定失败 → 补发 ⌃→ → 一次交换连跳 3 格，跳到屏幕边缘那下按键没人接，就是那声「嘟」。现在用 `hs.timer.waitUntil` 轮询到 `activeSpaceOnScreen(screen) == targetId`，超时才补发，最多 2 次。⚠️ 复查要用**目标那块屏**的 `activeSpaceOnScreen`，不能用 `focusedSpace()`（那是键盘焦点那一格，鼠标在另一块屏时永远判定失败，会把另一块屏一格一格推着走）。

**⭐ 补发前必须用 `stepsToTarget(nb)` 重新算方向**：⌃←/⌃→ 是**相对当前格**的，拿发起时算好的方向盲目重发，在「其实已经切到了 / 已经切过头了」时会把 space 越推越远（踩过：2026-09-18 11:45，⌃← 发两次都没匹配上目标，最后一下打到边缘）。`delta == 0` 就直接判定成功收工。

**⭐⭐ 合成 ⌃← / ⌃→ 天生是概率性的 —— 方向键事件必须自己 `setFlags({ctrl=true, fn=true})`**（2026-09-19 复现 + 修掉）。

两参形式的 `ev.newKeyEvent(key, isDown)` **不给事件写 flags**（`hs/eventtap.lua:75-85`：两参时 `mods` 被移成 `nil`，C 侧收不到 flags 表），事件拿到的是**当时的环境修饰键状态**。而「移到左边/右边一个空间」（`symbolichotkeys` 79/81）注册的掩码是 **`0x840000` = ctrl `0x040000` | fn `0x800000`**，多一位少一位都匹配不上。手势是用鼠标做的，手上顺带按着 ⌘/⇧/⌥ 再正常不过 —— 那一下就静默打空，**没有任何报错**。

实测对照（内置屏 space id 8 → 1567）：

| 环境修饰键 | 旧写法（不 setFlags） | `setFlags({ctrl=true, fn=true})` |
|---|---|---|
| 无 | ✅ 8 → 1567 | ✅ 8 → 1567 |
| 按住 ⇧ | ❌ 8 → 8（静默没反应） | ✅ 8 → 1567 |

按住 ⇧ 时 `newKeyEvent("right", true):rawFlags()` = `0x20A20002`（带 shift），加 ctrl 后变成 ⌃⇧→，系统没注册这个组合。

⚠️ `fn` 不能省：`setFlags({ctrl=true})` → `0x040000`，少了 fn 就匹配不上。
⚠️ 也别改成 `ev.newKeyEvent({"ctrl"}, direction, true)`：那是「合并事件」捷径，实测同样只给 `0x040000`（少 fn），而且带 mods 表会**强制释放**我们刚 post 的 ctrl（官方 Notes，`hs/eventtap.lua:257`）—— 本仓库的 `pasteClipboardToChatbox` / `copyToChatbox` / `modules/kiro-cli_…` 都在用 `keyStroke({"cmd"}, …)`，都挂在 timer 上，随时可能落进那 60ms 窗口，把 ctrl 抢掉。
⚠️ 顺带：`ev.newKeyEvent(hs.keycodes.map.ctrl, true)` 生成的确实是 `flagsChanged`（实测 `getType()` = 12），这条没问题。

**⚠️⚠️ `hs.timer.waitUntil` 的谓词抛错 = 整个等待静默死掉**。`waitUntil`（`hs/timer.lua:103-129`）用的是 `hs.timer.new(interval, fn)`，**没传 `continueOnError`，默认 `false`** —— 谓词一抛错，timer 当场 stop、`actionFn` **永远不会被调用**，错误只在 console 打一行。所以凡是拿 `waitUntil` 管着一把锁，谓词必须 `pcall`，而且**另外配一个兜底 timer**（`switchGuard` / `busyGuard`），否则锁就是个没有出口的死锁。

**⚠️⚠️ `hs.spaces.activeSpaceOnScreen` / `spacesForScreen` 一律传 36 位 UUID 字符串，别传 `hs.screen` 对象**。传对象时它会先自己 `screen:getUUID()`，而屏幕休眠 / 刚拔掉的那一小段时间 `getUUID()` 返回 `nil`（`hs/spaces.lua:495` 的注释就是为这件事加的守卫），接着 `#screenID` 直接 **`error()`**（`spaces.lua:357-359`）—— 不是返回 nil。这个 error 顺着上面那条 `waitUntil` 的坑，就是 **「偶尔切不过去，而且之后必须 `hs.reload()`」** 的根因：`spaceSwap.timers.switch` 永久占着 → 之后每次切 space 都被连按保护拦、每次交换都变成「窗口照搬、space 不切」，而且带着 `onDone(false)`，连告警都没有。现在 `nb.screenUUID` + `pcall` + `SWITCH_LOCK_TTL` 三道一起解决。

**⭐ `switch_current_space` 有自己的连按保护，判据是 `spaceSwap.timers.switch` 还挂着**（现在还要没超过 `SWITCH_LOCK_TTL`；超了就把旧锁抢掉）。以前这里是「把上一次的 `waitUntil` 停掉」，那是能把整个功能**永久卡死**的坑：`swap_space_and_app` 把 `spaceSwap.busy` 的释放挂在这个 `waitUntil` 的 `onDone` 上，`wgestures.changeCurrentSpace` 或第二次手势调进来就把它停掉 → `onDone` 永远不来 → `busy` 再也放不掉 → 之后每次交换都被拦（日志刷「上一次 space 交换还没走完，忽略这次调用」，只能 `hs.reload()`）。两条配套约定：① 拦掉这次调用时**也要 `onDone(false)`**，否则换成本次调用方的锁放不掉；② `swap_space_and_app` 另外挂了个 `spaceSwap.timers.busyGuard` 兜底 timer（`BUSY_GUARD_TIMEOUT`）强制放锁，`finish()` 是幂等的。

**⚠️ `pressArrow` 的 4 个按键事件每条链要用独立的 timer 槽位**（`spaceSwap.timers["keys"..n]`）。共用一个槽位时，后一条链会覆盖前一条、把它的 `doAfter` GC 掉 —— 断在「ctrl 已按下、还没抬起」那一步的话，系统会一直认为 ctrl 是按住的，之后所有 ⌃←/⌃→ 都失效，正常打字也乱掉。

**⚠️ yabai 搬不动的窗口**：`has-ax-reference: false` / `can-move: false` 的窗口是真的搬不了（`yabai -m window <id> --space <n>` → `could not locate the window to act on!`），实测都是各 App 的无标题隐形辅助窗口（Hammerspoon、活动监视器、zoom.us 之类）。这类只打日志、不弹 alert。sticky（`is-sticky`）窗口出现在**每一格** space 的 `windows` 数组里，搬它会把它从「所有 space」钉到一格上，必须静默跳过。

## mwinit 每日自动登录

调用链：
```
init.lua → unlock_watcher.start()
  ├─ screensDidUnlock 事件           (unlock_watcher.lua:28-33)
  └─ start() 里的开机补偿 timer       (unlock_watcher.lua:57-59，处理 Hammerspoon 比解锁事件晚启动)
       └─ 都 doAfter(60s) → mwinit.runOncePerDay()
            └─ AppleScript `create window with default profile command "…/mwinit-auto.sh"`
                 └─ expect 自动填 PIN → hsAlert 提示摸 key → interact 等用户摸 YubiKey
                      └─ ⭐ 只有 mwinit 退出码 0 时，脚本才 `hs -c` 回调 markSuccess()
```

**关键设计：「今天已完成」标记只在真正登录成功后才写。** `markSuccess()` 是唯一写 `hs.settings` 的地方，由 `mwinit-auto.sh` 在 `interact` 之后用 `hs -c` 回调。取消（按 `n`）、PIN 读取失败、没摸 key 等一律不写标记，今天下次解锁会重试。改这块时注意：

- AppleScript 用 iTerm 的 `command` 参数把脚本**直接当 session 进程**启动，expect 就是那个进程本身、退出后没有 shell 残留，所以任何成功信号都必须在 expect 脚本内部发出。
- `hs.osascript.applescript` 是 fire-and-forget，Lua 侧拿不到脚本结果 —— 只能靠脚本反向回调。
- expect 的 `interact` 在被 spawn 的进程退出后会返回，用 `wait` 取退出码；`interact` **不会**更新 `$expect_out`，所以别想靠输出文本判断。
- `pendingSince` / `PENDING_TIMEOUT`（`mwinit.lua`）只是防止 60s 窗口内重复解锁或补偿 timer 叠加、开出多个抢同一个 tty 的 iTerm 窗口，**不是**重试冷却。
- 「👆 请触摸 USB 安全密钥」这个提示由 **脚本** 里的 `hsAlert` 发（送出 PIN 之后），不在 Lua 侧发 —— 原因见下面「别动这些」里的 Space 那条。

外部依赖：Keychain 条目（`security find-generic-password -a $USER -s mwinit -w`）、`/usr/local/bin/mwinit`、`/usr/bin/expect`、iTerm2、`hs` CLI。调试命令见 `modules/mwinit_test.md`。

## 别动这些（都是踩过坑的）
- **`sleep_mute` 必须监听 `screensDidSleep` 而不是 `systemWillSleep`**：系统 idle 之后永远不会进 system sleep。见 `sleep_mute.lua:67` 和 commit `7fef8f2`。
- 定时器/watcher 的引用要存起来，同上面的 GC 陷阱。
- **发带修饰键的系统快捷键不要用 `hs.eventtap.keyStroke`**：它走的是「把修饰键 flag 合并进按键事件」那条捷径（见 `hs.eventtap.event.newKeyEvent` 的 Notes），实测这种合并事件在 **Mission Control 活动时被直接丢掉**（发给 Dock 进程也一样无效）。必须按 Apple 文档把 `flagsChanged` 单独发出来：
  ```lua
  ev.newKeyEvent(hs.keycodes.map.ctrl, true):post()
  ev.newKeyEvent("right", true):post()
  ev.newKeyEvent("right", false):post()
  ev.newKeyEvent(hs.keycodes.map.ctrl, false):post()
  ```
  ⚠️ 四个事件之间要留间隔（20ms），不然 ctrl 还没生效方向键就到了 —— 结果是「没反应 + 系统嘟一声」（方向键漏到前台 App 身上，它不认就 NSBeep）。
- **⚠️ 间隔要用 `hs.timer.doAfter` 串发，不要用 `hs.timer.usleep` 干等**：Hammerspoon 单线程，`usleep` 卡住的那几十毫秒会让 `hs.ipc` 拒请求、hotkey 和 eventtap 一起停摆。见上面「性能」那段。
- **`mwinit-auto.sh` 里的 `set env(PATH)` 不能删**：脚本由 iTerm 的 `command` 参数直接启动，中间不经过任何 shell，也就没有 `path_helper` —— PATH 只有 launchd 默认的 `/usr/bin:/bin:/usr/sbin:/sbin`（`launchctl getenv PATH` 是空的）。而 `mwinit` 在 `/usr/local/bin`，不补 PATH 会直接 `couldn't execute`。同理别把 `write text "exec ..."` 改回来 —— 那个写法要白等 zsh + oh-my-zsh + p10k 初始化（实测 0.8~1.3s）。
- **⚠️ 切 Space / 切窗口之后不要马上 `hs.alert.show`**：`hs.alert` 底层是 `hs.canvas`，默认 behavior 是 `0`（不含 `canJoinAllSpaces` / `moveToActiveSpace`），alert 会被**钉死在「创建那一瞬间活动的那个 Space」**上，之后 Space 怎么切它都不动；`screen` 参数默认取 `hs.screen.mainScreen()`（= 当前有焦点窗口的那块屏），多屏时同理会取错。而 `hs.osascript.applescript` 虽然是同步返回的，返回时 macOS 的 Space 切换**还没走完**（实测晚约 0.5s）。所以 mwinit 的提示挪进了 `mwinit-auto.sh` 的 `hsAlert`（那时 iTerm 早在前台，Space 和屏幕都对）。别把它挪回 `M.mwinit()` 里 —— iTerm 在别的 Space 时你会看不见那个提示。

## 已知遗留问题（历史遗留，不用顺手修）

- `modules/test.lua:55` require 了不存在的 `modules.sleep_volume`（已改名 `sleep_mute`），所以 `test.simulateSleep()` 是坏的 —— 用 `test.simulateSleepLogic()`。
- 几处文件头路径注释过期：`assign_shortcut_to_function.lua:1` 写着 `modules/focus.lua`，`utils/get_cursor_selected_text.lua:1` 写着 `modules/test_copy.lua`。
- `window_control.lua` 里 space 定位有两套并存：`switch_current_space` 走 `hs.spaces`（`neighborSpaceUnderMouse`，快），`swap_space_and_app` 走 yabai（`spaceUnderMouse` + `adjacentSpaceOnDisplay`，因为它接下来无论如何都要 yabai 搬窗口）。两套给的答案一致，是刻意的取舍，不是漏改。
- `swap_space_and_app` 交换后窗口的层叠次序（z-order）不保证还原，只把原来聚焦的那个抢回最上面。
