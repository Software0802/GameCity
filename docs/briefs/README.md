# 垂直切片 Brief 索引

本目录归档 GameCity 垂直切片的锁定设计。实现以这些文档为准。仓库已接 listen-host 指令权限；完整模拟公式和美术仍未做。

These files archive the locked vertical-slice design. The repo skeleton does not implement them yet.

| 文件 | 内容 |
| --- | --- |
| [gameplay-vertical-slice.md](gameplay-vertical-slice.md) | 对局框架、玩家意图、服务器规则、胜负 |
| [world-vertical-slice.md](world-vertical-slice.md) | 地图、地块、道路边、权限、指令与模拟 tick |
| [netcode-interface-v0.md](netcode-interface-v0.md) | 服务器权威协议草案 v0 |
| [art-visual-source.md](art-visual-source.md) | 调色板、风格、镜头表 S01–S04 |

## 锁定约束

以下决定已锁定，切片内不再改口径：

- **引擎**：Godot 4。
- **模式**：2 个阵营，轻对抗，2–4 名玩家。
- **持久化**：一局一个对局，内存中的城市，不跨局保留。
- **网络**：服务器权威协议；垂直切片允许 listen-host（主机跑同一套模拟）。
- **世界**：64×64 地块；兴趣区 8×8 地块；道路图只允许正交（四邻），不允许斜向边。
- **市政服务**：只有电力。切片不做供水。

## 非目标

- 不在本归档阶段实现完整模拟、同步或美术资源。
- 不合并、不部署，直到负责人志坤批准。
