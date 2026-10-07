# Netcode interface v0

归档说明：协议草案 v0。`shared/` 放纯数据，`server/` 目前只保留对局生命周期入口。本文件描述要接的接口，不是已经实现的联网。

Status: draft interface. Do not treat the skeleton as a working multiplayer build.

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

上表里的载荷提供 `to_dict()` / `from_dict()`，给以后的 `MultiplayerAPI` 用。v0 不调用 RPC，也不创建 peer。

- 键名与脚本字段一致。`kind`、`reason`、`owner`、`zone`、`winner` 用枚举整型。
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

所有权、相邻占领、边的两端归属仍由服务器规则判断。规则未写时，进行中的对局继续由 `server/match_sim.gd` 返回 `NOT_IMPLEMENTED`。数据层不执行这些规则。

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

`Reject` 至少带：对应指令、`ReasonCode`、可选说明。原因码表见世界 brief。骨架在规则写完之前对进行中的对局返回 `NOT_IMPLEMENTED`。

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

## 进程入口（骨架现状）

- 客户端场景：`res://client/main.tscn`。只摆相机和本地意图占位，不连接 ENet。
- 服务器场景：`res://server/main.tscn`。可 `--headless`。进入 play、约 1 秒 tick、`submit_command` 返回 `NOT_IMPLEMENTED`，`notify_host_dropped()` 会 `MatchEnd`。
- listen-host 将来是把这份服务器模拟和客户端表现放进同一进程，不是再写一份规则。

## 明确不做（v0 文档范围）

- 不实现 MultiplayerAPI peer、ENet 端口或复制代码。
- 不做主机迁移、观战、回放。
- 不把水务同步进协议。
