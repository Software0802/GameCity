# GameCity

双阵营轻对抗城市建设。Godot 4 垂直切片：listen-host 已能收发指令，画面仍是骨架。

Two-faction light-versus city builder. Godot 4 vertical slice: listen-host commands work; the view is still a skeleton.

## 这是什么 / What this is

- 2 个阵营，2–4 名玩家。一局约 30–45 分钟后结算。
- 一局一城：对局数据只在内存里，不把城市存到下一局。
- 服务器权威模拟。垂直切片允许 listen-host，主机跑同一套模拟。
- 地图 128×128 格（`SliceConstants.MAP_SIZE`），兴趣区 8×8，道路只走正交四邻。市政服务只有电，切片不做水。

权威模拟在 `server/world_state.gd`。ENet 会话在 autoload `GameNet`（`server/net_authority.gd`）。客户端只提交意图；拒绝时丢掉乐观操作。

The authoritative sim is `server/world_state.gd`. The ENet session is the `GameNet` autoload (`server/net_authority.gd`). Clients submit intents and drop optimistic edits on Reject.

## 用 Godot 4 打开 / Open in Godot 4

单一工程，就在仓库根目录。`shared/`、`server/`、`client/` 都是这个工程里的目录，不是三份独立的 `project.godot`。

One Godot project at the repo root. `shared/`, `server/`, and `client/` belong to that project. There is not a separate `project.godot` in each folder.

1. 安装 Godot 4.7 或更新版本（工程默认渲染器 Forward+，macOS 走 Metal）。
2. 项目管理器 → Import → 选中本仓库根目录的 `project.godot`。
3. 默认主场景是 `res://client/main.tscn`：正交相机（相对竖直偏约 25°）、一块地面占位、左上角对局状态。
4. 默认 ENet 端口 **24567**（可用 `--port` 覆盖）。服务器是专用无头进程 `res://server/main.tscn`，启动即开始（或从存档恢复）一轮；客户端连上后先发 `hello_rpc`，收到 `WELCOME` 才算玩家，之前的指令一律 `NOT_AUTHENTICATED`。服务器停机不结束轮次，重启后从存档继续，`round_ends_at_unix` 不变。

```bash
# 专用无头服务器（唯一的服务器入口；参数见下表）
godot --headless --path . res://server/main.tscn -- --port 24567 --save-dir user://saves

# 客户端加入。listen-host（H 键 / --listen）已删除，GameNet.host() 只剩返回 ERR_UNAVAILABLE 的桩。
godot --path . -- --join 127.0.0.1 --port 24567 --name alice
```

专用服务器参数（`--` 之后，全部可选）：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `--port <int>` | 24567 | ENet UDP 端口 |
| `--save-dir <path>` | `user://saves`（macOS 即 `~/Library/Application Support/Godot/app_userdata/GameCity/saves`） | 存档目录。接受 `user://`、绝对路径、相对当前工作目录的路径 |
| `--save-interval <sec>` | 30 | 定时存档间隔。启动、轮次结束、关停时另各存一次 |
| `--round-seconds <int>` | `SliceConstants.ROUND_SECONDS_DEFAULT`（604800） | **新一轮**的长度。恢复存档时忽略，结束时间不变 |
| `--pace <float>` | 1.0 | 写入 `WorldState.pace` 与 `MatchStart.pace`。显式传入时覆盖存档里的 pace，否则沿用存档 |
| `--status-file <path>` | 不写 | 每秒原子写 `{tick, players, players_known, round_ends_at_unix, saved_at_unix, pid, phase}` |
| `--stop-file <path>` | `<save-dir>/stop` | 文件出现即存档、删除该文件并以 0 退出。headless Godot 4.7.2 没有信号钩子（SIGTERM 直接杀进程、不触发任何通知），这是唯一的优雅停机入口，定时存档是保底。`--stop-file ""` 关闭 |
| `--start-treasury <int>` | 不设（沿用 `SliceConstants.START_TREASURY`） | **新一轮**（首次启动或 `--new-round`）时对两个阵营调用 `WorldState.set_treasury_all(float(amount))`；恢复存档时不应用。sim-economy 合入前该方法不存在，调用静默跳过并打印一行日志 |
| `--free-build` | 关 | 沙盒：不扣建造费和维护费，国库冻结（也没有收入） |
| `--new-round` | 关 | 把旧存档移到 `<save-dir>/backup-<时间戳>/`，用 `WorldState.new()` 开新一轮 |
| `--smoke-host` | 关 | 旧两进程冒烟：预种阵营 A 的脚本玩家 `smoke-host` 并执行原 host 的三条指令（`(0,0)` 分区 R、边 `(0,0)-(1,0)`、占领 `(8,0)`），第一个连入者因此分到 B；收到 5 条远端指令后广播 `MatchEnd{server_stop}`，1 秒后退出。不传 `--save-dir` 时不落盘 |

存档是 `<save-dir>/world-<UTC 时间戳>.json`，先写 `.tmp` 再改名，只保留最近 3 份，启动时取最新能完整解析的一份。信封形状见 docs/plans/m2-city-phase.md「存档信封」，玩家表在信封的 `players` 里（没有单独的 `players.json`）；`round.tick` 是信封之外唯一的新增键，用来让 `status.json` 的 tick 重启后继续。

光标方向键移动。Enter `ClaimTile`，Z `SetZone R`，E 向右加边，P `PlacePower`，Backspace `DemolishOwn`。

出生地是示例坐标，不是锁定玩法，全部由 `MAP_SIZE` 派生（`WorldState.SPAWN_A / SPAWN_B`）：阵营 A 为 `[0,8) × [0,8)`，阵营 B 为 `[MAP_SIZE-8, MAP_SIZE) × [MAP_SIZE-8, MAP_SIZE)`，128 地图上即 `[120,128)²`。

无头自检（每条都以 `*_OK` 收尾并以 0 退出；失败打印差异并非零退出。注意 `-s` 脚本本身解析失败时 Godot 仍以 0 退出，所以要同时看 `*_OK` 标记）：

```bash
# 合约：shared/ 每个载荷 to_dict → JSON → from_dict 往返、枚举整型、SET_TAX_RATE 边界 → SHARED_OK
godot --headless --path . -s res://server/shared_roundtrip_check.gd
# 权限与解析 → PERMISSION_OK
godot --headless --path . -s res://server/permission_check.gd
# 存档：建世界、下指令、跑 tick，to_save_dict → JSON → from_save_dict 逐格逐边逐电站比较 → SAVE_OK
#（输出含一行预期的 ERROR，以退出码为准）
godot --headless --path . -s res://server/save_roundtrip_check.gd
# 模拟规则（pace 0.01）：没钱被拒、有路有电升档、缺路缺电不升、电站超载欠压、污染跨界、危机减容、
# 税率边界、存档后计时器继续、FactionState 收入与手算一致 → SIM_OK，并打印 100 tick 的 SIM_PERF
godot --headless --path . -s res://server/sim_check.gd
# 玩家表与存档信封：阵营平衡、token 哈希查找、信封 → JSON → 恢复逐字段比较、只留 3 份、
# 跳过损坏的最新文件、拒绝不同版本、--new-round 备份 → PERSIST_OK（输出含预期的 WARNING/ERROR 行）
godot --headless --path . -s res://server/persistence_check.gd
# 两进程冒烟：先起 host（后台），再起 smoke client → SMOKE_OK，host 日志出现 MatchEnd: server_stop，
# host 随后自行退出（不传 --save-dir，不落盘）
godot --headless --path . res://server/main.tscn -- --port 24671 --smoke-host
godot --headless --path . res://client/smoke_client.tscn -- --join 127.0.0.1 --port 24671
# 服务器端到端（约 2 分钟）：两个客户端握手拿到不同阵营与 token、token 重连阵营不变且地块仍在、
# SIGKILL 与 stop 文件两种重启后 tick 继续且玩家表还在、--round-seconds 20 约 20 秒后 MatchEnd: clock
# 且结束后指令回 MATCH_NOT_ACTIVE、hello 前的指令回 NOT_AUTHENTICATED、错误协议被拒、旧 smoke → SERVER_CORE_OK
./server/server_core_check.sh
```

`server/check_client.tscn` 是上面脚本用的无头检查客户端（直接连 `GameNet`，不经过 `client/session.gd`），参数见 `server/check_client.gd` 头部注释。

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
