local M = {}

local DEFAULT_WAKE_VOLUME = 60
local UNMUTE_AFTER_UNLOCK_TIME = 3
-- 记住睡眠前的音量，这样唤醒时可以恢复到原值（而不是固定的 80）
local volumeBeforeSleep = nil

-- 带重试的恢复函数
local function restoreVolume(attempt)
  attempt = attempt or 1
  local maxAttempts = 5

  local device = hs.audiodevice.defaultOutputDevice()
  if not device then
    print(string.format("[Restore #%d] 无设备，0.5s 后重试", attempt))
    if attempt < maxAttempts then
      hs.timer.doAfter(0.5, function() restoreVolume(attempt + 1) end)
    end
    return
  end

  local target = volumeBeforeSleep or DEFAULT_WAKE_VOLUME
  if target < 5 then target = DEFAULT_WAKE_VOLUME
  end

  -- 尝试设置
  device:setVolume(target)
  device:setMuted(false)   -- ⭐ 新增：解除静音

  -- 🔑 读回来确认是否真的设成功了
  hs.timer.doAfter(0.2, function()
    local d2 = hs.audiodevice.defaultOutputDevice()
    local actual = d2 and d2:volume() or -1
    local muted = d2 and d2:muted() or "false"
    print(string.format("[Restore #%d] 目标=%.0f, 实际=%.1f, muted=%s, device=%s",
      attempt, target, actual, tostring(muted), d2 and d2:name() or "nil"))

    if actual and actual >= target - 5 then
      -- ✅ 成功
      hs.alert.show(string.format("🔊 音量恢复至 %.0f%%", target))
    elseif attempt < maxAttempts then
      -- ❌ 失败，重试
      hs.timer.doAfter(0.5, function() restoreVolume(attempt + 1) end)
    else
      print(string.format("[Restore] 重试 %d 次后仍失败", maxAttempts))
      hs.alert.show("⚠️ 音量恢复失败")
    end
  end)
end

local function caffeinateCallback(eventType)
  -- 详细日志
  local eventName = "unknown"
  for k, v in pairs(hs.caffeinate.watcher) do
    if v == eventType then eventName = k; break end
  end
  
  local dev = hs.audiodevice.defaultOutputDevice()
  if not dev then return end
  local devName = dev and dev:name() or "nil"
  local vol = dev and dev:volume() or "nil"
  
  print(string.format("[Caffeinate] event=%s | device=%s | vol=%s | volumeBeforeSleep=%s",
    eventName, devName, tostring(vol), tostring(volumeBeforeSleep)))

  -- ========== 睡眠/锁屏时静音 ==========
  if eventType == hs.caffeinate.watcher.systemWillSleep then
    local device = hs.audiodevice.defaultOutputDevice()
    -- 记录睡眠前的音量
    volumeBeforeSleep = device:volume()
    print(string.format("[Mute] 记录音量 %.0f，准备静音", volumeBeforeSleep))
    device:setVolume(0)
    device:setMuted(true)    -- ⭐ 新增：同时开启静音
    print("[Sleep] 已静音")
    print(string.format("[Sleep] 音量 %.0f → 0", volumeBeforeSleep or -1))

  -- ========== 解锁/唤醒时恢复 ==========
  elseif eventType == hs.caffeinate.watcher.screensDidUnlock then
    -- 优先恢复睡眠前的音量；如果没记录到，用默认的 WAKE_VOLUME
    local targetVolume = volumeBeforeSleep or DEFAULT_WAKE_VOLUME
    print("[Restore] 已安排 3 秒后恢复音量")
    hs.timer.doAfter(UNMUTE_AFTER_UNLOCK_TIME, function() restoreVolume(1) end)
  end
end

M.watcher = hs.caffeinate.watcher.new(caffeinateCallback)
M.watcher:start()

return M
