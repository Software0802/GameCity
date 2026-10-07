# 部署约定（阿里云 ECS）

沿用负责人在 VideoPlatform 上已验证的部署方式。主机地址不写进本仓库，由负责人提供；同一台机器上已经跑着另一个服务，**不得触碰 `/opt/genius` 及其 systemd 单元**。

## 布局

```
/opt/gamecity/
  godot                     # 官方 Linux 二进制（按 uname -m 选 x86_64 或 arm64），与本地同版本 4.7.2
  releases/<sha>-<ts>/      # 每次发布一份，保留 3 份
  current -> releases/...   # 原子切换（mv -T）
  data/                     # 存档目录：world-*.json 快照、players.json、status.json
  backups/                  # backup.sh 产物，保留 14 份，权限 600
  .env                      # 端口、pace、round-seconds 等，640
```

- 专用系统账号 `gamecity`，整树归 `gamecity:gamecity`。
- systemd `gamecity.service`：`ExecStart=/opt/gamecity/godot --headless --path /opt/gamecity/current res://server/main.tscn -- --port 24567 --save-dir /opt/gamecity/data --status-file /opt/gamecity/data/status.json`，`Restart=on-failure`，`MemoryMax` 先设 400 MiB，上线后按实测调。
- ENet 走 **UDP 24567**，安全组要放行 UDP，不是 TCP。

## 健康检查

服务器每秒把 `{tick, players, round_ends_at_unix, saved_at_unix, pid}` 写到 `status.json`。健康 = 文件 mtime 距今 ≤ 5 秒且 `tick` 在增长。部署脚本轮询这个文件，不健康就回滚到上一个 release 并重启。

## 发布流程（`deploy/deploy.sh`）

1. 本地门禁：`permission_check`、`sim_check`、`tests/run_smoke.sh` 全绿，否则不打包。
2. `git archive HEAD` 打包，默认排除 `client/assets/techart`（无头服务器用不到，包从 119 MB 降到约 100 KB；`GAMECITY_ARCHIVE_EXCLUDE=""` 可恢复完整打包），记录 `BUILD_INFO.json`（sha、时间、脏标记）。
3. 上传到 `releases/<sha>-<ts>/`，解包后在主机跑一次 `godot --headless --import` 生成 `.godot/` 类缓存（不跑则 `shared/` 的 class_name 解析不到，启动报几十条 SCRIPT ERROR），再 `mv -T` 切 `current`，`systemctl restart gamecity`。
4. 轮询 `status.json` 健康；失败则切回上一个 release 再重启，脚本以非零退出说明"已回滚"还是"回滚也失败"。
5. 修剪到 3 个 release。

存档在 `data/`，发布不碰它。存档格式版本号在 `SliceConstants.SAVE_FORMAT_VERSION`，升版本时服务器启动要能读旧版。

## 备份

`deploy/backup.sh` 每日 03:47（避开同机另一个服务的 03:17）打包 `data/` 到 `backups/`，保留 14 份。恢复演练：解包到临时目录，用 `--save-dir` 指向它启动一个本地服务器，确认 `status.json` 的 tick 从存档继续。

## 规则

- 每一次生产变更（首次部署、重新发布、停服、改存档）都要负责人明确确认后再执行。脚本只准备，不自动跑。
- 首次部署前要核对：ECS 架构、可用内存、UDP 放行、`gamecity` 账号存在、`/opt/gamecity` 归属。
