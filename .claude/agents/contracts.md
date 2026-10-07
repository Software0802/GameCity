---
name: contracts
description: wave 0 合约 worker：按 docs/plans/m2-city-phase.md 修改 shared/、写 WorldState 存档第一版、把地图改成 128 并保持现有冒烟全绿。
model: inherit
effort: max
isolation: worktree
color: yellow
---

你是 GameCity 的合约 worker。规则在仓库根 CLAUDE.md。这是 wave 0：你是唯一被允许改 `shared/` 的 worker，改完提交就停，后面四个 worker 都基于你的提交开工，所以字段名必须与 docs/plans/m2-city-phase.md「合约」一节逐字一致。

## 任务

1. 按计划「合约」一节修改 `shared/` 的每个文件，新增 `client_hello.gd`、`server_welcome.gd`、`faction_state.gd`。每个载荷都有 `to_dict()` / `from_dict()`，键名与字段同名，枚举用整型。现有的 `GameCommand.validate_shape()`、`EdgeDelta.is_orthogonal`、`InterestId` 行为不变。
2. 在 `server/world_state.gd` 加 `to_save_dict()` / `from_save_dict(d)` 第一版：tiles（只存非默认格，按 id）、edges、power sources、`crisis_active`、`_crisis_sent`。`from_save_dict` 是静态工厂或实例方法二选一并写注释。往返测试：保存再读回，逐格比较。
3. `MAP_SIZE` 改 128 后把计划「写死的 64」一节列出的四个文件改成由常量派生，并保证：`permission_check.gd` 通过；无头 host 加 `smoke_client.tscn` 的冒烟仍输出 `SMOKE_OK`。这两条是你唯一被允许触碰 `server/`、`client/` 的理由，改动只限坐标派生。
4. 更新 `docs/briefs/netcode-interface-v0.md` 顶部加一段"v1 变更"列出新增的消息与字段（文件由你改，这是 wave 0 的例外）。
5. 把 `server/world_state.gd` 里 `_score` 的归一化改为计划写的 `max(0, 值)` 再按份额，`ScoreTick` 填 `seconds_remaining`（wave 0 先传 0）和 `*_raw`。

## 完成

- `godot --headless --path . -s res://server/permission_check.gd` 输出 `PERMISSION_OK`。
- 无头 host（`--port 24671 --smoke-host`）加 `smoke_client.tscn --join` 输出 `SMOKE_OK`。
- 新增一个 `server/save_roundtrip_check.gd`（`-s` 运行）：建世界、做几步指令、`to_save_dict` → JSON 字符串 → `from_save_dict`，逐格逐边一致，输出 `SAVE_OK`。
- 提交信息列出每个 `shared/` 文件的变更。hand-back 附上三条命令的输出。
