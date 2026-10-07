# deploy/ — 发布与备份

约定见 docs/ops/deploy.md。这里的脚本**只准备、不自动跑**：`deploy.sh` 默认 dry-run，真实执行要 `--yes`，而每一次生产变更（首次部署、重新发布、停服、改存档）都要负责人先确认。主机地址不进仓库，只放在本机的 `deploy/.env`（已 git-ignore）。同一台机器上 `/opt/genius` 及其 systemd 单元属于另一个服务，所有脚本都不碰它。

## 文件

| 文件 | 用途 | 装到哪 |
| --- | --- | --- |
| `deploy.sh` | 本地门禁 → `git archive HEAD` → scp → `mv -T` 切 `current` → 重启 → 轮询 `status.json` → 失败回滚 → 修剪 3 份 | 本机运行 |
| `.env.example` | `deploy.sh` 的参数模板（主机、用户、端口、路径、保留份数、健康超时） | 复制为 `deploy/.env` |
| `gamecity.env.example` | 服务运行参数（端口、pace、轮次秒数、存档间隔），由 unit 的 `EnvironmentFile` 读 | `/opt/gamecity/.env`，`root:gamecity 0640` |
| `gamecity.service` | 专用服务器 unit：`Restart=on-failure`、`TimeoutStopSec=30`（SIGTERM 先存后退）、`MemoryMax=400M` | `/etc/systemd/system/gamecity.service` |
| `gamecity.service.d/release.conf` | drop-in 模板，`deploy.sh` 每次发布把 `@RELEASE@` 换成 `<sha>-<ts>` 写入，`systemctl show gamecity -p Environment` 能看到在跑哪个版本 | `/etc/systemd/system/gamecity.service.d/release.conf`（脚本写） |
| `gamecity.service.d/user.conf` | drop-in 模板，机器上账号不是 `gamecity:gamecity` 时手工替换 `@RUN_USER@` / `@RUN_GROUP@` 安装 | 同上目录（手工） |
| `backup.sh` | 把 `data/` 打包到 `backups/`，保留 14 份，`umask 077`，文件 0600 | 随 release 一起上去，由 timer 调 `/opt/gamecity/current/deploy/backup.sh` |
| `gamecity-backup.service` / `.timer` | 每日 03:47 跑 `backup.sh`（避开另一个服务的 03:17） | `/etc/systemd/system/` |

## 主机布局

```
/opt/gamecity/
  godot                     官方 Linux 4.7.2 二进制，按 uname -m 选 x86_64 / arm64，与本地同版本
  releases/<sha>-<ts>/      每次发布一份，保留 3 份；每份带 BUILD_INFO.json 和 .previous
  current -> releases/...   mv -T 原子切换
  data/                     存档与 status.json，发布不碰
  backups/                  backup.sh 产物，0600，保留 14 份
  .env                      运行参数，0640
```

ENet 走 **UDP 24567**，安全组放行 UDP。

## 首次部署清单（负责人确认后，按顺序）

1. 核对 ECS：`uname -m`、可用内存（`MemoryMax=400M` 是起点）、磁盘、UDP 放行。
2. 建账号与目录：`useradd -r -s /usr/sbin/nologin gamecity`；`mkdir -p /opt/gamecity/{releases,data,backups}`；`chown -R gamecity:gamecity /opt/gamecity`。
3. 放 Godot 二进制到 `/opt/gamecity/godot`，`chmod +x`，`/opt/gamecity/godot --version` 必须是 `4.7.2.stable`。
4. `install -m 640 -o root -g gamecity deploy/gamecity.env.example /opt/gamecity/.env`，按需改端口 / pace / 轮次。
5. `install -m 644 deploy/gamecity.service /etc/systemd/system/`；账号不同时再装 `user.conf`；`systemctl daemon-reload && systemctl enable gamecity`。
6. 备份计划：`install -m 644 deploy/gamecity-backup.service deploy/gamecity-backup.timer /etc/systemd/system/ && systemctl enable --now gamecity-backup.timer`。
7. 本机 `cp deploy/.env.example deploy/.env` 填主机与用户；`deploy/deploy.sh` 先看 dry-run 输出；再 `deploy/deploy.sh --yes`。

部署账号需要免密 `sudo systemctl` / `sudo tee` / `sudo chown`（或直接用 root 并把 `GAMECITY_SUDO` 设为空）。

## 发布

```bash
deploy/deploy.sh                 # dry-run：打印全部本地与远端命令序列，本地打包，不触网
deploy/deploy.sh --with-gate     # dry-run 但真的先跑 tests/run_smoke.sh
deploy/deploy.sh --yes           # 真实执行；门禁不绿不打包；工作区脏则拒绝（--allow-dirty 放行）
```

退出码：0 发布且健康；1 门禁 / 打包 / 预检拒绝（主机未改动）；2 不健康已回滚到上一版；3 不健康且回滚也失败（需要上机）。

两处与 docs/ops/deploy.md 字面不同、需要集成者知道的实现决定：

- 打包默认排除 `client/assets/techart`（`GAMECITY_ARCHIVE_EXCLUDE`，119 MB 贴图，无头服务器不加载；设为空串即完整 `git archive HEAD`）。
- 解包后在主机上跑一次 `godot --headless --path <release> --import`：新 checkout 没有 `.godot/`，缺 `global_script_class_cache.cfg` 时 `shared/` 的 `class_name` 解析不了。日志在 `<release>/import.log`。

健康 = `data/status.json` 的 mtime 距今 ≤ 5 秒且 `tick` 在两次采样间增长，超时 `GAMECITY_HEALTH_TIMEOUT`（默认 60 秒）。回滚目标来自 `releases/<新版本>/.previous`。修剪保留最新 `GAMECITY_KEEP_RELEASES`（默认 3）份，永远不删 `current` 指向的那份。

## 备份与恢复演练

`backup.sh` 每日 03:47 跑；手动 `systemctl start gamecity-backup`。恢复演练不碰线上 `data/`：解包到临时目录，用 `--save-dir` 指向它启动一个本地服务器（别的端口），确认 `status.json` 的 `tick` 从快照继续而不是归零——与 `tests/run_smoke.sh` 第 5 步同一个断言。

## 还没验证的部分

脚本在本机只跑过 dry-run（没有主机）。首次真实发布时要盯着 [3] 预检的输出（远端 godot 版本、账号、unit、`.env`）和 [6] 的健康轮询；`gamecity.service` 的 `MemoryMax` 与更严格的沙箱选项按实测再调。
