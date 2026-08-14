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
| 本地存储 | SQLite（WAL + busy timeout，历史指标，实时状态在内存 TVar） |
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
│       ├── Storage/    # SQLite 历史
│       └── Api/        # Servant API + WebSocket
├── frontend/           # Vue 3 + TS 仪表盘
├── src-tauri/          # Tauri 2 壳（sidecar 生命周期）
│   └── binaries/       # 编译后的 monitor-backend sidecar
├── scripts/
│   └── build-backend.ps1
└── docs/               # 本地参考文档
```

## 构建与运行

### 1. 编译 Haskell 后端

```bash
cd backend
cabal build exe:monitor-backend
```

### 2. 独立运行后端（开发调试）

```bash
cabal run exe:monitor-backend -- --config config.json
# 输出 READY <port> <token>
# curl -H "Authorization: Bearer <token>" http://127.0.0.1:<port>/api/servers
```

### 3. 前端开发

```bash
cd frontend
npm install
npm run dev        # http://localhost:5173
```

浏览器模式需设置环境变量指向后端：
`VITE_BACKEND_PORT=<port> VITE_BACKEND_TOKEN=<token> npm run dev`

### 4. 桌面应用（Tauri）

```bash
# 1) 编译后端并放到 sidecar 目录
pwsh scripts/build-backend.ps1

# 2) 开发模式（自动起 Vue dev server + Haskell sidecar）
cd src-tauri
cargo tauri dev

# 3) 打包安装程序（打包后把 config.json 放到 exe 同目录）
cargo tauri build
```

## 监控能力（全部只读）

* 系统：CPU / 内存 / 负载 / 运行时长 / 磁盘（/ 及全部有效挂载点）
* Docker：容器列表与 CPU/内存、images / containers / volumes / build cache 磁盘占用
* 网络：实时 RX/TX 速率（/proc/net/dev 差分）、vnStat 每日/每月流量历史
* 安全：TLS 证书状态/指纹/过期倒计时、TCP 监听端口与对外暴露、最近 24h SSH 成功/失败登录、UFW 状态与规则、iptables 拦截计数、fail2ban jail、SSH 主机公钥指纹
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

## 调度与保留策略

* 轻量指标脚本每 intervalSec（默认 20s）采样一次，用于实时曲线与速率
* 重量级全量脚本每 fullIntervalSec（默认 60s）执行一次
* 连续失败按 2 的幂退避，上限 backoffMaxSec（默认 300s），成功即恢复
* 上一轮未完成时跳过本轮，SSH 会话不会堆积
* SQLite 历史保留 retentionDays（默认 30 天），每 6 小时清理一次

## 安全设计（read-only by design）

* API 只有 GET 端点；不存在任何命令执行接口；
* 采集命令全部是后端内置的固定只读脚本，逐段容错；
* 后端只绑定 127.0.0.1，端口由 OS 动态分配，所有 REST 请求带 Bearer token；
* WebSocket 端点豁免 token（浏览器无法设置 WS 头），但只推送只读指标；
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
    "fullIntervalSec": 60, "timeoutSec": 90,
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
