# GameCity 协作规则

Godot 4 双阵营城市建设垂直切片。项目说明在 README.md，锁定设计在 docs/briefs/README.md，当前里程碑在 docs/plans/。

## 角色

- 主会话是集成者：拥有 `shared/`、`docs/`、`CLAUDE.md`、`.claude/`。改合约、合并 worker 分支、跑总冒烟、开 PR。
- worker 是 `.claude/agents/` 里的一个角色，只写自己名下的文件。新角色复制一个现有角色文件改名。

## 文件归属

| 路径 | 归属 |
| --- | --- |
| `shared/**` | 集成者。里程碑内冻结 |
| `docs/**`、`CLAUDE.md`、`.claude/**` | 集成者 |
| `server/net_authority.gd`、`server/world_state.gd`、`server/match_sim.gd`、`server/main.tscn` | match-end |
| `client/presentation.gd`、`client/session.gd`、`client/main.tscn`、`client/` 下新文件 | client-view |
| `tests/**`、`client/smoke_client.*`、`server/permission_check.gd` | smoke-qa |
| `client/assets/techart/roads_interchange/**` | 集成者。M1 样本，只读参考 |
| `client/assets/techart/showcase_max/**`、`client/techart_showcase.tscn`、`client/run_techart_showcase.sh` | techart-showcase |

`server/net_authority.gd` 是热点：时钟、阶段、结束都在这一个文件里。只有 match-end 改它。

## 合约

`shared/` 是服务器和客户端之间唯一的合约。需要改合约时停下，在 hand-back 里给出精确 diff 和理由，等集成者改完再继续。

## Git

worker 在自己的 worktree 分支上提交，提交信息写清楚改了什么。分支名就是交付物，集成者负责合并。`main` 只在负责人志坤批准后合并。

## 验证

Godot 二进制在 PATH 上叫 `godot`。新 worktree 没有 `.godot/` 导入缓存，先导入一次：

```bash
godot --headless --path . --import
```

然后跑 README「无头自检」里的命令，以及 `tests/run_smoke.sh`（存在时）。

## Hand-back 格式

1. 分支名和改动文件列表
2. 跑过的每条命令原文和输出末尾 20 行
3. 没验证的部分和原因
4. 需要的合约变更，没有就写「无」
