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
```