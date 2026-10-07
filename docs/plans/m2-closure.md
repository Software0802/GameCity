# M2：闭环

目标：docs/briefs/gameplay-vertical-slice.md「验收」三条全部达成。引擎按 brief 锁定的 Godot 4，渲染器为工程默认 Forward+。M2 的画面是纯色几何，程序化中等写实在 M4 接入。

## 顺序

1. 集成者改合约（`shared/`），提交后冻结：
   - `ScoreTick.seconds_remaining: int`
   - `ScoreTick.FactionScore` 的 pop / fiscal / control 为归一化后的 0–1 值，`total` 为加权和。归一化前每项先 `max(0, 值)`，再按 己方 / (己方 + 对方)，双方都为 0 取 0.5
   - 同步改 docs/briefs/netcode-interface-v0.md 里「`total` 不是归一化后的 0–1 分」那一句
   - `MatchEnd.final_scores: ScoreTick`，可空
   - `MatchEnd.reason` 取值：`host_drop`、`clock`
2. 三个 worker 并行，各自 worktree：match-end、client-view、smoke-qa。角色文件在 `.claude/agents/`。
3. 集成者按 match-end → smoke-qa → client-view 合并，跑 `tests/run_smoke.sh`，开 PR 等负责人批准。

## worker 之间的约定

- `--match-seconds <int>`：match-end 实现，smoke-qa 和 client-view 使用。默认 2100。
- `--expect clock`：smoke-qa 实现在 smoke_client.gd。
- 危机在时长一半触发。
- 画面只依赖 `ClientSession` 已有数据加 `last_score.seconds_remaining`。

## 不在 M2

重连身份、3–4 人大厅、C/I 需求三角、建筑升档、财政公式、美术包接入。
