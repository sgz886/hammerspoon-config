-- ~/.hammerspoon/modules/test.lua
-- 测试工具模块：用于在 Console 里手动触发各种测试

local M = {}

-- ============================================
-- 1. 设备信息查看
-- ============================================
function M.showDeviceInfo()
  local dev = hs.audiodevice.defaultOutputDevice()
  if not dev then
    print("❌ 没有默认输出设备")
    return
  end
  print("========== 当前输出设备 ==========")
  print("设备名:", dev:name())
  print("UID:", dev:uid())
  print("音量:", dev:volume())
  print("是否静音:", dev:muted())
  print("===================================")
end

-- ============================================
-- 2. 列出所有输出设备
-- ============================================
function M.listAllDevices()
  print("========== 所有输出设备 ==========")
  local defaultUID = hs.audiodevice.defaultOutputDevice():uid()
  for _, d in ipairs(hs.audiodevice.allOutputDevices()) do
    local mark = (d:uid() == defaultUID) and "⭐" or "  "
    print(string.format("%s %s | volume=%s", mark, d:name(), tostring(d:volume())))
  end
  print("===================================")
end

-- ============================================
-- 3. 手动设置音量
-- ============================================
function M.setVolume(vol)
  local dev = hs.audiodevice.defaultOutputDevice()
  if not dev then
    print("❌ 没有默认输出设备")
    return
  end
  dev:setVolume(vol)
  print(string.format("✅ 音量已设为 %.0f", vol))
end

-- ============================================
-- 4. 模拟"即将睡眠"事件
-- ============================================
function M.simulateSleep()
  print("🧪 模拟睡眠事件...")
  -- 手动触发 caffeinate watcher 回调
  local watcher = require("modules.sleep_volume").watcher
  -- 直接调用底层的回调逻辑（通过发送真实事件类型）
  -- 但 watcher 的回调是私有的，所以我们换个思路：直接 require 并调用其逻辑
  print("⚠️ 注意：watcher 的 callback 是内部的，我们用另一种方式模拟")
  print("   → 请直接调用 test.simulateSleepLogic() 测试逻辑")
end

-- ============================================
-- 5. 模拟睡眠/唤醒的业务逻辑（推荐用这个测试）
-- ============================================
local WAKE_VOLUME = 80
local volumeBeforeSleep = nil

function M.simulateSleepLogic()
  print("🧪 ===== 模拟：系统即将睡眠 =====")
  local dev = hs.audiodevice.defaultOutputDevice()
  if not dev then print("❌ 无设备"); return end
  
  local cur = dev:volume()
  if cur == nil then
    print("⚠️ 当前设备不支持音量控制")
    return
  end
  volumeBeforeSleep = cur
  dev:setVolume(0)
  print(string.format("✅ [Sleep] 音量 %.0f → 0", cur))
  print(string.format("   记录的 volumeBeforeSleep = %.2f", volumeBeforeSleep))
end

function M.simulateWakeLogic()
  print("🧪 ===== 模拟：系统已唤醒 =====")
  local dev = hs.audiodevice.defaultOutputDevice()
  if not dev then print("❌ 无设备"); return end
  
  local target = volumeBeforeSleep or WAKE_VOLUME
  print(string.format("   volumeBeforeSleep = %s", tostring(volumeBeforeSleep)))
  if target < 5 then
    print(string.format("   睡前音量 %.0f < 5，改用默认 %d", target, WAKE_VOLUME))
    target = WAKE_VOLUME
  end
  dev:setVolume(target)
  hs.alert.show(string.format("🔊 音量已恢复至 %.0f%%", target))
  print(string.format("✅ [Wake] 音量恢复至 %.0f", target))
end

-- ============================================
-- 6. 一键完整流程测试（睡眠 → 等 3 秒 → 唤醒）
-- ============================================
function M.runFullCycle()
  print("🚀 开始完整周期测试...")
  M.simulateSleepLogic()
  print("⏳ 3 秒后模拟唤醒...")
  hs.timer.doAfter(3, function()
    M.simulateWakeLogic()
    print("✅ 完整周期测试完成")
  end)
end

-- ============================================
-- 7. 真正触发系统睡眠（慎用！）
-- ============================================
function M.realSleep()
  print("💤 10 秒后真正进入系统睡眠...")
  print("   （按任意键或动鼠标可唤醒）")
  hs.timer.doAfter(10, function()
    hs.caffeinate.systemSleep()
  end)
end

-- ============================================
-- 打印使用帮助
-- ============================================
function M.help()
  print([[
========== 测试命令列表 ==========
test.showDeviceInfo()       -- 查看当前设备信息
test.listAllDevices()       -- 列出所有输出设备
test.setVolume(50)          -- 手动设置音量到 50
test.simulateSleepLogic()   -- 模拟睡眠逻辑（音量→0）
test.simulateWakeLogic()    -- 模拟唤醒逻辑（音量恢复）
test.runFullCycle()         -- 睡眠+3秒后唤醒的完整流程
test.realSleep()            -- 10 秒后真正让系统睡眠
test.help()                 -- 显示此帮助
===================================
  ]])
end

print("✅ test.lua 已加载，输入 test.help() 查看可用命令")

return M
