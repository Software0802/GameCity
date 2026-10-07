# Gameplay vertical slice

归档说明：这是垂直切片玩法 brief。数字除文中写明的比例和时长范围外，均为占位，尚未调参。代码里的 `shared/slice_constants.gd` 只记下已锁定的常数，不实现规则。

Archive of the gameplay vertical slice. Weights and the match-length range below are locked. Other tuning numbers are placeholders.

## 对局框架 / Match frame

- 两个阵营（faction A、faction B），轻对抗。
- 玩家人数 2–4。
- 一局时长 30–45 分钟，然后结算。
- 一局一城。对局结束即销毁内存状态，没有跨局持久城市。

## 开局 / Start

- 每个阵营拥有一块出生领地（spawn territory）。
- 出生地之外的地块均为未占领（unclaimed / neutral）。
- 出生地尺寸示例见 [world-vertical-slice.md](world-vertical-slice.md)（例如每阵营 8×8）。具体坐标未锁定。

## 客户端只发送意图 / Client intents only

客户端不直接改世界。允许的意图只有下面这些。地块、分区、边、电力的合法性由服务器判定。

| 意图 | 含义 | 作用范围 |
| --- | --- | --- |
| `ClaimTile` | 占领一块中立地块 | 必须与己方地块正交相邻的中立格 |
| `SetZone` | 设置分区 | 仅己方地块。取值为 `R`、`C`、`I` 或 `none` |
| `AddEdge` | 加一条道路边 | 仅正交边，并满足己方所有权规则（见世界 brief） |
| `RemoveEdge` | 拆除一条道路边 | 同上 |
| `DemolishOwn` | 拆除己方建筑 | 仅己方 |
| `PlacePower` | 放置电力 | 仅己方地块。切片只有电力 |
| `RemovePower` | 移除电力 | 仅己方地块 |

不允许的客户端行为：直接改对方的 owner、zone、建筑，或在本地宣布胜负。

## 服务器规则 / Server rules

服务器是唯一裁判。下列规则是切片目标行为；具体公式的系数是占位，验收看“有影响”，不看精确曲线。

### 居住与人口

- `R`（居住）要形成人口，必须同时有路和电。
- 缺路或缺电时，该居住地块不提供人口。

### 需求三角

- `C`（商业）与 `I`（工业）走简化的需求三角：R / C / I 互相构成需求。
- 三角的具体系数是占位，不在本 brief 锁定数值表。

### 拥堵

- 边上有简化拥堵（congestion）。
- 拥堵挂在正交道路边上，不引入斜向边，也不做车辆网格。

### 财政

- 预算 = 税收 − 电力维护费。
- 切片没有水费，也没有水维护。

### 危机

- 每局一次、局中发生的共享危机（one mid-match shared crisis）。
- 两个阵营面对同一事件，不是各自私有副本。

### 计分

对局结算分三项，权重锁定：

| 分项 | 权重 |
| --- | --- |
| 人口 pop | 40% |
| 财政 fiscal | 30% |
| 控制 control | 30% |

各项如何归一到 0–1 仍是占位。权重本身不再改。

## 验收 / Accept

切片玩法可接受的最低现象（人数与公式用占位数字即可）：

1. 两名玩家能看见对方在建造。
2. 占领、分区、道路、电力会影响到拥堵或电力警报中的至少一类反馈。
3. 对局会结束，并给出胜者。

## 明确不做

- 不做持久城市、不做存档读档。
- 不做水务。
- 不做第三阵营。
- 不在客户端上判定规则。
