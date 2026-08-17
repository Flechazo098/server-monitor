# Server Monitor

本地只读服务器监控桌面应用。

```
┌──────────────────────────────────────┐
│         Desktop Application          │
│  ┌────────────────────────────────┐  │
│  │ Vue 3 + TypeScript + ECharts   │  │
│  │ Dashboard / Servers / Events   │  │
│  │ History / Settings             │  │
│  └───────────────┬────────────────┘  │
│                  │ HTTP / WS          │
│                  ▼                    │
│  ┌────────────────────────────────┐  │
│  │ Haskell Sidecar                │  │
│  │ Servant + Warp + STM + SQLite  │  │
│  │ SSH (read-only) 采集           │  │
│  └────────────────────────────────┘  │
│  Tauri 2：窗口 / 托盘 / 生命周期      │
└──────────────────────────────────────┘
```

## 技术栈

| 部分 | 选型 |
|---|---|
| 桌面壳 | Tauri 2（Rust 只负责窗口与 sidecar 生命周期） |
| 后端 | Haskell（Servant + Warp + STM + async） |
| 本地存储 | SQLite（WAL + busy timeout，历史指标/事件/告警状态；实时快照在内存 TVar） |
| 前端 | Vue 3 + TypeScript + Vite + Pinia + ECharts（按需引入） |
| 采集 | 系统 OpenSSH（Tailscale 隧道，固定只读脚本） |
| 通信 | REST + WebSocket，127.0.0.1 动态端口 + Bearer token |

## 目录结构

```
server-monitor/
├── backend/            # Haskell 后端（Servant API + 采集器）
│   ├── monitor.cabal
│   ├── cabal.project
│   ├── config.json     # 服务器配置 + 告警阈值 + 采集策略
│   ├── app/Main.hs
│   └── src/Monitor/
│       ├── Core/       # 类型与配置
│       ├── Collector/  # SSH 只读采集 + 解析（SSH.hs / Parse.hs）
│       ├── Runtime/    # 采集 worker（分层调度、退避、告警引擎）
│       ├── Storage/    # SQLite 历史、事件与告警去重状态
│       └── Api/        # Servant API + WebSocket
├── frontend/           # Vue 3 + TS 仪表盘
├── src-tauri/          # Tauri 2 壳（sidecar 生命周期）
│   └── binaries/       # 编译后的 monitor-backend sidecar
├── scripts/
│   ├── build.ps1       # test/check/build/bundle/clean/contract/version/all
│   ├── set-version.ps1 # 同步四处版本号
│   ├── setup-updater.ps1
│   └── write-update-manifest.ps1
├── .github/workflows/  # 版本变化后的 Windows 签名发布
└── server-monitor.code-workspace
```

`backend/hie.yaml`、`.vscode/settings.json` 和根工作区文件会同时把 Cabal、Cargo
与前端 TypeScript 项目交给 HLS、rust-analyzer 和 Volar。建议直接打开
`server-monitor.code-workspace`；打开仓库根目录也使用相同设置。

## 构建与运行

### 1. 统一构建入口

```powershell
./scripts/build.ps1 version   # 校验 Tauri/Cargo/npm/Cabal 版本与 updater 公钥一致
./scripts/build.ps1 test      # Haskell 测试 + Haskell/JSON/Zod 契约 + 前端测试
./scripts/build.ps1 check     # test + hlint + TS/build + cargo fmt/check
./scripts/build.ps1 build     # sidecar + frontend + Tauri debug exe
./scripts/build.ps1 bundle    # NSIS + Tauri updater 签名（有本地/CI 密钥时）
./scripts/build.ps1 all       # check + bundle
./scripts/build.ps1 clean     # 仅清理仓库内可重建产物
./scripts/build.ps1 clean -Dependencies # 另清理 frontend/node_modules
```

`clean` 不删除全局 Cargo/Cabal/npm 缓存。Rust dev profile 已关闭调试符号和
增量缓存，release 使用 thin LTO，以降低 Windows/Tauri 构建的磁盘峰值。

版本只能由脚本统一修改：

```powershell
./scripts/set-version.ps1 -Version 0.2.0
```

### 2. 跨语言契约

TypeScript 不直接相信 Haskell JSON。`monitor-contract` 使用生产 ADT 与生产
`ToJSON` 生成 REST/WS 完整态和空态样本；Vitest 用 strict Zod schema 解码，
前端类型全部由 `z.infer` 得到。字段缺失、多余、改名或类型变化会在构建时失败，
每个运行时 REST/WS payload 也经过同一 schema。

```powershell
./scripts/build.ps1 contract
```

这不是跨语言形式化证明，而是生产序列化器、构建测试和运行时解码共同组成的
可执行契约；相比三份手写接口，它能把 `cpuPercent` 静默变成 `undefined` 的问题
转化为明确的协议错误。

### 3. 独立运行后端（开发调试）

```bash
cabal run exe:monitor-backend -- --config config.json --token 0123456789abcdef0123456789abcdef
# 输出 READY <port> <token>
# curl -H "Authorization: Bearer <token>" http://127.0.0.1:<port>/api/servers
```

### 4. 前端开发

```bash
cd frontend
npm install
npm run dev        # http://localhost:5173
```

浏览器模式需设置环境变量指向后端：
`VITE_BACKEND_PORT=<port> VITE_BACKEND_TOKEN=<token> npm run dev`

### 5. 桌面应用（Tauri）

```powershell
# 生成可直接后台启动并动态调试的 debug exe，同时暂存 sidecar
./scripts/build.ps1 build

# 生成签名 NSIS 安装器和 updater 签名
./scripts/build.ps1 bundle
```

桌面壳启用 single-instance；第二实例只恢复并聚焦主窗口。Windows 下 sidecar
被放进 `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` Job Object，正常关闭或 Rust 壳异常
退出都会回收 Haskell sidecar 及其 SSH 子进程树。

## 签名更新与发布

基础开发配置包含公钥但没有 endpoint，因此本地开发不会访问 GitHub。签名
`bundle` 和 CI 构建通过配置覆盖注入 Release endpoint，并生成现代 Tauri v2
产物：`*-setup.exe` 与 `*-setup.exe.sig`。`write-update-manifest.ps1` 生成
`latest.json`；客户端检测到新版本后显示更新条，下载后由 Tauri 校验 minisign
签名，再以 passive 模式安装并重启。

本地私钥位于 gitignored 的 `.local-secrets/`。仓库所有者需配置两个 GitHub
Secrets，任何时候都不要提交或打印它们：

* `TAURI_SIGNING_PRIVATE_KEY`
* `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`

`.github/workflows/release.yml` 在 `main` 上的 `tauri.conf.json` 变化或手动触发时
读取统一版本；已有 `v<version>` tag 则跳过，否则执行完整 check、签名 Windows
bundle、生成 manifest 并发布 Release。当前 GitHub 故障期间只完成了本地与静态
验证，尚未调用 GitHub API 或实际运行远端 workflow。

## 监控能力（全部只读）

* 系统：CPU total/user/system/iowait、内存 available/cache/buffers/swap、负载、运行时长、磁盘（/ 及全部有效挂载点）
* Docker：容器列表与 CPU/内存、images / containers / volumes / build cache 磁盘占用
* 网络：实时 RX/TX 速率（/proc/net/dev 差分）、vnStat 每日/每月流量历史
* 安全：TLS 证书状态/指纹/过期倒计时、TCP 监听端口与对外暴露、最近 24h SSH 成功/失败登录、UFW 状态与规则、iptables 拦截计数、fail2ban jail 与封禁 IP、SSH 主机公钥指纹
* 业务：m3u8 下载器任务队列（只读 jobs.db + /health）、Gitea 仓库数/用户/活跃度/健康
* 运维：apt 可升级包、systemd 服务状态、备份任务与最新备份时间、Caddy 访问日志大小与增长趋势
* 入口健康检查（配置的 publicUrls，含延迟）

每个采集段独立容错：单段 Unsupported / 权限不足 / 失败只记录到
sectionErrors，不影响服务器在线状态。远程脚本整体包在
timeout 90 里，本地再叠加 async 超时 + ssh 进程回收。

## 告警体系

阈值与持续时间全部在 backend/config.json 的 alerts 段：

| 条件 | 默认 | 级别 |
|---|---|---|
| 磁盘使用率（每个挂载点） | > 80% | critical |
| 内存使用率 | > 90% | critical |
| CPU 持续高（连续采样） | > 85% 持续 180s | warning |
| TLS 证书剩余天数 | < 30 天 | warning |
| 入口健康检查连续失败 | >= 3 次 | critical |
| 备份过旧 / 服务失败 | > 26h / failed | critical |
| 服务器不可达 | — | critical |

去重与防抖：每个告警键只发一次 fired / resolved 转换事件；
恢复后 cooldownSec（默认 3600s）内同键不重复触发，避免抖动刷屏。
活动/通知/冷却状态持久化到 SQLite，桌面应用或 sidecar 重启不会重复告警。

## 调度与保留策略

* 轻量指标脚本每 intervalSec（默认 20s）采样一次，用于实时曲线与速率
* 重量级库存/安全脚本每 fullIntervalSec（默认 300s）执行一次；入口健康仍随轻量采样执行
* 连续失败按 2 的幂退避，上限 backoffMaxSec（默认 300s），成功即恢复
* 上一轮未完成时跳过本轮，SSH 会话不会堆积
* SQLite 历史保留 retentionDays（默认 30 天），每 6 小时清理一次
* 历史查询按时间窗口动态分桶，完整覆盖请求范围并控制在约 3000 个图表点
* 本地 schema 使用 `PRAGMA user_version = 5`；版本不匹配时重建本地数据表，不承诺旧开发数据库兼容

## 安全设计（read-only by design）

* API 只有 GET 端点；不存在任何命令执行接口；
* 采集命令全部是后端内置的固定只读脚本，逐段容错；
* 后端只绑定 127.0.0.1，端口由 OS 动态分配，所有 REST 请求带 Bearer token；
* WebSocket 使用 query token 鉴权，并推送一致的 ServerState 快照与告警/状态转换；
* SSH 强制校验已有 known_hosts，不自动接受或写入新的主机密钥；
* Tauri WebView 没有 shell execute 权限，只有 Rust 壳可启动固定 sidecar；
* SSH 走 Tailscale 隧道，公网不暴露 22 端口；
* 私钥路径只在本地 config.json，日志与数据库不写入任何密钥或敏感信息。

## 配置（backend/config.json）

```json
{
  "dbPath": "monitor.db",
  "alerts": {
    "diskPct": 80, "memPct": 90, "cpuPct": 85, "cpuSustainSec": 180,
    "tlsMinDays": 30, "healthMaxFails": 3,
    "backupMaxAgeHours": 26, "cooldownSec": 3600
  },
  "collection": {
    "fullIntervalSec": 300, "timeoutSec": 90,
    "retentionDays": 30, "backoffMaxSec": 300
  },
  "servers": [
    {
      "id": "vultr",
      "name": "Vultr (45.76.195.129)",
      "sshHost": "100.82.162.19",
      "sshPort": 22,
      "sshUser": "linuxuser",
      "sshKey": "F:/code/server/.codex/keys/vultr_linuxuser_ed25519",
      "intervalSec": 20,
      "publicUrls": ["https://m3u8d.mafuyu.moe/health", "https://git.sighs.cc/"],
      "certHosts": ["m3u8d.mafuyu.moe", "git.sighs.cc"]
    }
  ]
}
```

certHosts 留空时自动从 publicUrls 提取主机名。

## API 一览

```
GET /api/health
GET /api/servers                # 完整状态快照（含 alerts / sectionErrors）
GET /api/servers/:id/containers
GET /api/servers/:id/services
GET /api/servers/:id/fail2ban
GET /api/servers/:id/backup
GET /api/history?server=:id&hours=24     # 指标历史（SQLite）
GET /api/caddy?server=:id&hours=168      # Caddy 日志大小趋势
GET /api/events?limit=50                 # 结构化事件（含 severity/state）
WS  /ws                    # snapshot + metrics/status/alert 推送
```
