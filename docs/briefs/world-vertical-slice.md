# World vertical slice

归档说明：地图、权限和模拟 tick 的锁定口径。类型占位在 `shared/`（`TileDelta`、`EdgeDelta`、`InterestId`、`GameCommand`、`ReasonCode`）。本 brief 不授权现在就把模拟写完。

## 地图与持久化 / Map and persistence

- 地图为 **64×64** 地块（tiles）。
- 兴趣区块（interest block）为 **8×8** 地块。全图因此是 8×8 = 64 个兴趣区。
- 出生地示例：每个阵营一块 **8×8**（正好一个兴趣区）。这是例子，不是锁定坐标。
- 出生地以外的 owner 为 **neutral**。
- 整局状态只在内存中。对局结束即丢弃，不写持久城市。

## 地块 / Tile

```
tile {
  id,
  x,
  y,
  owner,          # faction | neutral
  zone,           # R | C | I | none
  hasBuilding,
  buildingTier,   # 0–2
  powerCovered
}
```

- `id` 在一局里稳定标识该格。骨架用 `y * 64 + x`。
- `owner`：某一阵营，或 neutral。
- `zone`：`R`、`C`、`I`，或 `none`。
- `hasBuilding`：该格是否有建筑。
- `buildingTier`：整数 0–2，对应后续 2–3 档高度 LOD 的数据，不是美术网格。
- `powerCovered`：当前是否被电力覆盖。由模拟 tick 写，不由客户端写。

## 边 / Edge

```
edge {
  a,
  b,
  capacity,
  congestion
}
```

- 只允许 **正交四邻**。`a` 与 `b` 必须是上下左右相邻的两格。
- 禁止斜向边。道路图是正交图，不是八向图。
- `capacity`：该边容量。数值占位。
- `congestion`：简化拥堵。数值占位，由模拟 tick 更新。

正交判定：`|ax-bx| + |ay-by| == 1`。

## 权限 / Permissions

服务器执行，客户端不得绕过。

| 动作 | 允许条件 |
| --- | --- |
| 占领中立格 | 目标 owner 为 neutral，且与己方已占领格正交相邻 |
| 分区、拆除、放置/移除电力 | 仅己方 owner 的地块 |
| 加边 / 拆边 | 正交，并且满足己方所有权规则：边的两端都必须是己方地块。不得把边接到对方地块上，也不得改对方地上的边 |
| 对方数据 | **永远不**改对方的 owner、zone、建筑 |

失败时不改状态，返回 Reject 与原因码（见下）。

## 指令 → 增量或拒绝 / Commands

客户端指令（与玩法 brief 同一张表）：

| 指令 | 成功时 | 失败时 |
| --- | --- | --- |
| `ClaimTile` | `TileDelta`（owner 变为该阵营） | `Reject` |
| `SetZone` | `TileDelta`（zone 为 R / C / I / none） | `Reject` |
| `AddEdge` | `EdgeDelta` | `Reject` |
| `RemoveEdge` | `EdgeDelta`（边上移除） | `Reject` |
| `PlacePower` | `TileDelta` 或随后 tick 产生的覆盖变化；放置本身只发生在己方格 | `Reject` |
| `RemovePower` | 同上 | `Reject` |
| `DemolishOwn` | `TileDelta`（清己方建筑） | `Reject` |

原因码（枚举仍在 `shared/reason_codes.gd`。进行中的对局由 `server/world_state.gd` 判断，不再回 `NOT_IMPLEMENTED`）：

| 码 | 何时 |
| --- | --- |
| `OK` | 已接受 |
| `NOT_IMPLEMENTED` | 枚举保留。进行中的对局不再用它代替权限判断 |
| `UNKNOWN_COMMAND` | 不认识的指令 |
| `MATCH_NOT_ACTIVE` | 不在对局进行中 |
| `OUT_OF_BOUNDS` | 坐标超出 64×64 |
| `NOT_NEUTRAL` | 占领目标不是中立 |
| `NOT_ADJACENT` | 占领格不与己方正交相邻 |
| `NOT_OWNER` | 分区 / 拆除 / 电力不在己方格 |
| `OPPONENT_IMMUTABLE` | 试图改对方 owner、zone 或建筑 |
| `INVALID_ZONE` | zone 不是 R / C / I / none |
| `NOT_ORTHOGONAL` | 边不是四邻 |
| `EDGE_RULE` | 边不满足己方两端所有权 |

## 模拟 tick / Sim tick

- 步长约 **1 秒**。
- 每个 tick 更新：`powerCovered`、人口、边上的 `congestion`。
- 人口与拥堵的公式是占位；tick 的存在和这三项输出不是占位。
- **电力覆盖半径建议为 4**（地块）。这是建议值，尚未调参。
- 切片不模拟水，tick 不产水覆盖。

## 与兴趣区的关系

世界状态按地块和边存储。网络层按 8×8 兴趣区订阅，见 [netcode-interface-v0.md](netcode-interface-v0.md)。兴趣区 id 不替代 tile id。

## 明确不做

- 不持久化地图。
- 不做水网、水塔、水管。
- 不做斜向道路。
- 不在本阶段写完整 tick 公式。
