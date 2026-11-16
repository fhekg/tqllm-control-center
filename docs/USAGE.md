# tqLLM Control Center 使用说明

## 1. 启动应用

Finder 双击 `/Applications/tqLLM Control Center.app`（或项目 `build/` 内的同名应用）。
窗口为浅色原生 macOS 窗口；首页顶部为运行状态面板与全局「启动服务 / 关闭服务」开关。

## 2. 首页指标含义

| 指标 | 来源 | 说明 |
|---|---|---|
| 生成速度 Answering | snapshot 活动 decode 请求速率之和 | 无正在生成的请求时显示 `—` |
| 填充速度 Prefill | snapshot 最近 prefill 速率 | 不含缓存命中 |
| 首字延迟 TTFT | snapshot `first_output_ms` | 最近一次请求 |
| 上下文上限 Context | `/health.context` / `engine.context_per_slot` | 并发 >1 时为每槽值 |
| 内存占用 Memory | 引擎进程 `phys_footprint`（Metal 版 hardware 采样为 null 时的真实来源） | 统一内存 |

右上角 pill 显示「实时 · 采样时间」或「未连接」；状态点区分运行 / 启动中 / 故障 / 停止。

## 3. 服务控制

- 全局开关在顶部；详情页提供重启、环境检查、启动参数预览（可复制完整命令）。
- **登录时自动启动**：通过 `SMAppService` 注册登录项（应用需位于 /Applications）。
- **退出应用时停止服务**：默认关闭。关闭时应用退出后引擎继续运行，下次打开应用会识别为「外部终端（tqllm CLI）启动」，停止需确认。
- 启动前自动检查：CLI 可执行、主模型 / 草稿模型存在（外置盘 stat 带 8s 超时）、QSA 兼容性、阈值 ≥4096。

## 4. 模型管理

- 「扫描模型」读取目录内 GGUF 头部元数据（不加载权重、不改动文件）。
- 自动识别：主模型（qwen35 + QSA 索引张量）、草稿（dflash）、其他（标记「未验证兼容」）。
- 外置硬盘断开 / 休眠：页面显示「磁盘无响应」，启动被阻止并提示；重新挂载后再扫描。
- 切换主模型 / 草稿后需重启服务生效（页面有「需要重启」徽标）。

## 5. QSA 加速

- 开关映射 `--qsa-from N|off`（启动级）。仅当主模型含 QSA 索引时可用。
- 阈值选项 32K/48K/64K/96K（引擎要求 ≥4096）。
- 「运行 QSA A/B 对照」：固定长文档（阈值+8K tokens，自动校准加长）、temperature=0、输出 128，
  两臂仅 `--qsa-from` 不同，各重启引擎跑 2 轮 + 预热，比较 decode 中位速度并给出判定。
- 三态区分：已配置（UI）/ 已加载（启动参数回显）/ 实际触发（A/B 证据）。

## 6. 推测解码

- DFlash2：`-md <gguf> --draft-max N`，Tree 默认开（`--no-tree` 关）。
- MTP：`--mtp`（模型需 MTP 头；本模型有），要求并发 1，不与 `-md` 同用。
- 接受率来自 snapshot `drafted/accepted`，无请求时显示「尚无测量」。

## 7. 上下文与缓存

- Context / KV 精度 / Prompt Cache / Memory Fit 均为启动级；「设置值 vs 实际加载值」面板对照
  `/health.context` 与日志 `KV format …` / `fit:` 公告（Memory Fit 可能自动降级）。

## 8. 生成参数

- Temperature / Top-p / Top-k / Max Tokens / 思考模式为**请求级**，随每次请求发送；
  「发送测试请求」用流式 API 实测并显示 TTFT。启动级默认值另行映射（`--temperature` 等）。

## 9. API 服务

- Host / Port / 并发（`--np`）启动级；运行中可用「应用并发到运行中服务」（`POST /admin/slots`）。
- API Key 存 Keychain；「检查连接」实测 `/health` 与 `/v1/models`。
- Tailscale：Host 设 `0.0.0.0` 或 Tailscale IP 并重启，建议设 Key；页面自动探测并给出 Tailscale 地址。

## 10. 实时性能 / 运行日志 / 配置预设

- 性能页：实时曲线、请求统计表格、短上下文基准、QSA A/B、历史报告查看与 Markdown 导出。
- 日志页：官方 `~/.cache/tqllm/server.log` 增量 tail + 应用事件；全部/启动/请求/错误筛选；
  诊断清单一键复制；日志导出。
- 预设页：日常交互 / 长上下文 QSA / 性能基准测试 + 自定义保存；JSON 导入导出（不含 Key）；
  持久化于 `~/Library/Application Support/tqLLM-Control-Center/`。

## 11. 故障排查

| 现象 | 处理 |
|---|---|
| 首页「未连接」 | 服务未启动或端口不符；点全局启动或检查 API 页端口 |
| 「端口被其他程序占用」 | 更换端口或停止占用程序；本应用不会误杀 |
| 「外置硬盘无响应」 | USB 硬盘深度休眠唤醒可能需要数分钟；等待或重新挂载 |
| 启动超时 | 查看运行日志页错误筛选；模型加载失败常见于文件缺失 / 内存不足 |
| QSA 判定「差异不显著」 | 上下文刚过阈值或草稿解码占主导；加长上下文或关闭草稿重测 |