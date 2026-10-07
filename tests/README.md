# tests/ — 无头端到端冒烟

`tests/run_smoke.sh` 一条命令跑完 M2A / M2B 的验收路径（docs/briefs/design-v2.md 里程碑表）。任一步失败非零退出并打印相关日志尾部；每步有编号与耗时；端口随机高位；工作目录 `mktemp -d`；退出时清理所有 godot 进程（trap），失败时保留工作目录供排查。

```bash
export PATH="/opt/homebrew/bin:$PATH"
tests/run_smoke.sh                 # 全部步骤
tests/run_smoke.sh --skip-import   # 复跑时跳过 --import
SMOKE_ROUND_SECONDS=90 tests/run_smoke.sh   # 轮次更长（步骤 4–6 共用一局）
```

环境变量：`GODOT`（默认 PATH 上的 godot）、`SMOKE_ROUND_SECONDS`（默认 60）、`SMOKE_PACE`（默认 0.01）、`SMOKE_START_TREASURY`（默认 60）、`SMOKE_REQUIRE_ECONOMY=1`（步骤 7 的 SKIP 视为 FAIL，M2B 合入后用它收紧门禁）、`SMOKE_KEEP=1`（全绿也保留工作目录）。

步骤 1–3 是门禁：失败即停。步骤 4–7 各自独立判定并继续，这样一次运行就能把每个尚未合入的服务器特性都点名。

## 步骤、断言、依赖

| 步 | 跑什么 | 断言 | 依赖谁的交付 |
| --- | --- | --- | --- |
| 1 | `godot --headless --path . --import` | 退出码 0，输出无 `SCRIPT ERROR` | — |
| 2a | `-s res://server/shared_roundtrip_check.gd` | 退出码 0 且有 `SHARED_OK` | contracts（wave 0，已合） |
| 2b | `-s res://server/permission_check.gd` | 退出码 0 且有 `PERMISSION_OK` | contracts；sim-economy 改 `world_state.gd` 后仍须绿 |
| 2c | `-s res://server/save_roundtrip_check.gd` | 退出码 0 且有 `SAVE_OK`（输出里本来就有一行预期的 `ERROR:`，只看退出码） | contracts；sim-economy 扩展存档后仍须绿 |
| 2d | `-s res://server/sim_check.gd`，文件存在时才跑 | 退出码 0 且有 `SIM_OK` | **sim-economy**（文件不存在则 SKIP） |
| 2e | `res://client/main.tscn --quit-after 5`、`res://client/smoke_client.tscn --quit-after 5` | 无 `SCRIPT ERROR` / `Parse Error`，退出码 0。`--check-only -s` 不加载 autoload，查不了引用 `GameNet` 的脚本，所以用这个办法 | client-play 的 `client/**` 改动 |
| 3 | 无头 host `--smoke-host` + `smoke_client.tscn --join --expect server_stop`（旧路径，默认 `--scenario legacy`） | 客户端 `SMOKE_OK`；host 日志有 `MatchEnd: server_stop`。断言内容与 wave 0 相同：(0,0) zone R、host 边 (0,0)-(1,0)、B 占 `SPAWN_B+(-1,0)` 并 zone C、两条 `OPPONENT_IMMUTABLE` 拒绝、`winner=NEUTRAL`、pending 归零、(0,0) 回滚为 A | **server-core** 在拆掉 listen-host 后仍要保留 `--smoke-host` 语义：A 侧的 zone R / 加边 / 占 (8,0) 和远端指令达阈值后的 `MatchEnd{server_stop}` |
| 4 | 服务器 `--port <p> --pace 0.01 --round-seconds 60 --free-build --save-dir <tmp>/save --status-file <tmp>/status.json`；A（`--name Alice --scenario idle --hold-seconds 45`）先进并保持在线；B（`--name Bob --scenario b`）进来建格后退出；B 用同一 `--identity-file` 重连 | 两个客户端都打印 `WELCOME`；阵营不同；两个身份文件都有非空 `token=` 且不同；B 首次 `returning=false`，看到 `TILE <out> owner=<B>`；重连 `returning=true`、阵营不变、token 不变、仍看到该 TILE，且 `BUILD sent=0`（什么都不用重建） | **server-core**：`hello_rpc` / `WELCOME`、玩家表、断线不删玩家 |
| 5 | 读 `status.json` 的 `tick` / `round_ends_at_unix` / `pid`；SIGTERM 服务器，等它退出（≤10 s）；`--save-dir` 下有存档；同参数重启；等新 `status.json`（mtime 晚于重启、pid 变化）；B 重连 | `tick` 不归零（after ≥ before 且 > 0）；`round_ends_at_unix` 前后相同（停机不延长轮次）；剩余时间 ≥ 15 s；B `returning=true`、阵营不变、`TILE <out> owner=<B>`、`BUILD sent=0` | **server-core**：`--save-dir`、`--status-file`、SIGTERM 时先存后退、启动恢复 |
| 6 | 同一服务器继续；A（idle）、B（b）都带 `--expect clock --round-seconds 60` 重连，等 `MatchEnd` | 两个客户端 `SMOKE_OK`；`MATCH_END reason=clock final_scores=true`；`winner` 非 NEUTRAL 且等于 B 的阵营（只有 B 建了有路有电的 R 格）；A、B 看到同一个 winner。客户端 `DEADLINE` = `--round-seconds` + 15 s，收到 `MATCH_START` 后收紧到 `round_ends_at_unix` + 15 s；`round_ends_at_unix=0` 或超出预期立即失败 | **server-core**：`--round-seconds`、墙钟轮次、`MatchEnd{clock, final_scores}`；分数由 `WorldState.score()`（sim-economy 合入前是 wave 0 的 `_score`） |
| 7 | 新服务器，不加 `--free-build`，`--start-treasury 60`；A idle 保持在线；B `--scenario broke` 连发两次占领 | 第二次占领收到 `REJECT ... name=INSUFFICIENT_FUNDS tile=<out2>`，该格仍中立，客户端打印 `BROKE_OK`。若第一次也被拒（成本公式把出生地 64 格算进去时 50×1.64 = 82 > 60），打印 `BROKE_DIAG` 仍算通过，可调 `SMOKE_START_TREASURY` | **server-core** 提供 `--start-treasury`（`server/` 下 grep 不到就 SKIP 并写明）；**sim-economy** 的扣费与 `INSUFFICIENT_FUNDS`（`server/world_state.gd`、`server/sim/` 都 grep 不到就 SKIP） |

步骤 4、5、6 共用一台服务器与同一个 `--save-dir`：第 5 步的重启和第 6 步的时钟都是对第 4 步建出来的状态做的，顺带验证"服务器停机不延长轮次"。4–5 通常 15–25 s，60 s 轮次留有余量；若剩余不足 15 s 第 5 步会明确报"用光了轮次预算，调大 `SMOKE_ROUND_SECONDS`"。

## 基线（85c3a93）上的预期结果

| 步 | 结果 | 失败信息里点名的缺项 |
| --- | --- | --- |
| 1、2a–2c、2e、3 | PASS | — |
| 2d | SKIP | `server/sim_check.gd` 不存在（sim-economy） |
| 4 | FAIL | `NO_HELLO_RPC` → 缺 `GameNet.hello_rpc` / `WELCOME`（server-core）；`server/ has no: hello_rpc` |
| 5 | FAIL | 没有 `status.json` → 缺 `--status-file` / `--save-dir`（server-core） |
| 6 | FAIL | `MATCH_START round_ends_at_unix=0` → 缺 `--round-seconds`（server-core） |
| 7 | SKIP | `server/` 下没有 `--start-treasury`（server-core），sim-economy 的 `INSUFFICIENT_FUNDS` 未验证 |

合入后预期转绿顺序：**server-core** → 4、5、6（身份文件由 `smoke_client.gd` 内置的最小 `Identity` 类读写，不等 client-play）；**sim-economy**（加上 server-core 的 `--start-treasury`）→ 2d、7。client-play 合入后把 `smoke_client.gd` 的 `Identity` 换成 `ClientIdentity`，并靠 2e 检查它的脚本没有解析错误。

## smoke_client.gd

```
godot --headless --path . res://client/smoke_client.tscn -- --join <host> --port <p> \
    [--scenario legacy|idle|a|b|broke] [--expect server_stop|clock|none] \
    [--name <1-24 字符>] [--identity-file <path>] [--hold-seconds <n>] [--round-seconds <n>]
```

- 场景的坐标全部由服务器 **分配的阵营** 派生（WELCOME 的 `faction`，wave 0 服务器用 `faction_assigned`），不是由 `--name` 决定。`b` 建的格是己方出生角外侧那一格（A 为 (8,0)，B 为 (MAP_SIZE−9, MAP_SIZE−8)），路连到角格，电站放在角格。重连时若快照里这一格已经是 R、有电、有路，则一条指令也不发（`BUILD sent=0`）。
- 连上后 `GameNet.has_method("hello_rpc")` 为真才 `rpc_id(1, "hello_rpc", ClientHello.to_dict())`；否则打印 `NO_HELLO_RPC`：`legacy` 按旧路径继续，其他场景立即失败并写明缺 `hello_rpc`（`--expect clock` 时先等 `MATCH_START` 检查时钟，这样同时缺两样的服务器会先被点名时钟）。
- 身份文件：`--identity-file` 指定路径，默认 `user://identity.cfg`；ConfigFile，段 `[identity]`，键 `token`、`name`。收到 WELCOME 立刻写入。
- 每条消息一行机器可读输出：`WELCOME player_id= faction= returning= name=`、`MATCH_START round_seconds= round_ends_at_unix= server_unix= pace=`、`FACTION_STATE ...`（内容变化时才打）、`TILE x,y owner= zone= building= tier= power= brownout=`（只打关注的格）、`EDGE`、`REJECT kind= reason= name= tile=`、`MATCH_END reason= winner= final_scores= seconds_remaining=`、`FINAL_SCORE ...`、最后 `SMOKE_OK` 或 `SMOKE_FAIL <原因>`。

## 手动复现单步

```bash
PORT=$((20000 + RANDOM % 20000)); T=$(mktemp -d)
godot --headless --path . res://server/main.tscn -- --port $PORT --pace 0.01 --round-seconds 60 --free-build --save-dir $T/save --status-file $T/status.json &
godot --headless --path . res://client/smoke_client.tscn -- --join 127.0.0.1 --port $PORT --name Alice --identity-file $T/a.cfg --scenario idle --hold-seconds 30 &
godot --headless --path . res://client/smoke_client.tscn -- --join 127.0.0.1 --port $PORT --name Bob --identity-file $T/b.cfg --scenario b --hold-seconds 2
kill %1 %2
```
