# Netcode interface v0

## v1 变更（2026-10-08）

M2 wave 0 按 [docs/plans/m2-city-phase.md](../plans/m2-city-phase.md)「合约」一节修改了 `shared/`。`SliceConstants.PROTOCOL_VERSION = 1`。下文 v0 正文中与本节冲突的地方以本节为准；没提到的保持不变。

**地图**：`MAP_SIZE` 64 → **128**，`INTEREST_BLOCK` 仍 8，`BLOCKS_PER_AXIS` 派生为 16（256 个兴趣区）。`tile_id = y * MAP_SIZE + x`。出生地由常量派生：A 为 `[0,8)²`，B 为 `[MAP_SIZE-8, MAP_SIZE)²`（`WorldState.SPAWN_A / SPAWN_B`）。

**新增消息**（`ServerEvent.Kind` 末尾追加，现有整型不变）：

| 消息 | 脚本 | 字段 | 路由 |
| --- | --- | --- | --- |
| 客户端 → 服务器 `hello_rpc(dict)` | `client_hello.gd` `ClientHello` | `token`（可空）、`name`（1–24 字符，`ClientHello.is_valid_name`）、`protocol` | 连上后的第一条消息 |
| `WELCOME` | `server_welcome.gd` `ServerWelcome` | `token`、`player_id`、`faction`、`name`、`returning` | 该连接收到的第一条事件；字典键 `welcome` |
| `FACTION_STATE` | `faction_state.gd` `FactionState` | `faction`、`treasury`、`income_per_sec`、`population`、`jobs`、`technicians`（M2 恒 0）、`tax_rate`、`demand_r / demand_c / demand_i`（−1..1）、`power_capacity`、`power_load` | 只发给该阵营的玩家，不是全局事件，也不按兴趣区路由；字典键 `faction_state` |

握手顺序：连接 → `hello_rpc` → `WELCOME` → `MATCH_START` → 兴趣区快照。`WELCOME` 之前的指令一律 `NOT_AUTHENTICATED`。

**新增指令**：`GameCommand.Kind.SET_TAX_RATE`，字段 `rate: float`，工厂 `GameCommand.set_tax_rate(rate)`。阵营级指令，地块与边字段不用。`validate_shape()`：`rate` 不在 `[TAX_RATE_MIN, TAX_RATE_MAX]`（或非有限数）→ `INVALID_RATE`。

**新增原因码**（末尾追加）：`INSUFFICIENT_FUNDS`、`INVALID_RATE`、`NOT_AUTHENTICATED`。

**现有载荷新增字段**：

| 类型 | 新增 |
| --- | --- |
| `TileDelta` | `satisfaction: float`（0–1，按 1/`FIELD_QUANT` 量化）、`pollution: float`（同上）、`brownout: bool`。`power_covered` 仍是"在某电站半径内"；实际有电 = `power_covered and not brownout` |
| `MatchStart` | `round_seconds`、`round_ends_at_unix`、`server_unix`、`pace` |
| `ScoreTick` | 顶层 `seconds_remaining: int`；`FactionScore` 的 `pop / fiscal / control` 现在是归一化 0–1，新增 `pop_raw / fiscal_raw / control_raw` 给 HUD。归一化公式 `ScoreTick.share(own, other)`：每项先 `max(0, 值)`，再 己方 / (己方 + 对方)，双方都为 0 取 0.5。`total` 因此也是 0–1 |
| `MatchEnd` | `final_scores: ScoreTick`（可空，空时写 `{}`）。`reason` 取值 `clock`、`server_stop`；**`host_drop` 改名为 `server_stop`**。常量 `MatchEnd.REASON_CLOCK / REASON_SERVER_STOP` |
| `CrisisEvent` | `kind: String`（M2 为 `grid_storm`，常量 `CrisisEvent.KIND_GRID_STORM`）、`ends_at_unix: int` |
| `PowerAlert` | `brownout: bool` |
| `RegionSummary` | `pollution_avg: float`、`brownout: bool` |

**常量**：`SliceConstants` 新增轮次（`ROUND_SECONDS_DEFAULT / ROUND_SECONDS_TEST / PACE_DEFAULT`）、版本（`SAVE_FORMAT_VERSION / PROTOCOL_VERSION`）、`FIELD_QUANT`、经济 / 成长 / 危机占位数值，`POWER_RADIUS_SUGGESTED` 改名 `POWER_RADIUS`，删除 `MATCH_MINUTES_*`。

**存档**：`WorldState.to_save_dict()` / `WorldState.from_save_dict(d)`（静态工厂，`map_size` 不符返回 `null`）。字典全部 JSON 可序列化，走 `to_dict()` 链，不用 `var_to_bytes`。`JSON.stringify` 默认不是全精度，需要精确浮点时传 `full_precision = true`。

归档说明：协议草案 v0。`shared/` 放纯数据，`server/` 目前只保留对局生命周期入口。本文件描述要接的接口，不是已经实现的联网。

Status: draft interface. Listen-host transport for this slice lives in `server/net_authority.gd` (autoload `GameNet`). Default ENet port **24567**. The rules below stay the contract.

## 权威模型 / Authority

- **专用服务器权威**（dedicated-server-authoritative）。世界只有服务器上的那一份。
- 垂直切片允许 **listen-host**：主机进程跑同一套模拟，不另写一套规则。
- 客户端只提交意图。乐观 UI 可以先画，服务器 `Reject` 时必须回滚。
- 主机掉线：切片内 **对局直接结束**（host drop ends the match）。不做主机迁移。

## 传输 / Transport

- Godot `MultiplayerAPI` + ENet。
- 指令通道：**reliable ordered**。
- 不在 v0 把指令改成不可靠通道。

## shared/ 纯数据 / Shared pure data

`shared/` 里的脚本不继承 Node，供服务器和客户端一起用：

| 脚本 | 类型 | 内容 |
| --- | --- | --- |
| `slice_constants.gd` | `SliceConstants` | 64、8、tick、计分权重、Owner、Zone |
| `commands.gd` | `GameCommand` | 客户端指令及载荷 |
| `reason_codes.gd` | `ReasonCode` | Reject 原因码 |
| `tile_delta.gd` | `TileDelta` | 地块增量（v0 为整格快照） |
| `edge_delta.gd` | `EdgeDelta` | 边增量；`is_orthogonal` |
| `interest.gd` | `InterestId` | 兴趣区 id（块坐标、线性 id、`"bx,by"`） |
| `server_event.gd` | `ServerEvent` | 服务器 → 客户端消息种类与信封 |
| `command_reject.gd` | `CommandReject` | `Reject`：指令引用、kind、`ReasonCode`、可选说明 |
| `interest_update.gd` | `InterestUpdate` | 订阅变更 `add[]` / `remove[]` |
| `region_summary.gd` | `RegionSummary` | 未订阅区域摘要 |
| `match_start.gd` | `MatchStart` | 对局开始载荷 |
| `match_end.gd` | `MatchEnd` | 对局结束载荷（胜者） |
| `score_tick.gd` | `ScoreTick` | 计分快照 |
| `power_alert.gd` | `PowerAlert` | 电力警报 |
| `congestion_alert.gd` | `CongestionAlert` | 拥堵警报 |
| `crisis_event.gd` | `CrisisEvent` | 局中那一次共享危机 |

不要在 `shared/` 里放场景树、RPC 注解实现或 UI。

### Dictionary 往返 / Dictionary round-trip

上表里的载荷提供 `to_dict()` / `from_dict()`，RPC 直接传这些字典。`shared/` 里的脚本不创建 peer。

- 键名与脚本字段一致。`kind`、`reason`、`owner`、`zone`、`winner` 用枚举整型。这些脚本本身不创建 peer；RPC 在 `server/net_authority.gd`。
- 边的端点写成 `{"x": int, "y": int}`。读入时也接受已经是 `Vector2i` 的值。
- `InterestId` 写出 `block_x`、`block_y`、`linear_id`、`key`。读入优先块坐标，否则线性 id，否则 `"bx,by"`。
- `InterestUpdate.add` / `remove` 的元素可以是该字典、线性 id 整数，或 `"bx,by"` 字符串。
- `ServerEvent` 字典带 `kind`，并带一个与种类同名的载荷键（`tile_delta`、`reject`、`interest_update` 等）。
- `EdgeDelta.removed == true` 表示这条边被移除，这是 `RemoveEdge` 在线上的权威结果。`TileDelta` 仍是整格快照。

载荷字段（占位数值不代表已经调参）：

| 类型 | 字段 |
| --- | --- |
| `CommandReject` | `kind`，`command`（完整 `GameCommand`），`reason`，`detail` |
| `InterestUpdate` | `add[]`，`remove[]` |
| `RegionSummary` | `interest`，`population`，`power_alert`，`crisis` |
| `MatchStart` | `map_size`，`interest_block`，`faction_count`（默认即切片常数） |
| `MatchEnd` | `winner`（`Owner`；`NEUTRAL` 表示没有阵营胜者，例如主机掉线），`reason` |
| `ScoreTick` | `tick_index`，`factions[]`（`faction` / `pop` / `fiscal` / `control` / `total`）。`total` 只是锁定权重乘上这三项，不是归一化后的 0–1 分 |
| `PowerAlert` | `x`，`y`，`power_covered`，`shortage`（缺电） |
| `CongestionAlert` | `a`，`b`，`congestion` |
| `CrisisEvent` | `crisis_id`，`active`，`detail`。两边看到同一份 |

`GameCommand.validate_shape()` 只做形状检查，返回 `ReasonCode.Id`：

- 地块或边端点不在 64×64 内 → `OUT_OF_BOUNDS`
- `zone` 不是 R / C / I / none → `INVALID_ZONE`
- 边不满足 `|ax-bx| + |ay-by| == 1` → `NOT_ORTHOGONAL`
- 不认识的 `kind` → `UNKNOWN_COMMAND`
- 形状合法 → `OK`

所有权、相邻占领、边的两端归属由 `server/world_state.gd` 判断。数据层不执行这些规则。

## 客户端 → 服务器 / Commands

可靠有序发送。字段与 [world-vertical-slice.md](world-vertical-slice.md) 一致。

| 指令 | 载荷 | 乐观 UI | 服务器拒绝 |
| --- | --- | --- | --- |
| `ClaimTile` | 地块 x, y | 可先显示占领 | `Reject`，客户端回滚 |
| `SetZone` | 地块 x, y；zone = R / C / I / none | 可先显示分区 | `Reject`，回滚 |
| `AddEdge` | 端点 a, b（地块坐标） | 可先显示边 | `Reject`，回滚 |
| `RemoveEdge` | 端点 a, b | 可先去掉边 | `Reject`，回滚 |
| `DemolishOwn` | 地块 x, y | 可先去掉建筑 | `Reject`，回滚 |
| `PlacePower` | 地块 x, y | 可先显示电力 | `Reject`，回滚 |
| `RemovePower` | 地块 x, y | 可先去掉电力 | `Reject`，回滚 |

除这七个指令外，客户端没有别的写世界入口。

`Reject` 至少带：对应指令、`ReasonCode`、可选说明。原因码表见世界 brief。进行中的对局不再用 `NOT_IMPLEMENTED` 代替权限判断。

## 服务器 → 客户端 / Server messages

| 消息 | 作用 |
| --- | --- |
| `MatchStart` | 对局开始。之后才接受指令 |
| `TileDelta` | 一格的权威结果 |
| `EdgeDelta` | 一条边的权威结果（含移除） |
| `PowerAlert` | 电力警报（缺电 / 覆盖变化的提示，不是第二套电力规则） |
| `CongestionAlert` | 拥堵警报 |
| `CrisisEvent` | 局中那一次共享危机 |
| `ScoreTick` | 计分快照。权重 pop 40% / fiscal 30% / control 30% |
| `MatchEnd` | 对局结束，带胜者 |
| `Reject` | 拒绝一条指令；客户端回滚乐观 UI |
| `InterestUpdate` | 该客户端当前订阅集合的变更 |
| `RegionSummary` | 未订阅区域的摘要，不是逐格权威流 |

生命周期：`MatchStart` → 进行中（play）→ `MatchEnd`。

## 兴趣管理 / Interest

- 区域大小与世界 brief 相同：8×8 地块，id 见 `InterestId`。
- 客户端订阅三类块：**己方**、**边界**、**相机所在**。
- 订阅变化用 `InterestUpdate`。
- 未订阅区域只收 `RegionSummary`，不收逐格 `TileDelta` / `EdgeDelta` 流。
- **重连**发送一份快照（reconnect snapshot），再按当前订阅恢复增量。切片不做断线后的主机迁移；主机掉线仍直接 `MatchEnd`。

## 进程入口

- 客户端场景：`res://client/main.tscn`。`H` 在本机 listen，`J` 加入 `127.0.0.1`。方向键移动光标，Enter 发送 `ClaimTile`。
- 无头 listen-host：`res://server/main.tscn`。默认端口 24567，第二名玩家连上后 `MatchStart`。`notify_host_dropped()` 广播 `MatchEnd`（胜者 `NEUTRAL`，原因 `host_drop`）。
- 加入方：`res://client/main.tscn -- --join 127.0.0.1 --port 24567`。
- listen-host 与无头入口共用 `GameNet` 和 `server/world_state.gd`，不另写一套规则。

## 明确不做（v0 文档范围）

- 不做主机迁移、观战、回放。
- 不把水务同步进协议。
- 不把人口、财政、拥堵公式当成已调参结果。tick 会写占位值。
