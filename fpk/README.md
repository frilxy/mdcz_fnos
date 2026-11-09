# MDCz 飞牛 fnOS 原生应用包

把 [MDCz](https://github.com/ShotHeadman/mdcz) 官方 **非 Docker** 发行包（`mdcz-<version>.tar.gz`）封装成飞牛 NAS 应用中心可手动安装的 `.fpk`。

- 运行方式：Linux 原生进程，使用飞牛系统里已安装的 **Node.js 24**（`nodejs_v24`），**不使用 Docker**。
- 应用名：`mdcz`；显示名：**MDCz**（官方 WebUI 自带简体中文/英文切换，不额外标注「中文版」）；默认端口 **3838**。
- 程序文件装在应用目录，用户数据放在应用共享目录「应用文件 → mdcz」。
- 支持应用中心安装、启动、停止、重启、升级、卸载；崩溃后由内置守护进程自动拉起；NAS 开机后随应用中心自启。

```
fpk/
├── manifest                 # 应用元数据
├── ICON.PNG / ICON_256.PNG  # 包图标（取自官方桌面端图标）
├── config/
│   ├── privilege            # run-as=package，应用用户 mdcz
│   └── resource             # 声明共享目录 mdcz
├── cmd/                     # 生命周期脚本（安装/升级/配置/卸载/启停）
│   └── lib/common.sh        # 共享函数：目录、端口、Node、PID、健康检查
├── wizard/                  # 安装/升级/配置/卸载表单
├── app/
│   ├── ui/                  # 桌面入口（端口 ${wizard_port}）
│   ├── supervisor.mjs       # 进程守护：崩溃重启、优雅停止、PID 管理
│   └── ...                  # 构建时注入官方 server.js / web / node_modules
└── scripts/
    ├── prepare-runtime.sh   # 下载官方发行包 + 按官方 lockfile 装生产依赖
    ├── build-fpk.sh         # 组装 + 校验 + fnpack 打包
    ├── validate-fpk.sh      # 静态校验
    └── simulate-lifecycle.sh# 本机模拟安装/启动/崩溃/升级/卸载
```

## 运行时布局

| 用途 | 安装后位置 | 说明 |
| --- | --- | --- |
| 程序 | `/var/apps/mdcz/target` | 官方 `server.js`、`web/`、`persistence/`、`resources/`、`node_modules/`、`ui/`、`supervisor.mjs` |
| 配置 | `/vol*/@appshare/mdcz/config` | `default.toml`、`auth-state.json`、`.active-profile.json` |
| 数据库 | `/vol*/@appshare/mdcz/database` | `mdcz.sqlite`（含 `-wal` / `-shm` / `.lock.sqlite`） |
| 缓存 | `/vol*/@appshare/mdcz/cache` | `XDG_CACHE_HOME`、`TMPDIR`、临时首页 |
| 日志 | `/vol*/@appshare/mdcz/logs` | `mdcz.log`（服务输出）、`lifecycle.log`（启停/升级）、`install-smoke.log` |
| 备份 | `/vol*/@appshare/mdcz/backups` | 升级前自动备份 `pre-upgrade-*.tar.gz`，保留最近 5 份 |
| 运行态 | `/var/apps/mdcz/var` | pid 文件、停止标记（`TRIM_PKGVAR`） |
| 端口状态 | `/var/apps/mdcz/etc/web-port` | 记住用户选择的端口，升级不丢 |

媒体目录不复制进应用目录：用户在「应用设置 → 授权目录」授权影片文件夹，飞牛会把 ACL 授予应用用户 `mdcz`，MDCz 直接读写原目录。

## 构建

依赖：Linux x86_64、Node.js 24（含 corepack）、`curl`、`tar`、`python3`、`sha256sum`。

```bash
# 1. 准备运行时（下载官方 mdcz-<version>.tar.gz，校验 SHA256，按官方 pnpm-lock 安装生产依赖）
bash fpk/scripts/prepare-runtime.sh

# 2. 校验 + 打包（自动下载官方 fnpack 1.2.3）
bash fpk/scripts/build-fpk.sh

# 3. 本机模拟生命周期（可选，但建议每次改脚本后执行）
bash fpk/scripts/simulate-lifecycle.sh
```

产物：`dist/mdcz-<version>.fpk`，构建日志会打印版本、大小和 SHA256。

升级上游版本：修改 `fpk/manifest` 的 `version` 与 `changelog`，删除 `fpk/build/runtime`（或直接重跑 `prepare-runtime.sh`），再执行 `build-fpk.sh`。

### 构建说明

- 官方 `mdcz-<version>.tar.gz` **不含 `node_modules`**，其 `install.sh` 需要目标机联网 `corepack pnpm install`。为了让 fpk 装完即可离线运行，构建阶段用官方 `pnpm-lock.yaml`（`--frozen-lockfile`）装好生产依赖再打包。
- 原生依赖 `better-sqlite3`、`sharp`、`impit` 使用 npm 上的 x86_64 预编译包，构建机不需要 gcc；因此本包 `platform=x86`，ARM 设备不可安装。
- 打包使用飞牛官方 `fnpack 1.2.3`（`https://static2.fnnas.com/fnpack/`），不手写 fpk 格式。

## 自动同步上游

`.github/workflows/fnos-sync-upstream.yml` 每天 **北京时间 04:00**（UTC `0 20 * * *`）检查
[ShotHeadman/mdcz](https://github.com/ShotHeadman/mdcz) 的最新正式版：

1. 与 `fpk/upstream-version` 比较；没有新版本就结束。
2. 有新版本时更新 `fpk/upstream-version` 和 `fpk/manifest`（版本号、changelog）。
3. 下载新发行包并校验 SHA256，按官方 lockfile 重装生产依赖。
4. 执行 `build-fpk.sh` 与 `simulate-lifecycle.sh`；任一步失败都不会发布。
5. 提交 `chore: 同步上游 MDCz vX.Y.Z [skip ci]`、打 tag `vX.Y.Z`、发布 `mdcz-X.Y.Z.fpk` 与 `.sha256`。

也可以在 Actions 页面手动触发，指定上游版本：

```bash
gh workflow run fnos-sync-upstream.yml -f target_version=0.22.0
```

本地只检查不构建：

```bash
bash fpk/scripts/sync-upstream.sh --check-only
```

> 说明：这是“FPK 自动同步 + 自动发布”。飞牛应用中心对手动安装的 FPK 没有商店更新源，
> NAS 上仍需要在应用中心点一次升级；不会在 NAS 上保存管理员凭据做静默安装。

## 安装

1. 应用中心 → 手动安装 → 选择 `mdcz-<version>.fpk`。
2. 安装向导里确认 Web 端口（默认 3838）。若提示缺少 Node.js 24，请先在应用中心安装 `nodejs_v24`（manifest 已声明依赖，正常会自动处理）。
3. 安装完成后到「应用设置 → 授权目录」添加影片所在文件夹：
   - 只刮削、把 NFO/封面写到别处：读权限即可；
   - 需要写 NFO/封面/剧照、重命名或整理目录：必须给读写权限。
4. 打开应用（桌面图标或应用中心「打开」），首次进入设置管理员密码，然后添加媒体库。

访问地址：`http://<NAS 局域网 IP>:3838/`（端口以安装时设置为准）。

## 启停与日志

- 应用中心提供启动、停止、重启；`cmd/main` 也支持 `start|stop|status|log`。
- 启动前会检查端口占用、目录可写、Node 24 版本；启动后等待 `/health` 通过才返回成功。
- 进程管理：`app/supervisor.mjs` 记录 `pid + /proc 启动时间`，只操作自己的子进程；server 崩溃后按 3s→6s→…→60s 退避重启。停止时先 `SIGTERM`，20 秒未退出才 `SIGKILL`，不会误杀其他 Node 进程。
- 日志：「应用文件 → mdcz → logs」。应用中心启动失败时，错误摘要也会写入 `TRIM_TEMP_LOGFILE`。

## 升级

应用中心检测到更高版本后直接升级，或手动安装新 `.fpk`：

1. `upgrade_init`：停止服务，把 `config/` 与 `database/` 打包到 `backups/pre-upgrade-<旧版本>-to-<新版本>-<时间>.tar.gz`（保留最近 5 份）。
2. 替换程序文件（数据目录不受影响）。
3. `upgrade_callback`：补齐目录并启动；MDCz 启动时自动执行数据库迁移。

端口、授权目录、配置、数据库、媒体文件都会保留。升级前也可以手动再导出一份备份。

## 备份与恢复

- 热备份数据库（服务运行中，官方命令）：

  ```bash
  cd /var/apps/mdcz/target
  /var/apps/nodejs_v24/target/bin/node server.js database backup /vol1/1000/mdcz-backup.sqlite
  ```

  该命令只备份数据库；`config/`（含管理员密码哈希）需要另外复制。

- 冷备份（推荐，最完整）：在应用中心停止 MDCz，然后打包整个数据目录：

  ```bash
  tar -czf /vol1/1000/mdcz-data-$(date +%F).tar.gz -C /vol*/@appshare/mdcz .
  ```

  恢复：停止应用 → 解压覆盖回 `@appshare/mdcz` → 启动。

- 升级自动备份位于 `@appshare/mdcz/backups/`，恢复时解压对应 `pre-upgrade-*.tar.gz` 到数据目录即可（会覆盖 config/database）。

## 卸载

卸载向导默认 **保留** 数据目录；勾选「同时删除 MDCz 数据目录」才会清空 `@appshare/mdcz` 下的 config/database/cache/logs/backups。授权过的影片目录和影片文件永远不会被删除。

卸载前会停止服务并清理 pid，避免残留进程。

## 已验证 / 未验证

### 真实 fnOS（本机 192.168.10.229，2026-11-06）

- [x] 应用中心手动安装 `mdcz-0.21.0.fpk` 成功，依赖 `nodejs_v24` 由应用中心确认并记录
- [x] 安装后自动运行：`status=running`，进程以专用用户 `mdcz`（uid 981）运行 supervisor + server
- [x] 桌面入口 `mdcz.main` 为 iframe，端口正确取到向导值 `3838`，标题「MDCz」
- [x] `http://192.168.10.229:3838/` 返回 200，`/health` 返回 `{"status":"ok"}`，监听 `0.0.0.0:3838`
- [x] 应用中心「重启」成功，supervisor/server 换成新 PID 并恢复健康
- [x] 应用中心「停止」后进程退出、端口释放、`status=stopped`；再次「重启」可正常拉起
- [x] 数据目录真实生成：`@appshare/mdcz/{config,database,cache,logs,backups}`，属主 `mdcz`；`config/default.toml`、`database/mdcz.sqlite` 已创建
- [x] 端口状态写入 `@appconf/mdcz/web-port`，值为 3838
- [x] 应用中心真实升级 `0.21.0` → `0.21.0.1`：升级前自动停止并生成 `backups/pre-upgrade-0.21.0-to-0.21.0.1-20261106-204648.tar.gz`（约 890 KB），升级后自动启动
- [x] 升级后 `config/default.toml`、`database/mdcz.sqlite`、`web-port` 全部保留，显示名与入口标题均为「MDCz」，版本 `0.21.0.1`，端口仍为 3838
- [x] 真实刮削成功：`JUR-890` 生成 `JUR-890.nfo` / `movie.nfo`、poster、fanart、`extrafanart/fanart1-10.jpg`、`.actors` 演员头像，媒体目录写入正常
- [x] 升级到 `0.21.0.2` 后自动修复生效：`upgrade_callback` 对 `/vol1/1000/download/xunlei`、`/vol3/1000/lim` 执行 `trimacl -m a:o:RWX:sdf`，写入 `@appconf/mdcz/acl-owner-fix-v1`
- [x] 自动修复后服务仍以 `mdcz` 运行：进程树为 `root runuser -> mdcz supervisor -> mdcz server`，3838 端口不是 root 监听

> 说明：`fnos-cli` 的 `app start` 会因 `nodejs_v24` 状态为 `nostart`（运行时包，不是可启停服务）而要求走应用中心界面，这是 CLI 的依赖保护，不是应用故障；`app restart` 与 GUI 启动正常。

### 本机模拟验证（与安装后相同的目录结构和 TRIM_* 环境）

- [x] fnpack 1.2.3 构建成功，包结构/版本/图标/入口/依赖校验通过
- [x] 官方发行包 SHA256 校验、原生模块在 Node 24.22.1 上加载
- [x] install_init / install_callback、数据目录初始化、SQLite 初始化
- [x] 启动、`/health`、WebUI 首页、status、停止、端口释放
- [x] server 被 SIGKILL 后 supervisor 自动重启
- [x] 运行中修改端口触发重启并持久化
- [x] 升级保留配置/数据库、生成 `pre-upgrade-*.tar.gz`、自动恢复
- [x] 卸载默认保留数据；选择删除时只清理 `@appshare/mdcz`
- [x] 端口被占用时拒绝启动并给出用户可见错误
- [x] 测试后无残留进程

### 尚未实机验证

- [ ] NAS 重启后随应用中心自启（依赖 fnOS 默认行为，未重启设备）
- [ ] 「授权目录」ACL 下实际读取影片、写 NFO/封面、重命名
- [ ] 真实刮削联网（源站可达性、Cookie/登录）
- [ ] 浏览器内 iframe 实际打开效果（入口配置与 HTTP 响应已确认）

## 故障排查

| 现象 | 处理 |
| --- | --- |
| 启动失败：未找到 Node.js 24 | 应用中心安装 `nodejs_v24`，确认 `/var/apps/nodejs_v24/target/bin/node -v` ≥ 24 |
| 启动失败：端口被占用 | 应用设置里换端口，或停止占用端口的应用；`ss -ltnp \| grep 3838` 查看 |
| WebUI 打不开 | 先看 `@appshare/mdcz/logs/mdcz.log`；确认应用状态为运行中，端口与入口一致 |
| 刮削报错 / 无法读取影片 | 检查「授权目录」是否包含影片上级目录；需要写文件时给读写权限；重启应用 |
| 刮削报 `EACCES: permission denied, copyfile/scandir /vol1/...` | 飞牛 1.2.x 的 trimacl 已知缺陷，见下方「飞牛 1.2.x 写入权限（trimacl）」 |
| 数据库被锁 | 同一数据库只能有一个 MDCz 实例；确认没有手工再起一个 `node server.js` |
| 原生模块加载失败 | 确认是 x86_64 设备；`node_modules` 不应被手工替换；重新安装应用包 |

### 飞牛 1.2.x 写入权限（trimacl）

> 0.21.0.2 起会自动处理：`cmd/main start` 以 root 对每个授权目录执行 `trimacl -m a:o:RWX:sdf`，首次启动还会遍历已有影片目录补一遍；Web 服务仍然降权到 `mdcz` 运行。下面的手工命令适用于旧版本或自动修复失败的情况。

**现象**：授权目录已设为「读写」，但刮削时仍报：

```
EACCES: permission denied, copyfile '/vol1/.../.mdcz-staging-.../extrafanart/.scene-set-...jpg'
EACCES: permission denied, scandir '/vol1/1000/download/xunlei'
```

**原因**：飞牛 1.2.x 的 trimacl（Windows ACL）内核补丁存在非 root 用户写入判定缺陷，表现为目录/文件属主与权限位都正确、ACL 也显示可读写，但应用用户创建文件后再次打开写入仍被拒绝。上游论坛记录：

- [fnOS 1.2.0302 trimacl 挂载选项导致非 root 用户写入权限检查异常](https://club.fnnas.com/forum.php?mod=viewthread&tid=70373)

**处理**（需要 NAS 的 root SSH；二选一）：

1. 官方给的单条命令（推荐先只对出问题的媒体目录执行）：

   ```bash
   trimacl -m a:o:RWX:sdf /vol1/1000/download/test
   trimacl -m a:o:RWX:sdf /vol1/1000/download/xunlei
   ```

   然后重新刮削。新创建的文件会继承 owner 的 RWX ACE，写入恢复正常。

2. 如果同时用应用中心 API 的 `file acl set` 修，**必须保留应用用户的 ACE**，不能只写 owner，否则应用会连目录都无法读取（`scandir ... EACCES`）。正确写法是同时包含 owner 和 `mdcz`：

   ```json
   [{"owner":32719,"inherit":7},{"uid":981,"perm":14287,"inherit":7}]
   ```

   （`uid` 以 `id -u mdcz` 为准。）

执行后 `ls -ld` 会从 `d---------` 变成 `drwx------`，这是正常的。已存在的旧文件如果仍不可写，删除该影片目录里的旧 NFO/图片后重新刮削即可。

## 安全

- Web 服务以专用用户 `mdcz` 运行；安装/升级/启停等生命周期脚本以 root 运行，仅用于给「授权目录」补 trimacl ACE，服务进程通过 `runuser` 降权，不以 root 监听端口。
- 默认监听 `0.0.0.0` 仅为局域网访问，不要直接把端口映射到公网；远程访问建议 VPN 或带认证的反向代理。
- 升级/卸载脚本只操作 `@appshare/mdcz`，不会删除媒体文件。
