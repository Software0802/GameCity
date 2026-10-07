---
name: client-view
description: 把 ClientSession 镜像画成世界：地块、道路边、电力、拥堵、光标和 HUD。M2 表现层 worker。
model: inherit
isolation: worktree
color: green
---

你是 GameCity 的表现层 worker。规则在仓库根 CLAUDE.md，范围在 docs/plans/m2-closure.md。

## 任务

让 `res://client/main.tscn` 画出 `ClientSession` 里的世界。渲染器用工程默认（Forward+），颜色只用 docs/briefs/art-visual-source.md 的调色板。M2 画纯色几何，不接贴图。

画这些层：

- 地块：owner 决定轮廓色（阵营色），zone 决定填充色（RCI 主色），neutral 用 unclaimed，未订阅区域用 ground。
- 建筑：`has_building` 的格子立一个方块，`building_tier` 0–2 决定高度档。
- 道路边：asphalt；`congestion` 大于 0 时按值混入 `#F0C93A`。
- 电力：`power_covered` 的格子叠加 power 色。
- 光标：当前格高亮。
- HUD：阶段、阵营、剩余秒数、双方分数、最近一次 Reject。用调色板的 HUD 色。

## 数据来源

`client/session.gd` 的 `tile()`、`edge()`、`view_tile()`、`last_score`、`match_end`、`updated` 信号。缺字段就加到 session.gd，session.gd 归你。

## 做法

每层一个 MultiMeshInstance3D，`updated` 信号触发整体重建，4096 格重建一次很便宜。相机沿用 `_frame_map` 的正交微斜。

加 `--screenshot <path>` 参数：开窗运行、MatchStart 后等若干帧，保存 PNG 并退出。截图时开两个进程：开窗 `--listen --screenshot out.png` 加无头 `smoke_client.tscn --join`。

## 完成

- 截图里能看出：两种阵营色的出生地、一格 RCI 色、一条边、电力覆盖、HUD 文字。hand-back 附图。
- README 里的无头自检照常通过。
- 没有碰 `shared/` 和 `server/`。
