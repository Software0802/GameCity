# GameCity

双阵营轻对抗城市建设。Godot 4 垂直切片骨架（还不能玩）。

Two-faction light-versus city builder. Godot 4 vertical-slice skeleton (not playable yet).

## 这是什么 / What this is

- 2 个阵营，2–4 名玩家。一局约 30–45 分钟后结算。
- 一局一城：对局数据只在内存里，不把城市存到下一局。
- 服务器权威模拟。垂直切片允许 listen-host，主机跑同一套模拟。
- 地图 64×64 格，兴趣区 8×8，道路只走正交四邻。市政服务只有电，切片不做水。

当前仓库只有工程骨架和已归档的设计 brief。没有完整玩法、联网实现或美术资源。

This repository is a project skeleton plus archived design briefs. Full gameplay, netcode, and art assets are not in tree.

## 用 Godot 4 打开 / Open in Godot 4

单一工程，就在仓库根目录。`shared/`、`server/`、`client/` 都是这个工程里的目录，不是三份独立的 `project.godot`。

One Godot project at the repo root. `shared/`, `server/`, and `client/` belong to that project. There is not a separate `project.godot` in each folder.

1. 安装 Godot 4.3 或更新版本（本工程标记为 GL Compatibility）。
2. 项目管理器 → Import → 选中本仓库根目录的 `project.godot`。
3. 默认主场景是 `res://client/main.tscn`：正交相机（相对竖直偏约 25°）、一块地面占位、左上角文字 “GameCity skeleton”。
4. 无头服务器入口（只会打印 `MatchStart`，规则尚未实现）：

```bash
godot --headless --path . res://server/main.tscn
```

## 目录 / Layout

| 路径 | 角色 |
| --- | --- |
| `shared/` | 纯数据 GDScript：指令、拒绝码、地块/边增量、兴趣区 id、服务器消息种类。不继承 Node。 |
| `server/` | 权威模拟与对局生命周期入口，可无头运行。 |
| `client/` | 相机、输入、表现入口。 |
| `docs/briefs/` | 垂直切片设计 brief 归档。 |

设计索引：[docs/briefs/README.md](docs/briefs/README.md)

## 不要擅自合并或部署 / Do not merge or deploy

在负责人志坤明确批准之前，不要把本变更合并进 `main`，不要部署，不要导出正式包。

Do not merge to `main`, deploy, or ship an export until 志坤 approves.
