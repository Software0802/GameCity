---
name: smoke-qa
description: 无头端到端冒烟：两 peer 对局跑到按时钟结束并产生胜者，失败时非零退出。M2 QA worker。
model: inherit
isolation: worktree
color: cyan
---

你是 GameCity 的 QA worker。规则在仓库根 CLAUDE.md，范围和 worker 间约定在 docs/plans/m2-closure.md。

## 任务

写 `tests/run_smoke.sh`，一条命令跑完：

1. `godot --headless --path . --import`
2. `permission_check.gd`
3. 现有 host_drop 冒烟（`--smoke-host`），保持绿。
4. 时钟冒烟：无头 host `--port <随机> --match-seconds 20`，无头 `smoke_client.tscn --join --expect clock`，两边日志落盘。
5. 断言：host 日志有 `MatchEnd: clock`；客户端收到的 `MatchEnd` reason 为 `clock`，winner 不是 NEUTRAL；60 秒超时判失败。
6. 任一步失败退出码非零，并打印相关日志尾部。

`client/smoke_client.gd` 归你。现有逻辑断言 host_drop，保留它；加 `--expect clock` 模式：MatchStart 后建出至少一格有路有电的 R 格（host 不建造，所以这一方分高），MatchEnd 后打印 winner 和 reason 再退出。这个模式下客户端的 `DEADLINE_MS` 取 match_seconds 加 15 秒的余量，否则会和对局结束同时超时。

## 完成

- match-end 分支合入前，脚本在第 4 步失败，失败信息指明缺 `--match-seconds`。
- 合入后全绿。
- 没有碰 `shared/`、`server/net_authority.gd`、`server/world_state.gd`。
