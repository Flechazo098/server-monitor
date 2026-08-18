import { computed, watch } from 'vue'
import { createI18n, useI18n } from 'vue-i18n'

export type AppLocale = 'en' | 'zh-CN'

const saved = localStorage.getItem('server-monitor.locale')
const initialLocale: AppLocale = saved === 'en' || saved === 'zh-CN'
  ? saved
  : navigator.language.toLowerCase().startsWith('zh') ? 'zh-CN' : 'en'

const messages = {
  en: {
    nav: { overview: 'Overview', servers: 'Servers', events: 'Events', history: 'History', settings: 'Settings' },
    app: {
      subtitle: 'Read-only ops', connected: 'Backend connected', disconnected: 'Backend disconnected',
      language: 'Language', english: 'English', chinese: '中文',
      updateAvailable: 'Signed update available', later: 'Later', update: 'Update', downloading: 'Downloading', updateFailed: 'Update installation failed',
    },
    settings: {
      title: 'Settings', subtitle: 'Protected local configuration, sampling policy and alert thresholds',
      security: 'Configuration security', securityBody: 'Configuration is encrypted at rest with Windows DPAPI and can be decrypted only by this Windows user. Decrypted JSON is passed to the local sidecar in memory; it is never written as plaintext.',
      save: 'Save encrypted configuration', saving: 'Saving…', saved: 'Encrypted configuration saved. Restart to apply it.',
      restart: 'Restart now', addServer: 'Add server', removeServer: 'Remove', server: 'Server {index}',
      connection: 'Backend connection', policy: 'Runtime status', alerts: 'Alert thresholds', collection: 'Collection policy', servers: 'Monitored servers',
      loadFailed: 'Could not load protected configuration', saveFailed: 'Could not save configuration',
      urlsHint: 'One URL per line', hostsHint: 'One DNS name per line', encrypted: 'DPAPI · CurrentUser',
    },
  },
  'zh-CN': {
    nav: { overview: '概览', servers: '服务器', events: '事件', history: '历史', settings: '设置' },
    app: {
      subtitle: '只读运维监控', connected: '后端已连接', disconnected: '后端未连接',
      language: '语言', english: 'English', chinese: '中文',
      updateAvailable: '发现已签名更新', later: '稍后', update: '更新', downloading: '正在下载', updateFailed: '更新安装失败',
    },
    settings: {
      title: '设置', subtitle: '受保护的本地配置、采集策略与告警阈值',
      security: '配置安全', securityBody: '配置静态存储使用 Windows DPAPI 加密，仅当前 Windows 用户可解密。解密后的 JSON 只在内存中传递给本地后端，不会以明文写入磁盘。',
      save: '加密保存配置', saving: '正在保存…', saved: '加密配置已保存，重启后生效。',
      restart: '立即重启', addServer: '添加服务器', removeServer: '移除', server: '服务器 {index}',
      connection: '后端连接', policy: '运行状态', alerts: '告警阈值', collection: '采集策略', servers: '监控服务器',
      loadFailed: '无法加载受保护配置', saveFailed: '无法保存配置',
      urlsHint: '每行一个 URL', hostsHint: '每行一个 DNS 名称', encrypted: 'DPAPI · 当前用户',
    },
  },
}

export const i18n = createI18n({
  legacy: false,
  locale: initialLocale,
  fallbackLocale: 'en',
  messages,
})

document.documentElement.lang = initialLocale

export function useAppLocale() {
  const { locale } = useI18n()
  const appLocale = computed<AppLocale>({
    get: () => locale.value as AppLocale,
    set: (value) => { locale.value = value },
  })
  watch(appLocale, (value) => {
    localStorage.setItem('server-monitor.locale', value)
    document.documentElement.lang = value
  }, { immediate: true })
  return { locale: appLocale }
}

const zh: Record<string, string> = {
  'Overview': '概览', 'Servers': '服务器', 'Events': '事件', 'History': '历史', 'Settings': '设置',
  'Healthy': '健康', 'Warning': '警告', 'Critical': '严重', 'Offline': '离线', 'Online': '在线', 'Info': '信息',
  'Server': '服务器', 'Status': '状态', 'Time': '时间', 'Type': '类型', 'Severity': '级别', 'State': '状态', 'Message': '消息',
  'CPU': 'CPU', 'MEM': '内存', 'Memory': '内存', 'Load': '负载', 'Uptime': '运行时间', 'Updated': '更新时间',
  'Mode': '模式', 'Address': '地址', 'API health': 'API 健康状态', 'Live events': '实时事件',
  'healthy': '健康', 'reachable': '可达', 'active alerts': '活动告警', 'updated': '更新于', 'online': '在线', 'days': '天', 'times': '次', 'total': '合计',
  'Load 1m': '1 分钟负载', 'NET (rx / tx)': '网络（接收 / 发送）', 'NET rate': '网络速率',
  'Containers': '容器', 'Listen ports': '监听端口', 'Wildcard binds': '全地址绑定', 'SSH fails 24h': 'SSH 失败（24 小时）',
  'apt updates': 'apt 更新', 'Failed sections': '采集失败项', 'Inventory': '服务器清单',
  'Active alerts': '活动告警', 'Avg CPU': '平均 CPU', 'Avg MEM': '平均内存', 'Traffic today': '今日流量',
  'Cert expiring soonest': '最近到期证书', 'Traffic · vnStat daily': '每日流量 · vnStat',
  'Public entry points': '公开入口', 'TLS certificates': 'TLS 证书', 'Event log': '事件日志',
  'Metric history': '指标历史', 'Traffic per day · vnStat (30 days)': '每日流量 · vnStat（30 天）',
  'CPU composition · live': 'CPU 构成 · 实时', 'Network throughput (live)': '网络吞吐 · 实时',
  'Listening ports': '监听端口', 'Docker containers': 'Docker 容器', 'Filesystem mounts': '文件系统挂载点',
  'Docker disk usage (system df)': 'Docker 磁盘占用（system df）', 'Package updates (apt)': '软件包更新（apt）',
  'Firewall (UFW)': '防火墙（UFW）', 'Blocked traffic (iptables counters)': '拦截流量（iptables 计数）',
  'Fail2ban jails': 'Fail2ban 封禁', 'SSH auth (last 24h)': 'SSH 认证（最近 24 小时）',
  'SSH host key fingerprints': 'SSH 主机密钥指纹', 'm3u8 downloader queue': 'm3u8 下载队列',
  'Caddy access log': 'Caddy 访问日志', 'Backups': '备份', 'Unavailable sections': '不可用采集项',
  'No active alerts': '当前没有活动告警', 'No public URLs configured': '未配置公开 URL',
  'No certificates probed': '尚无证书探测结果', 'No servers — check protected configuration': '没有服务器，请检查受保护配置',
  'No events match the filters': '没有符合筛选条件的事件', 'No samples in this window': '此时间范围内没有采样',
  'vnStat daily data unavailable': 'vnStat 每日数据不可用', 'No listening socket data': '没有监听套接字数据',
  'No container data': '没有容器数据', 'No mount data': '没有挂载点数据', 'Docker not available': 'Docker 不可用',
  'apt unavailable': 'apt 不可用', 'UFW unavailable': 'UFW 不可用', 'iptables unavailable': 'iptables 不可用',
  'Fail2ban unavailable': 'Fail2ban 不可用', 'journalctl unavailable or no logins': 'journalctl 不可用或没有登录记录',
  'No certificate probes succeeded': '没有成功的证书探测', 'Host keys unreadable': '无法读取主机公钥',
  'Downloader unreachable': '下载器不可达', 'Gitea unreachable': 'Gitea 不可达', 'Caddy log unavailable': 'Caddy 日志不可用',
  'Backup info unavailable': '备份信息不可用', 'loading…': '加载中…', 'loading server…': '正在加载服务器…',
  'refreshing…': '正在刷新…', 'no metrics yet': '尚无指标', 'Restricted bind': '受限地址绑定', 'Exposed bind': '全地址绑定',
  'Active': '活动', 'Recovered': '已恢复', 'Success': '成功', 'Failed': '失败', 'Enabled': '已启用', 'Disabled': '已停用',
  'active transitions in current view': '当前视图中的活动状态变更', 'events shown': '条事件',
  'All servers': '全部服务器', 'All types': '全部类型', 'Alerts': '告警', 'All severities': '全部级别', 'Refresh': '刷新',
  'window': '时间窗口', 'persisted samples': '条持久化采样', 'samples': '条采样',
  'Last hour': '最近 1 小时', 'Last 6 hours': '最近 6 小时', 'Last 24 hours': '最近 24 小时', 'Last 7 days': '最近 7 天',
  'Load average': '平均负载', 'Net throughput': '网络吞吐', 'Traffic rx (today)': '今日接收流量', 'Traffic tx (today)': '今日发送流量',
  'user': '用户态', 'system': '内核态', 'memory used': '已用内存',
  'Disk usage threshold': '磁盘使用率阈值', 'Memory threshold': '内存阈值', 'CPU threshold': 'CPU 阈值',
  'CPU sustain time': 'CPU 持续时间', 'TLS minimum validity': 'TLS 最短有效期', 'Health failure count': '健康检查失败次数',
  'Backup maximum age': '备份最大时长', 'Re-alert cooldown': '重复告警冷却', 'Full inventory interval': '完整采集间隔',
  'SSH collection timeout': 'SSH 采集超时', 'History retention': '历史保留时间', 'Failure backoff cap': '失败退避上限',
  'Database path': '数据库路径', 'Display name': '显示名称', 'SSH host': 'SSH 主机', 'SSH port': 'SSH 端口',
  'SSH user': 'SSH 用户', 'SSH private key path': 'SSH 私钥路径', 'Fast sample interval': '快速采样间隔',
  'Public URLs': '公开 URL', 'TLS certificate hosts': 'TLS 证书主机',
  'Changes affect only local monitoring and never mutate a server.': '修改只影响本地监控配置，绝不会改动远端服务器。',
  'Storage': '存储', 'Network & Security': '网络与安全', 'Certificates': '证书', 'Business': '业务', 'Logs & Backups': '日志与备份',
  'last collection': '上次采集', 'failed section(s)': '个采集失败项', 'Last collection error': '上次采集错误',
  'CPU total': 'CPU 总计', 'User / system / IO': '用户态 / 内核态 / IO', 'Memory used': '已用内存',
  'Available / cache': '可用 / 缓存', 'Buffers': '缓冲区', 'Swap': '交换空间',
  'Port': '端口', 'Protocol': '协议', 'Bound to': '绑定地址', 'Process': '进程', 'Bind scope': '绑定范围', 'All interfaces': '所有接口',
  'Name': '名称', 'Image': '镜像', 'Latency': '延迟', 'Mount': '挂载点', 'Source': '来源', 'Size': '大小', 'Used': '已用', 'Available': '可用', 'Usage': '使用率',
  'Category': '类别', 'Count': '数量', 'images': '镜像', 'containers': '容器', 'volumes': '卷', 'build cache': '构建缓存',
  'Upgradable packages': '可升级软件包', 'Inactive': '未启用', 'To': '目标', 'Action': '动作', 'From': '来源',
  'Dropped / rejected packets': '丢弃 / 拒绝的数据包', 'Blocked bytes': '拦截字节数', 'Packets': '数据包', 'Bytes': '字节',
  'Target': '目标', 'Destination': '目的地址', 'Jail': '封禁规则', 'Current': '当前', 'Total': '累计', 'Banned IPs': '已封禁 IP',
  'Result': '结果', 'User': '用户', 'Accepted': '成功', 'Host': '主机', 'Subject': '使用者', 'Issuer': '颁发者',
  'Expires': '到期时间', 'Days left': '剩余天数', 'SHA-256 fingerprint': 'SHA-256 指纹', 'Key file': '公钥文件', 'Algorithm': '算法', 'Fingerprint': '指纹',
  'Service health': '服务健康状态', 'Unreachable': '不可达', 'Queue': '队列', 'Empty': '空', 'Title': '标题', 'Progress': '进度',
  'Health': '健康状态', 'Repositories': '仓库数', 'Users': '用户数', 'Repos active (7d)': '近 7 天活跃仓库',
  'Latest repository update': '最近仓库更新', 'Log size': '日志大小', 'Growth': '增长速度', 'loading history…': '正在加载历史…',
  'Last run': '上次运行', 'Next run': '下次运行', 'Local copies': '本地副本', 'Newest file': '最新文件', 'Service': '服务',
  'Unknown': '未知', 'Section': '采集项', 'Reason': '原因',
}

export function useUiText() {
  const { locale } = useI18n()
  return (value: string): string => locale.value.startsWith('zh') ? (zh[value] ?? value) : value
}
