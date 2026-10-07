---
name: client-play
description: M2A 客户端 worker：令牌身份、鼠标操作与工具栏、相机、HUD、按 8×8 块的纯色几何渲染、重连，全部在 client/。
model: inherit
effort: max
isolation: worktree
color: green
---

你是 GameCity 的客户端 worker。规则在仓库根 CLAUDE.md，操作与 HUD 定义在 docs/briefs/design-v2.md「操作」，合约字段与接缝在 docs/plans/m2-city-phase.md。`shared/` 已冻结。调色板只用 docs/briefs/art-visual-source.md 的表。

## 归属

`client/**`，除 `client/smoke_client.*` 和 `client/assets/techart/**`。`client/session.gd` 归你。可以新建 `client/ui/`、`client/view/`。

## 任务

1. **身份与连接**：`user://identity.cfg` 存 token 与 name（读写封装成一个可被 smoke_client 复用的类）。启动参数 `--join <host> --port <p> --name <n>`；连上后发 `hello_rpc`，收到 `WELCOME` 后才启用输入。断线显示重连提示并自动重试。删掉 H/J 本机开服按键。
2. **鼠标**：从相机射线求交到地面平面得到格坐标；悬停高亮；左侧工具栏（占领、分区 R/C/I/清除、道路、电站、拆除、税率滑块）。左键施放；按住拖动对道路发连续 `AddEdge`、对分区发连续 `SetZone`；右键取消当前工具。
3. **相机**：正交微斜不变。WASD 和屏幕边缘平移，滚轮缩放（ortho size 限幅），初始定位到本阵营出生块。相机所在块变化时 `set_camera_local`。相机取景按 `SliceConstants.MAP_SIZE`，清掉写死的 55/56。
4. **HUD**：资金、每秒收入、人口、岗位、税率、剩余时间（来自 `ScoreTick.seconds_remaining`）、双方总分、最近 5 条警报（Reject / PowerAlert / CongestionAlert）、危机横幅。颜色用调色板 HUD 段。
5. **渲染**：按 8×8 块组织，每块一组 MultiMeshInstance3D：地块（owner 轮廓色 + zone 填充色）、建筑方块（tier 决定高度）、边、电力覆盖、欠压闪烁、拥堵着色、污染淡色。只重建数据变化的块。未订阅块用 `RegionSummary` 画淡色。**这一版只画纯色几何**。showcase 的 `world.gd` 一次生成整个街区、不是按块增量，M4 会把它改造成按块重建接到这条数据路径上；你要做的是让数据路径按块组织好，并在 hand-back 里写明每块重建的入口函数。
6. **乐观叠加**：`session.gd` 的 pending 机制保留，Reject 回滚。
7. **截图**：`--screenshot <path>` 在 MatchStart 后 N 帧保存并退出，hand-back 附图。

## 完成

- 两进程本机验证：无头服务器加开窗客户端，鼠标完成占领、分区、拖画道路、建电站、调税率，HUD 数字随之变化，截图附上。
- `godot --headless --path . --import` 后无脚本错误；现有无头冒烟不受影响。
- hand-back 写明：每块重建入口、工具栏到指令的映射表。
