# GameCity

双阵营轻对抗城市建设。Godot 4 垂直切片：listen-host 已能收发指令，画面仍是骨架。

Two-faction light-versus city builder. Godot 4 vertical slice: listen-host commands work; the view is still a skeleton.

## 这是什么 / What this is

- 2 个阵营，2–4 名玩家。一局约 30–45 分钟后结算。
- 一局一城：对局数据只在内存里，不把城市存到下一局。
- 服务器权威模拟。垂直切片允许 listen-host，主机跑同一套模拟。
- 地图 64×64 格，兴趣区 8×8，道路只走正交四邻。市政服务只有电，切片不做水。

权威模拟在 `server/world_state.gd`。ENet 会话在 autoload `GameNet`（`server/net_authority.gd`）。客户端只提交意图；拒绝时丢掉乐观操作。

The authoritative sim is `server/world_state.gd`. The ENet session is the `GameNet` autoload (`server/net_authority.gd`). Clients submit intents and drop optimistic edits on Reject.

## 用 Godot 4 打开 / Open in Godot 4

单一工程，就在仓库根目录。`shared/`、`server/`、`client/` 都是这个工程里的目录，不是三份独立的 `project.godot`。

One Godot project at the repo root. `shared/`, `server/`, and `client/` belong to that project. There is not a separate `project.godot` in each folder.

1. 安装 Godot 4.7 或更新版本（工程默认渲染器 Forward+，macOS 走 Metal）。
2. 项目管理器 → Import → 选中本仓库根目录的 `project.godot`。
3. 默认主场景是 `res://client/main.tscn`：正交相机（相对竖直偏约 25°）、一块地面占位、左上角对局状态。
4. 默认 ENet 端口 **24567**（可用 `--port` 覆盖）。主机在大厅等到第二名玩家才 `MatchStart`。主机掉线直接 `MatchEnd`，不迁移主机。

```bash
# 本机 listen-host（带相机）。H 键等价于 --listen，J 键加入 127.0.0.1。
godot --path . -- --listen
godot --path . -- --join 127.0.0.1 --port 24567

# 无头 listen-host（同一套模拟，没有相机）
godot --headless --path . res://server/main.tscn -- --port 24567
```

光标方向键移动。Enter `ClaimTile`，Z `SetZone R`，E 向右加边，P `PlacePower`，Backspace `DemolishOwn`。

出生地是示例坐标，不是锁定玩法：阵营 A 为 `[0,8) × [0,8)`，阵营 B 为 `[56,64) × [56,64)`。

无头自检：

```bash
godot --headless --path . -s res://server/permission_check.gd
godot --headless --path . res://server/main.tscn -- --port 24671 --smoke-host
godot --headless --path . res://client/smoke_client.tscn -- --join 127.0.0.1 --port 24671
```

## 目录 / Layout

| 路径 | 角色 |
| --- | --- |
| `shared/` | 纯数据 GDScript：指令、拒绝码、地块/边增量、兴趣区 id、服务器消息种类。不继承 Node。 |
| `server/` | 权威模拟与对局生命周期入口，可无头运行。 |
| `client/` | 相机、输入、表现入口。 |
| `docs/briefs/` | 垂直切片设计 brief 归档。 |

设计索引：[docs/briefs/README.md](docs/briefs/README.md)

## 道路立交样本 / Roads interchange sample

M1 中等写实包在 `client/assets/techart/roads_interchange/`。`project.godot` 在仓库根，现有资源使用 `res://client/...`，本包前缀同样是 `res://client/assets/techart/roads_interchange/`。

工程默认渲染器自 2026-10-07 起是 Forward+，样本直接打开即可，无头冒烟命令不变：

```bash
godot --path . res://client/techart_sample.tscn
# 或
./client/run_techart_sample.sh
```

`res://client/techart_sample.tscn` 只实例化无 HUD 的 `sample_interchange.tscn`，不替换 `res://client/main.tscn`，也不改 listen-host。势力色和电力色是 overlay 材质，不写进世界 albedo。光照数值见 `client/assets/techart/roads_interchange/docs/LIGHT_PRESETS.md`。

The M1 mid-realism pack lives at `client/assets/techart/roads_interchange/` with `res://` prefix `res://client/assets/techart/roads_interchange/`. Forward+ is the project default since 2026-10-07. Open the HUD-free sample via `res://client/techart_sample.tscn`.

## 不要擅自合并或部署 / Do not merge or deploy

在负责人志坤明确批准之前，不要把本变更合并进 `main`，不要部署，不要导出正式包。

Do not merge to `main`, deploy, or ship an export until 志坤 approves.
