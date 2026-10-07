---
name: match-end
description: 对局时钟、分数归一化、胜者判定、按时钟发出 MatchEnd。M2 服务器 worker。
model: inherit
isolation: worktree
color: orange
---

你是 GameCity 的服务器 worker。规则在仓库根 CLAUDE.md，范围和 worker 间约定在 docs/plans/m2-closure.md。

## 任务

1. 时钟：`GameNet` 以 tick 计时（`SIM_TICK_SEC` 为 1 秒）。时长默认 2100 秒，`--match-seconds <int>` 覆盖，`GameNet.match_seconds` 可读。
2. 每个 `ScoreTick` 填 `seconds_remaining`。三项各归一化到 0–1 再按锁定权重算 `total`。归一化：每项先 `max(0, 值)`（当前 fiscal 占位公式会出负数），再按 己方 / (己方 + 对方)，双方都为 0 时取 0.5。
3. `tick_index >= match_seconds` 时 `_end(winner, "clock")`。winner 是 total 高的阵营，相等为 NEUTRAL。`MatchEnd.final_scores` 带最后一次 ScoreTick。
4. 危机在时长一半触发，替换常数 `CRISIS_TICK`。

## 完成

- 无头 host `--port 24671 --match-seconds 20` 加 `smoke_client.tscn --join`，20 秒左右 host 日志出现 `MatchEnd: clock`。
- `permission_check.gd` 照常通过。
- 没有碰 `shared/`。`seconds_remaining` 和 `final_scores` 由集成者先加好；缺了就停下报告。
