# M2：城市期

目标见 docs/briefs/design-v2.md 的 M2A / M2B。两道合并门：**M2A 基础设施**先合，**M2B 模拟**后合。四个 worker 并行开发，合并有先后。

## 顺序

0. **wave 0，contracts worker**：改 `shared/` 合约，写 `WorldState.to_save_dict()` / `from_save_dict()` 第一版（现有字段），把地图改成 128 并修好现有冒烟。提交后 `shared/` 冻结。
1. **wave 1，四个 worker 并行**：server-core、sim-economy、client-play、smoke-qa。各自 worktree。
2. **合并 M2A**：server-core → client-play → smoke-qa（基础设施部分）。跑全部冒烟。部署到云机（负责人确认后）。
3. **合并 M2B**：sim-economy → smoke-qa（模拟部分）。再部署。

## 合约（wave 0 交付，字段名即接口）

### `slice_constants.gd`
- `MAP_SIZE = 128`，`INTEREST_BLOCK = 8`，`BLOCKS_PER_AXIS` 派生。
- `SIM_TICK_SEC = 1.0`，`ROUND_SECONDS_DEFAULT = 604800`，`ROUND_SECONDS_TEST = 3600`，`PACE_DEFAULT = 1.0`。
- `SAVE_FORMAT_VERSION = 1`，`PROTOCOL_VERSION = 1`。
- `FIELD_QUANT = 8`：连续字段按 1/8 量化，只在跨档时发事件。
- 经济占位：`START_TREASURY 5000`、`COST_CLAIM_BASE 50`、`COST_CLAIM_GROWTH 0.01`（每已占一格加 1%）、`COST_EDGE 20`、`COST_POWER 400`、`UPKEEP_POWER_PER_SEC 0.5`、`TAX_RATE_DEFAULT 0.10`、`TAX_RATE_MIN 0.0`、`TAX_RATE_MAX 0.30`、`INCOME_PER_POP_PER_SEC 0.02`、`INCOME_PER_JOB_PER_SEC 0.01`。
- 成长占位：`POWER_RADIUS 4`、`POWER_PLANT_CAPACITY 20`、`TIER_UP_SECONDS 120`、`TIER_DOWN_SECONDS 180`、`SAT_UP 0.7`、`SAT_DOWN 0.3`、`TIER_POP = [1, 3, 8]`、`TIER_JOBS = [2, 6, 16]`、`POLLUTION_RADIUS 3`、`CONGESTION_CAPACITY 10`。
- 危机：`CRISIS_AT_FRACTION 0.5`、`CRISIS_DURATION_SEC 90`、`CRISIS_CAPACITY_FACTOR 0.5`。
- 删除 `MATCH_MINUTES_*`。保留 `Owner`、`Zone`、`tile_id`、`in_map`、`is_zone`。

### `commands.gd`
- 新增 `Kind.SET_TAX_RATE`，字段 `rate: float`，工厂 `GameCommand.set_tax_rate(rate)`。`validate_shape()`：rate 不在 `[TAX_RATE_MIN, TAX_RATE_MAX]` → `INVALID_RATE`。阵营级指令，地块字段不用。

### `reason_codes.gd`
- 新增 `INSUFFICIENT_FUNDS`、`INVALID_RATE`、`NOT_AUTHENTICATED`。

### `tile_delta.gd`
- 新增 `satisfaction: float`（0–1，量化）、`pollution: float`（0–1，量化）、`brownout: bool`。`power_covered` 仍表示"在某电站半径内"；实际有电 = `power_covered and not brownout`。

### 新增 `client_hello.gd`（`ClientHello`）
- `token: String`（可空）、`name: String`（1–24 字符）、`protocol: int`。客户端连上后第一条消息，走 RPC `hello_rpc(dict)`。

### 新增 `server_welcome.gd`（`ServerWelcome`）
- `token`、`player_id: int`、`faction: int`、`name`、`returning: bool`。作为 `ServerEvent.Kind.WELCOME` 下发，是该连接收到的第一条事件。

### 新增 `faction_state.gd`（`FactionState`）
- `faction`、`treasury: float`、`income_per_sec: float`、`population: int`、`jobs: int`、`technicians: int`（M2 恒 0）、`tax_rate: float`、`demand_r / demand_c / demand_i: float`（−1..1）、`power_capacity: int`、`power_load: int`。
- `ServerEvent.Kind.FACTION_STATE`。**只发给该阵营的玩家**，不是全局事件，也不按兴趣区路由。

### `match_start.gd`
- 新增 `round_seconds: int`、`round_ends_at_unix: int`、`server_unix: int`、`pace: float`。

### `score_tick.gd`
- 新增 `seconds_remaining: int`。`FactionScore.pop / fiscal / control` 为归一化 0–1；新增 `pop_raw / fiscal_raw / control_raw` 给 HUD 显示。归一化：每项先 `max(0, 值)`，再 己方 / (己方 + 对方)，双方都为 0 取 0.5。

### `match_end.gd`
- 新增 `final_scores: ScoreTick`（可空）。`reason` 取值：`clock`、`server_stop`（原 `host_drop` 改名）。

### `crisis_event.gd`
- 新增 `kind: String`（`grid_storm`）、`ends_at_unix: int`。

### `power_alert.gd`
- 新增 `brownout: bool`。

### `region_summary.gd`
- 新增 `pollution_avg: float`、`brownout: bool`。

### `server_event.gd`
- 新增 `WELCOME`、`FACTION_STATE` 两种 kind 及 `with_*` 工厂，字典键 `welcome`、`faction_state`。

### 存档信封（server-core 实现，形状在此锁定）
```
{
  "version": SAVE_FORMAT_VERSION,
  "saved_at_unix": int,
  "round": {"started_at_unix": int, "ends_at_unix": int, "pace": float, "phase": "play" | "ended", "crisis_fired": bool, "tick": int},
  "players": [{"player_id": int, "token_sha256": String, "name": String, "faction": int, "last_seen_unix": int}],
  "world": WorldState.to_save_dict()
}
```
`WorldState.to_save_dict()` / `from_save_dict(d)` 在 `server/world_state.gd`，wave 0 写第一版（tiles、edges、power sources、crisis 标志），sim-economy 扩展（阵营经济、计时器）。一律走 `to_dict()` 链到 JSON，不用 `var_to_bytes` 的 full objects。

### 握手
连接 → 客户端 `hello_rpc` → 服务器校验：无 token 则新建玩家并签发；已知 token 则恢复；未知 token 视为新玩家。→ `WELCOME` → `MATCH_START` → 兴趣区快照。`WELCOME` 之前的指令一律 `NOT_AUTHENTICATED`。阵营分配：按两阵营当前人数取少的一边，同数时 A。

## worker 之间的接缝

| 接缝 | 提供方 | 使用方 |
| --- | --- | --- |
| `WorldState.to_save_dict / from_save_dict` | wave 0 → sim-economy 扩展 | server-core |
| `WorldState.set_crisis(active: bool)` | sim-economy | server-core 按 `CRISIS_AT_FRACTION` 调用 |
| `WorldState.faction_states() -> Array[FactionState]` | sim-economy | server-core 路由给各阵营 |
| `WorldState.score(seconds_remaining) -> ScoreTick` | sim-economy | server-core |
| `WorldState.free_build: bool` | sim-economy 读 | server-core 从 `--free-build` 设 |
| `--pace`、`--round-seconds`、`--save-dir`、`--save-interval`、`--status-file`、`--port`、`--free-build`、`--new-round`、`--start-treasury` | server-core 解析 | smoke-qa、client-play |
| `WorldState.set_treasury_all(amount: float)` | sim-economy | server-core 在 `WorldState.new()` 后按 `--start-treasury` 调用，恢复存档时不调用 |
| 事件量化：连续字段只在跨 1/8 档时发 `TileDelta` | sim-economy | client-play 的重绘频率依赖它 |
| 客户端身份文件 `user://identity.cfg`（token、name） | client-play | smoke-qa 的重连测试复用同一读写类 |

## 写死的 64 必须清掉（wave 0 负责）

- `server/world_state.gd`：`SPAWN_B := Vector2i(56, 56)` → 由 `MAP_SIZE - SPAWN_SIZE` 派生。
- `server/permission_check.gd`：`claim_tile(64, 0)` 越界用例改用 `MAP_SIZE`；`(56,56)`、`(57,56)` 改为出生地派生坐标。
- `client/smoke_client.gd`：`(55,56)`、`(56,56)`、`(57,56)` 同上。
- `client/presentation.gd`：`cursor = Vector2i(55, 56)` 与 `dist := 56.0` 同上；相机取景按 `MAP_SIZE`。

## 完成状态（2026-10-08 03:00）

M2A、M2B 全部合入 `chore/agent-coordination`：`tests/run_smoke.sh` 7/7、`server_core_check.sh` 6 场景、`sim_check` / `persistence_check` / `session_check` / `view_check` 全绿；真实服务器加开窗客户端验证了握手、令牌重连（`returning=true`）、存档恢复、HUD 实时数值。

## M2 打磨项（已记录，未做）

- `TileDelta` 缺"此格有电站"标记：客户端画不出电站本体，也没有 `RemovePower` 工具入口。client-play 的提议是加 `has_power_plant: bool`（合约改动，服务器端在 `WorldState._copy_tile / _place_power / _remove_power` 填值）。
- 人口按档位无条件计数：tier 0 的 R 格没路没电也算 1 人口，与 design-v2「R 要形成人口必须同时有路和电」有出入。改法：`TIER_POP` 只在满意度门（有路且有电）通过时计入。
- `RemoveEdge` 没有工具栏入口。
- HUD 文案为英文（默认字体不含 CJK）；污染没有专门调色板色，暂用 I 区密集色半透明。
- 升档后 pop 3 > jobs 2 的孤立 R+C 组合会来回跷跷板（需求门 0.3 × 0.9 = 0.27 刚好低于 `SAT_DOWN`），调参项。
- `--free-build` 冻结国库（沙盒），若需要"免费但有收入"要给 `SimEconomy.tick` 加旗标。
- 服务器端 `hello_timeout`、`server_full` 两条路径没有自动化测试。

## 不在 M2

技术人员的产生与迁移、军事、轮回继承、大厅与阵营选择、程序化建筑接入（M4）。
