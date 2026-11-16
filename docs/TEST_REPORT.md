# tqLLM Control Center — 测试报告

测试日期：2026-11-16 · 设备：Mac mini（Apple M5 Pro / 48 GB / macOS 27.0.1）
引擎：tqllm 1.6.0（tqserve build 933dc6f8）· 模型：Qwen3.8-27B-TQ_L-QSA.gguf（13.8 GB，外置 USB 硬盘）
草稿：Qwen3.8-27B-DFlash2-MLX-4bit.gguf（1.2 GB）

## 1. 环境核验

| 项 | 结果 |
|---|---|
| CLI 路径 / 可执行 | `~/.tqllm/venv/bin/tqllm` ✓ |
| 版本 | 1.6.0（dist-info 读取；CLI 无 `--version` 命令，裸调用会触发 serve+下载，已规避） |
| `tqllm --help` / `tqserve --help / --list-kv / --list-flags` | ✓ 全部实测，输出存 `research/` |
| 主模型 GGUF | qwen35，946 tensors，ctx 262144，**QSA 索引 ✓**（qsa.budget/block_size/indexer_heads…+ qsa_* 张量），**MTP 头 ✓**（nextn_predict_layers=1） |
| 草稿 GGUF | dflash 架构，DFlash2，词表 248320 与主模型一致 ✓ |
| 外置盘其他模型 | Flint-40B-Q4（llama.cpp UD 量化，标记未验证兼容）；Flint-DFlash2（safetensors，不能作 `-md`） |
| 初始进程 | 无 tqllm/tqserve 残留 |

**事故与处理**：核验初期误触 `tqllm --version` 触发默认模型下载，立即终止进程并删除本次产生的 incomplete 临时文件；已有模型与草稿未受影响。此后所有启动均显式传 `--model` + `-md` 本地路径，零下载。

## 2. 构建与安装

- Swift 6.4（CommandLineTools，无完整 Xcode）。CLT 缺 `SwiftUIMacros` 插件 → `@State` 按 SwiftUI 语义手动展开；构建脚本处理模块缓存与沙箱限制。
- `./make_app.sh` → `build/tqLLM Control Center.app`（ad-hoc 签名，`codesign --verify` 通过）。
- 已安装 `/Applications/tqLLM Control Center.app`，`open` 启动正常（等价 Finder 双击）。
- 无显示器 / 无录屏权限环境：截图用应用内 `ImageRenderer` 离屏渲染（`--render` 模式），全部 11 个页面产出真实截图，见 `build/screenshots-live/`。

## 3. 服务控制（真实启停）

| 测试 | 结果 |
|---|---|
| CLI 路径启动（`tqllmctl start`，与 GUI 同一 EngineController） | ✓ 42s 就绪；argv 含 `--qsa-from 49152 -md … --kv bf16 --context 131072` |
| 启动方式 | **直接托管 tqserve**（venv Python 分离启动 + server.pid + server.log），argv 完全由 UI 决定；不经 `tqllm serve`（避免其自动补草稿） |
| 所有权判定 | 本应用启动 pid 记录 ✓；其他进程启动识别为「外部终端（tqllm CLI）启动」✓ |
| 停止 | 只走 `tqllm stop`（pid 文件 + killpg），端口释放 ✓；无 pkill |
| GUI 全局开关 | 分布式通知钩子触发与按钮相同的 `globalToggle()` 代码路径（见 §8） |
| 应用退出后服务继续 | 默认 stopOnQuit=false，退出 GUI 后引擎继续运行 ✓（见 §8） |
| 端口占用 / 模型缺失 / 磁盘无响应 | preflight 阻止启动并给出明确提示 ✓（磁盘 stat 8s 超时，主线程不阻塞） |

**外置盘深度休眠实测**：USB 硬盘休眠后 `ls` 模型目录耗时 **12 分 12 秒** 才返回（SMART Verified）。
应用在此期间的表现：主线程保持响应（扫描/探测全部后台化），页面显示「磁盘无响应」，启动被 preflight 阻止；磁盘唤醒后自动恢复。

## 4. 短上下文基准（3 轮，固定 prompt / temperature=0 / max_tokens=256 / 思考关）

| 轮 | prompt | 输出 | TTFT | Prefill tok/s | Decode tok/s | 草稿接受 |
|---|---|---|---|---|---|---|
| 1（冷启动含 ANE 预热） | 34 | 228 | 6559 ms | 5.2 | 34.4 | 173/825 |
| 2 | 34 | 228 | 217 ms | 156.8 | 49.8 | 173/825 |
| 3 | 34 | 228 | 217 ms | 156.7 | 49.7 | 173/825 |

Decode 中位 **49.7 tok/s**（DFlash2，draft-max 7，tree 开）。计时来自服务端 `timings`。
报告持久化：`~/Library/Application Support/tqLLM-Control-Center/benchmarks/`。

## 5. QSA A/B 对照（长上下文，真实触发验证）

条件：同一确定性长文档，temperature=0、top_p=1、top_k=1、max_tokens=128、思考关；
两臂仅 `--qsa-from 49152` vs `off`，每臂重启引擎，预热 1 轮 + 正式 2 轮；计时来自服务端 timings。

> 首轮运行因 prompt 估算不足（42,565 tokens < 阈值）被判定链正确识别为「未触发、结果无效」；
> 校准字符/token 比并加入「预热未达阈值自动加长」保险后重跑。

### 5.1 第一轮：60K 上下文（刚过阈值，实际 59,995 tokens）

| 臂 | 轮 | prompt | 输出 | TTFT | Prefill tok/s | Decode tok/s | 草稿接受 |
|---|---|---|---|---|---|---|---|
| QSA 开（49152） | 1 | 59995 | 30 | 152,987 ms | 392.2 | 39.8 | 24/90 |
| QSA 开（49152） | 2 | 59995 | 30 | 154,852 ms | 387.4 | 40.6 | 24/90 |
| QSA 关（off） | 1 | 59995 | 30 | 145,336 ms | 412.8 | 46.9 | 25/75 |
| QSA 关（off） | 2 | 59995 | 30 | 145,581 ms | 412.1 | 47.1 | 25/75 |

中位：开 40.2 tok/s / 关 47.0 tok/s，比值 **0.86x**。
判定（应用自动生成）：「上下文 59995 > 阈值 49152，QSA 触发条件满足。开反而更慢，需检查阈值与上下文。」

**解读**：60K 仅比阈值多 ~11K tokens，稀疏索引（indexer）计算开销超过被跳过注意力的收益，
且 DFlash2 树验证放大了每步开销。这与 QSA「长上下文才受益」的设计一致（官方宣称收益在 200K 级）。
应用如实报告了该结果，未伪造加速。

### 5.2 第二轮：120K 上下文（目标 120,000，实际 125,515 tokens）——条件漂移，作废

预热与第 1 轮 KV 被 Memory Fit 强制为 int8（`WARN --exact on: KV forced to int8 by memory`），
第 2 轮又回到 bf16（系统内存压力波动导致 usable working set 32.3→34.5 GB 变化）。
**两臂/各轮 KV 不一致违反固定条件原则，本轮结果作废**（未纳入判定）。

修复：A/B 加入 **KV 一致性守卫**——每轮结束后读取引擎日志的实际 `KV format`，
与预热轮不一致即中止该臂并明确报错，绝不产出混淆条件的对照数据。

### 5.3 第三轮：100K 上下文（目标 96,000，实际 100,315 tokens）——守卫拦截，作废

预热轮 KV 为 int8 (lean prefill)，第 1 轮漂移为 bf16 → **KV 一致性守卫按设计中止本臂**，
报错「Memory Fit 改变了实验条件」，未产出无效对照。

### 5.4 第四轮：100K 上下文，两臂显式固定 --kv q8（int8）——有效

修复：A/B 两臂显式 `--kv q8`，排除 Memory Fit 漂移；守卫逐轮校验。
本机内存充足时 fit 将 q8 升级为 bf16，**六轮请求实际 KV 全程 bf16 一致**（守卫通过），条件有效。
实际 prompt **100,315 tokens**（> 阈值 49,152，稀疏占比 ~51%）。

| 臂 | 轮 | prompt | 输出 | TTFT | Prefill tok/s | Decode tok/s | 草稿接受 |
|---|---|---|---|---|---|---|---|
| QSA 开（49152） | 1 | 100315 | 30 | 319,885 ms | 313.6 | 40.6 | 24/90 |
| QSA 开（49152） | 2 | 100315 | 30 | 321,719 ms | 311.8 | 40.2 | 24/90 |
| QSA 关（off） | 1 | 100315 | 30 | 324,066 ms | 309.6 | 41.1 | 25/75 |
| QSA 关（off） | 2 | 100315 | 30 | 300,876 ms | 333.4 | 39.4 | 25/75 |

中位：开 **40.4** / 关 **40.3** tok/s，比值 **1.00x**。
判定（应用自动生成）：「上下文 100315 > 阈值 49152，QSA 触发条件满足。差异不显著（<5%）。」

**综合解读（60K + 100K 两轮）**：
- 60K（刚过阈值，稀疏占比 18%）：开 40.2 / 关 47.0 = **0.86x**，开反而慢——稀疏索引（indexer）开销超过被跳过注意力的收益。
  这一**可复现的差异证明 QSA 确实参与了计算**（若被忽略则两臂应完全相同）。
- 100K（稀疏占比 51%）：开 40.4 / 关 40.3 = **1.00x**，开销与收益打平。
- 原因：本模型为 qwen35 **混合注意力架构**（`full_attention_interval=4`，65 层中仅 ~16 层全注意力，其余为线性注意力/SSM），
  decode 瓶颈不在被 QSA 稀疏化的全注意力层；叠加 DFlash2 树验证 amortize 了注意力成本。
  故在 60K–100K 区间、本硬件（M5 Pro / MLX）上 QSA 净收益≈0。官方宣称的 3.2x@200K 为 CUDA 平台数据，未在本机复现。
- **结论**：QSA 配置正确加载、触发条件满足、确实参与计算（三级验证链全部通过）；
  但在本机/本模型/60K–100K 区间**未测得净加速**。应用如实报告，未伪造加速。更长上下文（200K+）可能显现收益，
  受内存与 KV 漂移限制未在本轮验证。

## 5bis. 推测解码收益对照——本机后端不可行（如实披露）

尝试 DFlash2 vs 无草稿基线对照时发现：**Apple Silicon MLX 后端强制要求 DFlash2 草稿**
（tqserve 启动报 `the MLX backend needs the DFlash2 drafter (-md DRAFTER.gguf)`），无草稿臂无法启动。
首轮对照中无草稿臂实际仍带草稿（CLI 自动补草稿所致），1.03x 结果**作废**。

处理：
- 适配层改为**直接托管 tqserve**（绕过 CLI 的自动补草稿），使「关闭」档真正不传 `-md`——实测此时引擎拒绝启动，证实后端约束。
- UI 将「关闭」「MTP」两档**禁用并标注不可用**（不做假开关），仅 DFlash2 可选；「性能基准测试」预设改用 DFlash2 基线。
- 加速收益改以**草稿接受率（实测 21%）+ 实时 decode 速率**呈现；DFlash2 短上下文基准 decode 中位 ~50 tok/s。
- DFlash2 为精确推测解码（exact），输出与无草稿逐 token 一致，接受率 21% 表示多数草稿被拒、收益有限，与混合架构一致。

## 6. 监控与指标真实性

- `/api/monitor/v1/snapshot` schema v1 实测：engine/requests 字段齐全；**Metal 版 hardware 采样全为 null**。
- Memory 指标改用引擎进程 `proc_pid_rusage` 的 `ri_phys_footprint`（真实统一内存占用）：空闲 ~16.8 GB，60K 上下文请求期间 ~26.9 GB，与日志 `in use 17.6 GB / request keeps …` 量级一致。
- 无请求时 Decode 显示 `—`，不伪造数值 ✓。
- 请求历史持久化 `performance-history.json` ✓。

## 7. 页面与视觉

- 11 个页面（首页 + 10 功能页）全部可打开（渲染截图 + 导航钩子状态验证）。
- 视觉对齐原型：浅灰 #F3F4F5 背景、白色 24px 圆角卡片、#E7E9EC 描边、深灰文字、线性图标、双列功能入口、底部保留原型文案。
- 首页顶部为运行状态面板 + 全局启停（按规格 v2.1 调整）。
- 截图：`build/screenshots-live/01-home.png … 11-presets.png`。

## 8. GUI 交互验收（无辅助功能权限环境的替代方案）

System Events 辅助功能被系统拒绝（-10004），无法脚本点击原生按钮。
改用应用内分布式通知测试钩子，触发与 UI 按钮**完全相同**的代码路径
（`TopBar Button → AppModel.globalToggle()`、页面路由 `PageSwitch`、`ConfigStore` 预设/登录项方法），
状态写入 `gui-state.json` 作为证据。实测记录（2026-11-16）：

| 测试 | 操作 | 证据 |
|---|---|---|
| GUI 全局启动 | 引擎停止态发 `ui-toggle` | 60s 后 `engine_state=运行中, ownership=本应用启动, pid=61618`；改直接托管 tqserve 后复测 `pid=72475, ownership=本应用启动` ✓ |
| GUI 全局停止 | 运行态（本应用所有）再发 `ui-toggle` | `engine_state=已停止, ownership=—, pid=0`（无需确认弹窗，符合所有权语义） |
| 外部服务停止确认 | CLI 启动的服务在 GUI 中识别 | `ownership=外部终端（tqllm CLI）启动`；停止路径含 NSAlert 确认（代码审查 + CLI confirmedExternal 实测） |
| 页面导航 | `ui-nav models` | `gui-state.json page=models`；11 页离屏渲染全部产出 |
| 登录自动启动 | `ui-autostart on` → `off` | `gui-state.json autostart_status: "已注册（登录时启动）" → "未注册"`（SMAppService.mainApp 真实系统状态） |
| 预设保存 | `ui-preset save` | `presets.json` 出现「验收测试预设」（context 131072 / kv bf16），重启后仍在 |
| 配置持久化 | 多次重启应用 | `config.json` 字段完整保留（cliPath/modelDir/modelFile/draftFile/采样/端口等） |
| 报告持久化 | 基准后重启 | `benchmarks/bench-*.json` 可被 GUI/CLI 重新加载（修复了日期编解码不一致 bug） |

**缺陷修复记录**：
1. GGUF 解析器逐字节 read 导致扫描卡死 → 1MB 缓冲读取。
2. 外置盘 stat 在主线程阻塞（USB 深度休眠 12 分钟）→ 全部磁盘探测后台化 + 8s 超时缓存。
3. `tailscale ip` 子进程在视图 body 中同步执行导致渲染崩溃 → 异步探测缓存。
4. ImageRenderer 不绘制 ScrollView/TextField（AppKit 桥接）→ 渲染模式纯 SwiftUI 等价呈现。
5. 基准报告 save 用 ISO8601 编码、load 用默认解码 → 统一 ISO8601。
6. `@State` 宏插件缺失（CLT 环境）→ 按 SwiftUI 语义手动展开。
7. **CLI 自动补草稿导致「关闭」档失真**：`tqllm serve --model X` 总被 cli.py 注入默认 DFlash2，
   无草稿基线臂实际仍带草稿（1.03x 作废）→ 适配层改为直接托管 tqserve，argv 完全由 UI 决定。
8. **MLX 后端强制 DFlash2**：直接托管后实测无草稿/MTP 均被引擎拒绝启动 → UI 禁用这两档并标注，
   预设基线改 DFlash2，收益统计改用接受率+实时速率（如实披露后端限制）。
9. **长 prefill 期间引擎拒绝新连接**（`too many connections`）被误判为停止 → 区分 HTTP 响应（繁忙）与连接拒绝（停止），
   繁忙时首页显示「服务繁忙/填充中」而非误报停止。

## 9. 已知限制

- Metal 版 tqserve 不提供 hardware 遥测（gpu/ram/温度/功耗），内存以进程 footprint 替代；CPU/GPU 占用率不显示。
- 无辅助功能权限时无法脚本点击原生按钮；验收以同代码路径钩子 + 离屏渲染截图替代。
- `--mtp` 与 `-md` 互斥、要求 np=1；**本机 MLX 后端强制 DFlash2，MTP 与无草稿均不可用**（已在 UI 禁用并标注）。
- QSA A/B 的 decode 差异受草稿解码与上下文长度影响；判定阈值 ±5% 内记为「差异不显著」。本机 60K–100K 未测得 QSA 净加速（混合注意力架构所致，见 §5.4）。
- 外置 USB 硬盘深度休眠唤醒可达 10+ 分钟，期间启动被阻止（设计行为）。
- Memory Fit 会按请求内存压力动态选择 KV（bf16↔int8），A/B 需显式固定 KV 或加一致性守卫（已实现）。

## 10. 最终验收清单

| 验收项 | 状态 | 证据 |
|---|---|---|
| 可通过 Finder 双击启动 macOS 应用 | ✅ | `/Applications/tqLLM Control Center.app`，`open` 启动正常，ad-hoc 签名 `codesign --verify` 通过 |
| 首页与 HTML 原型视觉风格一致 | ✅ | 浅灰 #F3F4F5 / 白色 24px 圆角卡片 / #E7E9EC 描边 / 双列入口 / 底部原型文案；截图 `build/screenshots-final/01-home.png` |
| 十个功能页面都能正常打开 | ✅ | 11 页离屏渲染全部产出 + `ui-nav` 状态验证 |
| 全局开关真正启停 tqLLM | ✅ | `ui-toggle` 触发 `globalToggle()`：启动 pid 72475 / 停止 pid 0，所有权判定正确 |
| 使用已有模型，不重复下载 | ✅ | 直接引用外置盘 GGUF + 缓存草稿；误触下载已终止并清理；启动 argv 全为本地路径 |
| QSA 设置实际生效并被验证 | ✅ | 三级验证链：GGUF qsa.* + 张量 → argv `--qsa-from` → 100315>49152 触发；A/B 实测（60K 0.86x / 100K 1.00x，如实报告） |
| 推测解码参数正确配置 | ✅ | DFlash2 `-md --draft-max --no-tree` 精确映射；MTP/关闭因 MLX 后端限制禁用并标注（不做假开关） |
| 实时性能数字来自真实数据 | ✅ | snapshot + 服务端 timings + 进程 footprint；无数据显示 — |
| 配置预设持久化保存 | ✅ | config.json / presets.json；`ui-preset save` 验证；JSON 导入导出（不含 Key） |
| 错误、日志、异常状态可查看 | ✅ | server.log 增量 tail + 应用事件 + 筛选/导出/诊断清单；磁盘/端口/繁忙异常均有反馈 |
| 不破坏原有 tqLLM 和其他 AI 软件 | ✅ | venv/模型未改动；停止仅 `tqllm stop`（pid killpg）；未触碰 DSH/Splash 等 |
| 完成真实性能对照测试 | ✅ | 短上下文基准 + QSA 60K/100K A/B（KV 守卫）；报告持久化 + Markdown 导出 |

**交付物**：可运行 .app（已安装）、完整源码（`Sources/` + `SourcesCLI/`）、参数映射（`docs/PARAMETER_MAPPING.md`）、
测试报告（`docs/TEST_REPORT.md`）、使用说明（`docs/USAGE.md`）、真实截图（`build/screenshots-final/`）、构建脚本（`build.sh`/`make_app.sh`/`build_ctl.sh`）。