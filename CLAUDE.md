# GameCity 协作规则

Godot 4 双阵营持久世界城市建设与对抗。项目说明在 README.md，设计以 docs/briefs/design-v2.md 为准，当前里程碑在 docs/plans/。

## 原则

- **质量优先**（负责人原话）：每条规则都有无头测试；合并的代码里没有占位 TODO；交付前自己跑通全部冒烟。
- 生产变更（部署、停服、改存档）每次都要负责人确认，脚本只准备不自动跑。见 docs/ops/deploy.md。

## 角色

- 主会话是集成者：拥有 `shared/`、`docs/`、`CLAUDE.md`、`.claude/`。改合约、合并 worker 分支、跑总冒烟、开 PR、执行部署。
- worker 是 `.claude/agents/` 里的一个角色，只写自己名下的文件。新角色复制一个现有角色文件改名。

## 文件归属

| 路径 | 归属 |
| --- | --- |
| `shared/**` | 集成者。wave 0 由 contracts worker 一次性修改，之后冻结 |
| `docs/**`、`CLAUDE.md`、`.claude/**` | 集成者 |
| `server/world_state.gd`、`server/sim/**` | sim-economy |
| `server/net_authority.gd`、`server/match_sim.gd`、`server/main.tscn`、`server/persistence.gd`、`server/players.gd` | server-core |
| `client/**`（下面两行除外） | client-play |
| `client/smoke_client.*`、`tests/**`、`server/permission_check.gd`、`server/sim_check.gd`、`deploy/**` | smoke-qa |
| `client/assets/techart/**` | 集成者。showcase 与 M1 包是 M4 的输入，M2 不改 |

`server/world_state.gd` 和 `server/net_authority.gd` 各只有一个主人。跨这两个文件的需求走 docs/plans 里的接缝表，不直接改对方文件。

## 合约

`shared/` 是服务器和客户端之间唯一的合约。需要改合约时停下，在 hand-back 里给出精确 diff 和理由，等集成者改完再继续。

## Git

worker 在自己的 worktree 分支上提交，提交信息写清楚改了什么。分支名就是交付物，集成者负责合并。不推送，不开 PR。`main` 只在负责人志坤批准后合并。

## 验证

Godot 4.7.2 在 `/opt/homebrew/bin/godot`，Bash 里先 `export PATH="/opt/homebrew/bin:$PATH"`。macOS 没有 `timeout`，用 Godot 的 `--quit-after` 或脚本自退。新 worktree 先导入：

```bash
godot --headless --path . --import
```

然后跑 README「无头自检」里的命令和 `tests/run_smoke.sh`（存在时）。

## Hand-back 格式

1. 分支名和改动文件列表
2. 跑过的每条命令原文和输出末尾 20 行
3. 没验证的部分和原因
4. 需要的合约变更，没有就写「无」
