import SwiftUI

struct QSAView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: ConfigStore
    @EnvironmentObject var engine: EngineController
    @EnvironmentObject var scanner: ModelScanner
    @EnvironmentObject var bench: BenchmarkService
    @EnvironmentObject var monitor: MonitorService

    var qsaCapable: Bool { model.qsaCapable }
    var loadedQSA: Bool {
        engine.isRunning && engine.launchedArguments.contains("--qsa-from") &&
        !engine.launchedArguments.contains("off")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DetailHead(title: "QSA 加速", subtitle: "区分已配置、已加载与实际触发三个状态；开关不等于生效。", onBack: { model.go(.home) })
            DetailBody {
                Panel(title: "稀疏注意力配置") {
                    SwitchRow(title: "QSA 加速", desc: qsaCapable ? "映射到 tqserve --qsa-from（启动级）。" : "当前主模型不含 QSA 索引，开关不可用。",
                              isOn: $store.config.qsaEnabled, disabled: !qsaCapable)
                    ChoiceRow(title: "QSA 触发阈值（--qsa-from，最小 4096）",
                              options: [(32768, "32K"), (49152, "48K"), (65536, "64K"), (98304, "96K")],
                              selection: $store.config.qsaFrom,
                              desc: "上下文超过阈值后稀疏注意力才参与；Metal 默认取文件值，否则 49152。")
                    NoteBox(text: "超过阈值不代表一定加速。模型索引、启动参数和实际上下文都必须满足条件；下方“生效验证”用真实长上下文请求检验。", warn: true)
                    HStack(spacing: 10) {
                        ActionButton(label: "查看性能对照 →", icon: .activity) { model.go(.performance) }
                        RestartBadge()
                    }
                }
                Panel(title: "生效验证（真实请求）") {
                    NoteBox(text: "QSA A/B 对照：固定同一长文档（约 2× 阈值 tokens，确保充分越过阈值）、temperature=0、输出上限 128，分别在 --qsa-from \(store.config.qsaFrom) 与 off 下重启引擎各跑多轮，比较 decode 中位速度并给出判定。全程约 20–40 分钟。刚过阈值时稀疏索引开销可能占主导（实测 60K 时开反而略慢），更长上下文才能体现收益。")
                    HStack(spacing: 10) {
                        ActionButton(label: bench.running ? "测试进行中…" : "运行 QSA A/B 对照", icon: .play, primary: true, disabled: bench.running || !qsaCapable) {
                            Task { await bench.runQSAAB(store: store, engine: engine, scanner: scanner, rounds: 2, targetTokens: store.config.qsaFrom * 2 + 8192) }
                        }
                        if bench.running {
                            ActionButton(label: "取消") { bench.cancel() }
                        }
                    }
                    if bench.running {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: bench.progressFraction)
                                .tint(Theme.green)
                            Text(bench.progress).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                        }
                    }
                    if let err = bench.lastError {
                        NoteBox(text: err, warn: true)
                    }
                    if let latest = bench.reports.first(where: { $0.promptKind == "long-ab" }), let v = latest.qsaVerdict {
                        NoteBox(text: "最近判定（\(latest.at.formatted(date: .abbreviated, time: .shortened))）：\(v)")
                    }
                }
            } right: {
                Panel(title: "生效前检查") {
                    DataRow(name: "主模型 QSA 索引", value: qsaCapable ? "✓ 已验证（GGUF qsa.* + 张量）" : "✗ 不兼容")
                    DataRow(name: "QSA 运行时设置", value: store.config.qsaEnabled ? "已配置：开" : "已配置：关")
                    DataRow(name: "触发阈值", value: "\(store.config.qsaFrom) Tokens")
                    DataRow(name: "启动参数已加载", value: loadedQSA ? "✓ --qsa-from \(store.config.qsaFrom)" : (engine.isRunning ? "✗ 当前服务未带 QSA 参数" : "服务未运行"))
                    DataRow(name: "长上下文实际命中", value: triggerEvidence)
                    DataRow(name: "当前上下文", value: monitor.requestHistory.first?.context_tokens.map { "\($0)" } ?? "—")
                }
                Panel(title: "实际启动参数") {
                    MonoBlock(text: engine.launchedArguments.isEmpty ? "尚未由本应用启动。" : engine.launchedArguments.joined(separator: " "))
                }
                Panel(title: "注意") {
                    NoteBox(text: "QSA 属于稀疏近似注意力。本界面严格区分：已配置（UI）、已加载（启动参数）、实际触发（长上下文测试证据）。非 QSA 模型传 --qsa-from 无效。")
                }
            }
        }
    }

    var triggerEvidence: String {
        if let r = bench.reports.first(where: { $0.promptKind == "long-ab" }), let v = r.qsaVerdict {
            if v.contains("生效") { return "✓ A/B 实测加速" }
            if v.contains("未触发") { return "✗ 上下文不足" }
            return "已测试 · 见判定"
        }
        return "待测试"
    }
}

struct DraftView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: ConfigStore
    @EnvironmentObject var engine: EngineController
    @EnvironmentObject var monitor: MonitorService
    @EnvironmentObject var scanner: ModelScanner
    @EnvironmentObject var bench: BenchmarkService

    var mtpCapable: Bool {
        scanner.models.first { $0.path == store.config.modelFile }?.info.mtpCapable ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DetailHead(title: "推测解码", subtitle: "本机 MLX 后端仅支持 DFlash2 精确推测解码；输出与无草稿逐 token 一致（exact）。", onBack: { model.go(.home) })
            DetailBody {
                Panel(title: "解码方式") {
                    ChoiceRow(title: "推测解码模式",
                              options: [(EngineConfig.DraftMode.dflash2, "DFlash2"), (.mtp, "MTP"), (.off, "关闭")],
                              selection: $store.config.draftMode,
                              desc: "本机为 Apple Silicon MLX 后端，仅 DFlash2 可用。",
                              disabled: [.mtp, .off])
                    NoteBox(text: "引擎限制（实测）：tqserve 在 MLX 后端启动时报「the MLX backend needs the DFlash2 drafter (-md DRAFTER.gguf)」，即必须加载 DFlash2 草稿。因此「关闭」（无 -md）与「MTP」（--mtp 排除 -md）在此后端不可用，已禁用，不做假开关。DFlash2 为精确推测解码，输出与无草稿逐 token 一致。", warn: true)
                    StyledNumberField(label: "Draft Max · 草稿 Tokens 上限（--draft-max）", value: $store.config.draftMax,
                                      hint: "DFlash2 默认 7。调大不一定更快，取决于接受率与验证开销。")
                    SwitchRow(title: "Tree Verification", desc: "默认开；关闭映射到 --no-tree（链式验证）。启动级。", isOn: $store.config.treeVerify)
                    HStack { RestartBadge() }
                }
                Panel(title: "草稿模型关联") {
                    StyledTextField(label: "草稿模型文件（-md）", text: $store.config.draftFile, mono: true)
                    DataRow(name: "草稿架构", value: scanner.models.first { $0.path == store.config.draftFile }?.info.architecture ?? "未扫描")
                    DataRow(name: "接受率（实时）", value: monitor.acceptance.map { String(format: "%.1f%%", $0) } ?? "尚无测量")
                    DataRow(name: "已草稿 / 已接受", value: monitor.draftedTotal > 0 ? "\(monitor.draftedTotal) / \(monitor.acceptedTotal)" : "尚无测量")
                    DataRow(name: "最近含草稿请求速率", value: speedupText)
                    NoteBox(text: "加速收益说明：MLX 后端强制 DFlash2，无法建立「无草稿」基线，故 DFlash2 vs 无草稿对照在此后端不可行。收益以草稿接受率与实时 decode 速率呈现；短上下文基准（DFlash2）实测 decode 中位约 50 tok/s。")
                }
            } right: {
                Panel(title: "运行状态") {
                    DataRow(name: "当前服务草稿", value: engine.isRunning ? (engine.launchedArguments.contains("-md") ? "DFlash2（-md）" : (engine.launchedArguments.contains("--mtp") ? "MTP" : (monitor.draftedTotal > 0 ? "DFlash2（运行中）" : "见引擎日志"))) : "服务未运行")
                    DataRow(name: "引擎日志", value: engine.isRunning ? "见运行日志 drafter 行" : "—")
                    NoteBox(text: "接受率与草稿数来自 /api/monitor/v1/snapshot 的 drafted/accepted 字段，无请求时显示“尚无测量”。")
                }
                Panel(title: "调参原则") {
                    NoteBox(text: "调大 Draft Max 不一定更快；真实速度取决于草稿接受率、验证开销、上下文长度及模型兼容性。基准测试页可在固定条件下比较。")
                }
            }
        }
    }

    var speedupText: String {
        // 优先用推测解码收益对照报告：DFlash2 臂 vs 无草稿基线臂的中位 decode 比值
        if let r = bench.reports.first(where: { $0.name.contains("推测解码收益") }), r.arms.count == 2 {
            let d = r.arms[0].medianDecode, b = r.arms[1].medianDecode
            if b > 0 {
                return String(format: "%.2fx（%@ %.1f / %@ %.1f tok/s）", d / b, r.arms[0].name, d, r.arms[1].name, b)
            }
        }
        guard let r = monitor.requestHistory.first(where: { ($0.drafted ?? 0) > 0 }),
              let rate = r.decode_tokens_per_second else { return "尚无测量（发起请求后显示）" }
        return String(format: "%.1f tok/s", rate)
    }
}