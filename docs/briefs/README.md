# Brief 索引

**2026-10-08 起以 [design-v2.md](design-v2.md) 为准。** 它取代下面 v1 锁定中与之冲突的条目（持久化、专用服务器、7 天轮次、128×128、军事阶段的交战规则）。v1 文档保留作历史，其中的数据类型继续有效。

Design v2 supersedes the v1 locks below where they conflict. v1 files remain as history and as the source of the shared data types.

| 文件 | 内容 |
| --- | --- |
| [gameplay-vertical-slice.md](gameplay-vertical-slice.md) | 对局框架、玩家意图、服务器规则、胜负 |
| [world-vertical-slice.md](world-vertical-slice.md) | 地图、地块、道路边、权限、指令与模拟 tick |
| [netcode-interface-v0.md](netcode-interface-v0.md) | 服务器权威协议草案 v0 |
| [art-visual-source.md](art-visual-source.md) | 调色板、风格、镜头表 S01–S04 |

## v1 锁定约束（历史）

以下为垂直切片时期的锁定，被 v2 取代的条目以 v2 为准：

- **引擎**：Godot 4。
- **模式**：2 个阵营，轻对抗，2–4 名玩家。
- **持久化**：一局一个对局，内存中的城市，不跨局保留。
- **网络**：服务器权威协议；垂直切片允许 listen-host（主机跑同一套模拟）。
- **世界**：64×64 地块；兴趣区 8×8 地块；道路图只允许正交（四邻），不允许斜向边。
- **市政服务**：只有电力。切片不做供水。
- **画面**（2026-10-07 修订）：程序化中等写实，Forward+ 为工程默认，资产只用 CC0。见 art brief。

## 非目标

- 不在本归档阶段实现完整模拟、同步或美术资源。
- 不合并、不部署，直到负责人志坤批准。
