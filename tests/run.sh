#!/bin/bash
# 跑 clipboard action 规则测试。要 Hammerspoon 在跑（借它的 Lua 环境）
# 用法：tests/run.sh       全部通过退出码 0，否则 1
# ⚠️ </dev/null 不能省：stdin 不是终端时 hs 会去读 stdin，在 $(...) 里会一直卡住
out=$(hs -c 'return dofile(hs.configdir .. "/tests/clipboard_action_rules_test.lua")' </dev/null 2>&1)
echo "$out"
grep -q "✅ 全部通过" <<<"$out"
