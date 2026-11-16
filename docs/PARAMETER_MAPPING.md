# tqLLM Control Center — CLI / API 参数映射与兼容性说明

核验日期：2026-11-16 · 本机实测 + tqllm 1.6.0 wheel 源码（`tqllm/cli.py`）+ `tqserve --help / --list-kv / --list-flags` + 官网 docs（https://tqllm.com/docs.html）

## 0. 本机环境核验结果

| 项目 | 结果 |
|---|---|
| 系统 | macOS 27.0.1 (26A434)，Apple M5 Pro，48 GB 统一内存 |
| CLI | `~/.tqllm/venv/bin/tqllm` 存在；`--help` 正常 |
| 版本 | tqllm **1.6.0**（wheel `tqllm-1.6.0-py3-none-macosx_26_0_arm64.whl`），引擎 build `933dc6f8`（历史日志） |
| 引擎二进制 | `…/venv/lib/python3.12/site-packages/tqllm/bin/tqserve`（Mach-O arm64） |
| 主模型 | `/Volumes/移动硬盘/AI-Models/Qwen3.8-27B-QSA/Qwen3.8-27B-TQ_L-QSA.gguf`（14.8 GB，GGUF v3，946 tensors） |
| 主模型能力 | arch `qwen35`；训练上下文 262144；**含 QSA 索引**（`qwen35.qsa.budget=2048 / block_size=4 / indexer_heads=4 / indexer_head_dim=128 / rope_dim=64`，无 `qsa.sparse_from` → Metal 默认阈值 49152）；**含 MTP 头**（`nextn_predict_layers=1`）；量化 file_type 15（TQ4 系） |
| 草稿模型 | `~/.cache/tqllm/models/Qwen3.8-27B-DFlash2-MLX-4bit.gguf`（1.27 GB，arch `dflash`，DFlash2，与主模型同词表 248320） |
| 外置盘其他目录 | `Flint-40B-Q4`（llama.cpp UD-Q4_K_XL，非 tqLLM TQ 格式，不保证兼容）、`Flint-DFlash2`（safetensors，**不能**直接作 `-md`，`-md` 要求 GGUF） |
| 状态目录 | `~/.cache/tqllm/`（`server.log`、`server.pid`；`TQLLM_HOME` 可覆盖） |
| 默认端口 | 8086 |
| 当前进程 | 核验时无 tqllm/tqserve 进程 |

### 关键 CLI 语义（来自 cli.py 源码）

- `tqllm --version` **不是有效命令**：无命令/未知选项会落入 `serve`，首次运行自动下载模型。本应用绝不调用裸 `--version`；版本从 wheel 文件名/dist-info 读取。
- `tqllm serve [tqserve 选项…]`：后台启动 tqserve（`start_new_session`），写 `server.pid`，日志追加到 `server.log`，等待 `/health` 就绪后返回。
- **同时传 `--model <本地路径>` 与 `-md <本地路径>` 可完全避免下载**（cli.py `serve_args`：给了 `--model` 仍会补默认 drafter，除非显式 `-md`）。
- `--qsa` 只是 CLI 的模型选择提示，会被剥掉；**真正的 QSA 开关是 tqserve 的 `--qsa-from N|off`**。
- `tqllm stop`：对 `server.pid` 记录的进程组发 SIGTERM（`os.killpg`），只停 tqllm 启动的服务；无 pid 文件时报 "no server started by tqllm"。
- 未给 `--context` 时 CLI 补 65536（tqserve 自身默认 2048）。
- 端口被其他程序占用时 `ensure_server` 直接复用并提示，不会误杀。

## 1. 参数映射表

级别：🚀 启动级（改后需重启） · 📨 请求级（API body） · 🔁 运行时可改（admin API）

| UI 控件 | tqserve 参数 / API | 级别 | 取值范围 / 默认 | 生效验证 |
|---|---|---|---|---|
| 服务 启动/停止/重启 | `tqllm serve …` / `tqllm stop` | 🚀 | — | `/health` 200 + `server.pid` 进程存活 |
| CLI 路径 | 应用设置 `cliPath` | — | 本机已核验路径 | 文件存在 + `--help` 退出码 0 |
| 登录自动启动 | macOS `SMAppService.mainApp` | — | 开/关 | `SMAppService.status` |
| 主模型选择 | `--model FILE` | 🚀 | 本地 GGUF 路径 | 启动日志 `loading model from …` + `/v1/models` |
| 模型显示名 | `--name NAME` | 🚀 | 字符串 | `/v1/models` id |
| 草稿模型 | `-md FILE` | 🚀 | DFlash2 GGUF | 启动日志 `MLX backend, drafter …` |
| 推测解码模式 DFlash2 | `-md` + `--draft-max` | 🚀 | — | 日志 drafter 行 + snapshot `drafted>0` |
| 推测解码模式 MTP | `--mtp`（要求 `--np 1`，不能与 `-md` 同用） | 🚀 | **本机 MLX 后端不可用**（见 §4） | — |
| 推测解码 关闭 | 不传 `-md`/`--mtp` | 🚀 | **本机 MLX 后端不可用**（见 §4） | — |
| Draft Max | `--draft-max N` | 🚀 | 默认 DFlash2=7 | 启动参数回显 + 接受率统计 |
| Tree Verification | 默认开；`--no-tree` 关 | 🚀 | 开/关 | 启动参数预览 |
| QSA 开关 | `--qsa-from off`（关）/ 省略或 `--qsa-from N`（开） | 🚀 | Metal 默认=文件值，否则 49152 | 模型含 `qwen35.qsa.*` + 启动参数 + 长上下文 A/B |
| QSA 触发阈值 | `--qsa-from N` | 🚀 | **N≥4096** 或 off | 同上；上下文超过 N 后稀疏注意力生效 |
| Context 长度 | `--context N` | 🚀 | 模型上限 262144；memory fit 可能下调 | `/health` 的 `context` + 日志 `listening … context=` + fit 行 |
| KV Cache 精度 | `--kv FORMAT`（或 `-ctk/-ctv`） | 🚀 | bf16（默认）/ q8 / q4 / tq3 / t4kv / tcq3 / tcq2 等（`--list-kv` 为 store 列表） | 日志 `KV format …` + `/health.fit` |
| Prompt Cache | `--prompt-cache on\|off` | 🚀 | 默认 off；单槽 | 启动参数 + 重复前缀请求 `cached_tokens` |
| Memory Fit | `-fit on\|off`（辅以 `-fitt`/`-fitc`/`-fitl`） | 🚀 | 默认 on | 日志 `fit: …` 行 + `/health.fit` |
| Temperature | 启动默认 `--temperature T`；请求 `temperature` | 🚀+📨 | 0–2 | 请求预览 JSON |
| Top-p | `--top-p P` / 请求 `top_p` | 🚀+📨 | 0–1 | 同上 |
| Top-k | `--top-k K` / 请求 `top_k` | 🚀+📨 | 0–INT_MAX（采样至多 16 候选） | 同上 |
| Max Tokens | `--max-tokens N` / 请求 `max_tokens` | 🚀+📨 | 默认 512（tqserve） | 响应 `usage.completion_tokens` |
| 思考模式 | 启动 `--reasoning on\|off`；请求 `chat_template_kwargs.enable_thinking` | 🚀+📨 | 模板支持 low/medium/xhigh effort | 响应 `reasoning_content` |
| Host | `--host IPv4` | 🚀 | 默认 127.0.0.1；Tailscale 用 0.0.0.0 或 tailscale IP | 日志 `listening on …` |
| Port | `--port N` | 🚀 | 默认 8086 | `/health` |
| API Key | `--api-key-file FILE`（0600，密钥本体存 Keychain） | 🚀 | 可选 | 无 key 请求 401 |
| 并发请求 | `--np N`；运行时 `POST /admin/slots {"slots":k}` | 🚀+🔁 | context 按槽均分；装不下会拒绝启动 | `GET /admin/slots` + snapshot `engine.slots` |
| 实时指标 | `GET /api/monitor/v1/snapshot`（Bearer） | 只读 | schema v1 | 见 §2 |
| 健康检查 | `GET /health` | 只读 | `{status,engine,context,fit}` | — |
| 性能计时 | 响应 `timings{prompt_n,prompt_ms,prompt_per_second,predicted_n,predicted_ms,predicted_per_second,draft_n,draft_n_accepted}` | 只读 | — | 基准测试直接采用 |

## 2. 监控快照 schema（从 tqserve 内嵌 monitor 页面逆向核验）

```
GET /api/monitor/v1/snapshot
{
  schema_version: 1, instance_id,
  engine: { model, host, build, slots, context_per_slot, device_id },
  hardware: { gpu_used_bytes, gpu_total_bytes, ram_used_bytes, ram_total_bytes,
              cpu_percent, gpu_percent, gpu_celsius, gpu_watts, sample_age_ms, device_name },
  requests: [ { id, phase(queued|prefill|decode|complete|failed|cancelled),
                prompt_tokens, output_tokens, context_tokens, prefill_processed_tokens,
                first_output_ms,            // TTFT
                prefill_tokens_per_second,  // 不含缓存命中
                decode_tokens_per_second,
                elapsed_ms, drafted, accepted } ]
}
```

首页五项指标来源：Decode=活动 decode 请求速率和；Prefill=最近 prefill 速率；TTFT=最近请求 `first_output_ms`；Context=`engine.context_per_slot`；Memory=`hardware.gpu_used_bytes`（统一内存）。无数据一律显示 `—`。

## 3. QSA 生效判定链（不伪造）

1. **模型能力**：GGUF 元数据含 `qwen35.qsa.*` 且张量含 `qsa_q.weight` 等 → 兼容；否则 UI 禁用开关并说明。
2. **启动参数**：最终命令含 `--qsa-from N`（或默认）且非 off；应用保存并回显实际 argv。
3. **运行触发**：请求上下文 > 阈值后稀疏注意力才参与。验证方式：
   - 同条件长上下文 A/B（on vs off）decode 速率差异；
   - 可选诊断 `TQLLM_DEBUG=qsa_mass:N` 输出稀疏选择占 dense 注意力比例（日志证据）。
4. UI 分三态显示：已配置 / 已加载 / 实际触发（后者需要测试证据）。

## 4. 明确不支持 / 限制

- `tqllm --version` 不存在（会触发 serve+下载）→ 版本读 dist-info。
- `-md` 只接受 GGUF；外置盘 `Flint-DFlash2` 为 safetensors，不能直接用作草稿。
- `Flint-40B-Q4` 为 llama.cpp UD 量化，非 tqLLM TQ 格式，本应用标记"未验证兼容"，不默认加载。
- `--mtp` 与 `-md` 互斥，且要求 `--np 1`、文本模式。
- **Apple Silicon MLX 后端强制 DFlash2 草稿**（实测 tqserve 报 `the MLX backend needs the DFlash2 drafter (-md DRAFTER.gguf)`）：
  无草稿（不传 `-md`）与 MTP（`--mtp` 排除 `-md`）在此后端**均无法启动**。
  因此 UI 将「关闭」「MTP」两档禁用并标注不可用，仅 DFlash2 可选——不做假开关。
  `tqllm` CLI 之所以在给定 `--model` 时自动补默认草稿，正是为了满足该后端约束。
- **适配层直接托管 tqserve**（不经 `tqllm serve`）：CLI 的自动补草稿行为会使「关闭」档失真，
  故应用直接调用引擎二进制 `…/site-packages/tqllm/bin/tqserve`，argv 完全由 UI 配置决定；
  分离启动复用官方机制（venv Python `Popen(start_new_session=True)` + 写 `server.pid` + 追加 `server.log`），
  停止仍用官方 `tqllm stop`（按 pid 文件 killpg），所有权判定不变。
- QSA 阈值最小 4096；非 QSA 模型传 `--qsa-from` 无效（引擎按模型能力决定）。
- KV 精度、context、np 等启动级参数改动必须重启；应用以"需要重启"徽标提示并提供安全重启。
- Prompt Cache 仅单槽；`--kv-compact` 非精确（本应用不暴露）。
- 采样参数（temperature/top_p/top_k/max_tokens/思考）优先走请求级，不重启。
- 停止只通过 `tqllm stop`（pid 文件 + killpg）；外部终端启动的服务需用户确认，绝不 pkill 同名进程。
- API Key 存 macOS Keychain；命令行用 `--api-key-file`，避免出现在 `ps` 与日志。

## 5. 本机运行时实测观察（2026-11-16）

- **Memory Fit 自动降级**：请求 125,515 tokens 时日志出现
  `WARN --exact on: KV forced to int8 by memory for this request` 与 `KV format int8 for 125515 prompt + 128 new tokens (in use 17.6 GB, usable working set 32.3 GB)`。
  即设置 bf16 时，fit 仍可能按请求长度临时降级 KV；应用「设置值 vs 实际加载值」面板与日志页如实展示。
- **繁忙拒绝连接**：长上下文 prefill 期间 `/health` 等端点可能返回 `{"error":{"message":"too many connections"}}`。
  这是引擎在重负载下的正常行为，**不代表服务停止**；应用区分 HTTP 响应（繁忙）与连接拒绝（停止），
  繁忙时首页显示「服务繁忙 · 遥测暂不可用」而非误报停止。
- **Metal 版 hardware 遥测为 null**：snapshot 的 gpu/ram/温度/功耗字段不可用；
  内存指标改用引擎进程 `proc_pid_rusage(RUSAGE_INFO_V4).ri_phys_footprint`（实测空闲 ~16.8 GB，125K 请求 ~25.5 GB resident，与日志一致）。
- **QSA 收益与上下文长度强相关**：60K（刚过 49152 阈值）实测开 40.2 / 关 47.0 tok/s（0.86x，索引开销占主导）；
  120K 级对照见测试报告 §5.2。应用判定逻辑对「开反而更慢」如实报告，不伪造加速。
- **USB 外置盘深度休眠**：唤醒耗时可达 12 分钟；期间所有 stat 后台化 + 超时，GUI 不冻结。