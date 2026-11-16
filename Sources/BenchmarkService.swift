import Foundation
import SwiftUI

struct BenchRoundResult: Codable, Identifiable {
    var id = UUID()
    var arm: String
    var round: Int
    var promptTokens: Int
    var outputTokens: Int
    var ttftMs: Double          // 服务端 prompt_ms（首 token 前填充耗时）
    var prefillTps: Double
    var decodeTps: Double
    var elapsedMs: Double
    var drafted: Int
    var accepted: Int
    var clientTtftMs: Double?
    var at: Date
}

struct BenchArmResult: Codable, Identifiable {
    var id = UUID()
    var name: String
    var qsaFrom: String        // "49152" / "off"
    var rounds: [BenchRoundResult]
    var medianDecode: Double { median(rounds.map { $0.decodeTps }) }
    var medianPrefill: Double { median(rounds.map { $0.prefillTps }) }
    var medianTTFT: Double { median(rounds.map { $0.ttftMs }) }
    var acceptance: Double {
        let d = rounds.reduce(0) { $0 + $1.drafted }
        let a = rounds.reduce(0) { $0 + $1.accepted }
        return d > 0 ? Double(a) / Double(d) * 100 : 0
    }
    private func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}

struct BenchReport: Codable, Identifiable {
    var id = UUID()
    var name: String
    var at: Date
    var model: String
    var context: Int
    var kv: String
    var draftMode: String
    var promptKind: String
    var targetPromptTokens: Int
    var maxTokens: Int
    var arms: [BenchArmResult]
    var notes: [String]
    var qsaVerdict: String?
}

/// 基准测试与结果持久化层。固定模型/上下文/采样/内容/输出上限，多轮比较。
@MainActor
final class BenchmarkService: ObservableObject {
    @Published var running = false
    @Published var progress: String = ""
    @Published var progressFraction: Double = 0
    @Published var reports: [BenchReport] = []
    @Published var lastError: String?
    @Published var currentRounds: [BenchRoundResult] = []
    private var cancelled = false

    init() { loadReports() }

    func loadReports() {
        let dir = reportsDir()
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601   // 与 save 的 .iso8601 编码一致
        var out: [BenchReport] = []
        for f in files where f.hasSuffix(".json") {
            if let d = try? Data(contentsOf: dir.appendingPathComponent(f)),
               let r = try? dec.decode(BenchReport.self, from: d) {
                out.append(r)
            }
        }
        reports = out.sorted { $0.at > $1.at }
    }

    private func reportsDir() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tqLLM-Control-Center/benchmarks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func cancel() { cancelled = true }

    /// 固定测试内容：确定性段落重复，保证各轮/各臂完全一致。
    static func fixedPrompt(targetTokens: Int) -> String {
        let paragraph = """
        The history of computing is a story of abstraction. From vacuum tubes to transistors, \
        from integrated circuits to modern accelerators, each generation hid more complexity \
        behind simpler interfaces. Engineers learned to trade memory for speed, precision for \
        throughput, and generality for efficiency. A cache is a promise that the recent past \
        predicts the near future. A pipeline is a bet that independent work can overlap. \
        Quantization accepts small errors to move more numbers per second. Speculative decoding \
        drafts an answer and verifies it in one pass, keeping only what the model would have \
        written itself. Sparse attention selects the keys that matter and skips the rest. \
        Every technique is a measured compromise, and every benchmark must name its conditions: \
        the model file, the context length, the sampling parameters, the prompt, and the output cap. \
        Without those conditions a number is marketing, not measurement. With them, a number is \
        a fact that another engineer can reproduce on the same hardware. This paragraph repeats \
        to build a long, stable context for controlled experiments.
        """
        // 实测校准：该文档约 4.6 字符/token（Qwen 词表）；留 20% 余量确保超过阈值
        let charsPerToken = 4.6
        let targetChars = Int(Double(targetTokens) * charsPerToken * 1.2)
        var text = "Below is a long reference document. Read it carefully.\n\n"
        var i = 0
        while text.count < targetChars {
            i += 1
            text += "Section \(i). " + paragraph + "\n\n"
        }
        text += "\nQuestion: In one sentence, what is the main theme of the document above? Answer briefly."
        return text
    }

    static let shortPrompt = "Explain what a hash map is and how collisions are handled. Answer in about 150 words."

    private func runOneRound(api: APIClient, config: EngineConfig, arm: String, round: Int,
                             prompt: String, maxTokens: Int) async throws -> BenchRoundResult {
        let sampling: [String: Any] = [
            "temperature": 0.0, "top_p": 1.0, "top_k": 1,
            "max_tokens": maxTokens, "stream": false,
            "chat_template_kwargs": ["enable_thinking": false]
        ]
        let t0 = Date()
        let resp = try await api.chat(messages: [["role": "user", "content": prompt]], sampling: sampling)
        let elapsed = Date().timeIntervalSince(t0) * 1000
        let t = resp.timings
        let t2 = resp.timings?.predicted_per_second ?? 0
        let decode = t2 > 0 ? t2 : (Double(resp.usage?.completion_tokens ?? 0) / max(0.001, elapsed / 1000))
        return BenchRoundResult(
            arm: arm, round: round,
            promptTokens: resp.usage?.prompt_tokens ?? t?.prompt_n ?? 0,
            outputTokens: resp.usage?.completion_tokens ?? t?.predicted_n ?? 0,
            ttftMs: t?.prompt_ms ?? elapsed,
            prefillTps: t?.prompt_per_second ?? 0,
            decodeTps: decode,
            elapsedMs: t.map { ($0.prompt_ms ?? 0) + ($0.predicted_ms ?? 0) } ?? elapsed,
            drafted: t?.draft_n ?? 0,
            accepted: t?.draft_n_accepted ?? 0,
            clientTtftMs: nil,
            at: Date())
    }

    /// 短上下文基准：当前配置，N 轮。
    func runShort(store: ConfigStore, engine: EngineController, rounds: Int) async {
        guard engine.isRunning else { lastError = "服务未运行，请先启动。"; return }
        running = true; cancelled = false; currentRounds = []; lastError = nil
        defer { running = false }
        let api = engine.client(config: store.config, apiKey: store.apiKey)
        var results: [BenchRoundResult] = []
        for i in 1...rounds {
            if cancelled { break }
            progress = "短上下文基准 · 第 \(i)/\(rounds) 轮"
            progressFraction = Double(i - 1) / Double(rounds)
            do {
                let r = try await runOneRound(api: api, config: store.config, arm: "current", round: i,
                                              prompt: Self.shortPrompt, maxTokens: 256)
                results.append(r)
                currentRounds = results
            } catch {
                lastError = "第 \(i) 轮失败：\(error.localizedDescription)"
                break
            }
        }
        progressFraction = 1
        guard !results.isEmpty else { return }
        let report = BenchReport(
            name: "短上下文基准 · \(rounds) 轮", at: Date(),
            model: store.config.modelName, context: store.config.context, kv: store.config.kvFormat,
            draftMode: store.config.draftMode.label, promptKind: "short",
            targetPromptTokens: 0, maxTokens: 256,
            arms: [BenchArmResult(name: "当前配置", qsaFrom: store.config.qsaEnabled ? String(store.config.qsaFrom) : "off", rounds: results)],
            notes: ["固定 prompt、temperature=0、top_k=1、max_tokens=256、思考关闭。", "计时来自服务端 timings。"],
            qsaVerdict: nil)
        save(report)
        progress = "完成：decode 中位 \(String(format: "%.1f", report.arms[0].medianDecode)) tok/s"
    }

    /// 读取引擎日志中最近一次请求的实际 KV 格式（用于 A/B 条件一致性守卫）。
    static func lastKVFormat(logURL: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: logURL) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = size > 128 * 1024 ? size - 128 * 1024 : 0
        try? fh.seek(toOffset: start)
        guard let d = try? fh.readToEnd(), let s = String(data: d, encoding: .utf8) else { return nil }
        var last: String? = nil
        for line in s.components(separatedBy: "\n") {
            if line.hasPrefix("tqserve: KV format ") {
                let parts = line.components(separatedBy: " ")
                if parts.count >= 4 { last = parts[3] }
            }
        }
        return last
    }

    /// QSA A/B 对照：同模型/同 prompt/同采样，仅 --qsa-from 不同；每臂重启引擎。
    /// targetTokens 可指定长上下文目标（默认阈值+8K；验证加速收益建议 ≥2×阈值）。
    func runQSAAB(store: ConfigStore, engine: EngineController, scanner: ModelScanner, rounds: Int, targetTokens: Int? = nil) async {
        guard !running else { return }
        let qsaCapable = scanner.models.first { $0.path == store.config.modelFile }?.info.qsaCapable ?? false
        guard qsaCapable else { lastError = "主模型不含 QSA 索引，无法进行 QSA 对照。"; return }
        running = true; cancelled = false; currentRounds = []; lastError = nil
        defer { running = false }

        let original = store.config
        let threshold = max(4096, original.qsaFrom)
        var targetTokens = max(threshold + 8192, targetTokens ?? (threshold + 8192))
        var prompt = Self.fixedPrompt(targetTokens: targetTokens)
        let maxTokens = 128
        var arms: [BenchArmResult] = []
        var notes: [String] = [
            "固定内容：确定性长文档（目标 \(targetTokens) tokens，实际以 usage.prompt_tokens 为准）。",
            "采样固定：temperature=0、top_p=1、top_k=1、max_tokens=\(maxTokens)、思考关闭。",
            "两臂仅 --qsa-from 不同（\(threshold) vs off），其余启动参数一致，每臂重启加载。",
            "两臂显式 --kv q8（int8）：排除 Memory Fit 按请求内存压力漂移 KV 的干扰（本机实测 bf16↔int8 不稳定）。",
            "每臂第 1 轮为预热不计入统计；KV 一致性守卫逐轮校验日志实际格式。"
        ]

        let armSpecs: [(String, Bool)] = [("QSA 开（\(threshold)）", true), ("QSA 关（off）", false)]
        for (armIndex, spec) in armSpecs.enumerated() {
            if cancelled { break }
            var cfg = original
            cfg.qsaEnabled = spec.1
            cfg.qsaFrom = threshold
            // 显式固定 KV 为 q8（int8）：本机 Memory Fit 会按请求内存压力在 bf16/int8 间漂移，
            // 破坏对照条件。q8 紧凑、在目标上下文下必然容纳，fit 不会改动显式请求。
            cfg.kvFormat = "q8"
            cfg.context = max(cfg.context, targetTokens + maxTokens + 4096)
            store.config = cfg
            progress = "\(spec.0) · 重启引擎加载模型…"
            progressFraction = Double(armIndex) / 2.0 * 0.9
            await engine.restart(store: store, qsaCapable: true)
            guard engine.isRunning else {
                lastError = "\(spec.0) 臂启动失败：\(engine.lastError ?? "未知")"
                break
            }
            let api = engine.client(config: cfg, apiKey: store.apiKey)
            var results: [BenchRoundResult] = []
            // 预热轮（不计入统计）；若实际 prompt 未超阈值则自动加长重测，保证 QSA 触发条件
            var warm = try? await runOneRound(api: api, config: cfg, arm: spec.0, round: 0,
                                              prompt: prompt, maxTokens: maxTokens)
            var guardLoops = 0
            while let w = warm, w.promptTokens <= threshold, guardLoops < 3 {
                guardLoops += 1
                targetTokens = max(threshold + 8192, w.promptTokens) * 3 / 2
                prompt = Self.fixedPrompt(targetTokens: targetTokens)
                notes.append("预热未达阈值（\(w.promptTokens) ≤ \(threshold)），加长 prompt 至目标 \(targetTokens) tokens 重测。")
                warm = try? await runOneRound(api: api, config: cfg, arm: spec.0, round: 0,
                                              prompt: prompt, maxTokens: maxTokens)
            }
            if let w = warm {
                notes.append("预热轮实际 prompt tokens：\(w.promptTokens)")
            }
            // KV 一致性守卫：Memory Fit 可能按请求内存压力降级 KV（实测 125K 时 int8↔bf16 漂移）。
            // 一旦实际 KV 与预热轮不同，立即中止本臂，避免产出混淆条件的无效对照。
            let kvBaseline = Self.lastKVFormat(logURL: engine.serverLogURL)
            var kvAborted = false
            for i in 1...rounds {
                if cancelled { break }
                progress = "\(spec.0) · 第 \(i)/\(rounds) 轮（长上下文 prefill 约需数分钟）"
                do {
                    let r = try await runOneRound(api: api, config: cfg, arm: spec.0, round: i,
                                                  prompt: prompt, maxTokens: maxTokens)
                    let kvNow = Self.lastKVFormat(logURL: engine.serverLogURL)
                    if let b = kvBaseline, let n = kvNow, b != n {
                        lastError = "\(spec.0) 第 \(i) 轮 KV 格式漂移（\(b) → \(n)），Memory Fit 改变了实验条件，本臂中止。请降低上下文目标或显式固定 --kv 后重跑。"
                        notes.append("KV 漂移中止：预热 \(b)，第 \(i) 轮 \(n)。")
                        kvAborted = true
                        break
                    }
                    results.append(r)
                    currentRounds.append(r)
                } catch {
                    lastError = "\(spec.0) 第 \(i) 轮失败：\(error.localizedDescription)"
                    break
                }
            }
            if let kv = kvBaseline { notes.append("\(spec.0) 实际 KV 格式：\(kv)") }
            if kvAborted { break }
            arms.append(BenchArmResult(name: spec.0, qsaFrom: spec.1 ? String(threshold) : "off", rounds: results))
        }

        // 恢复原配置并重启
        progress = "恢复原配置并重启…"
        store.config = original
        await engine.restart(store: store, qsaCapable: qsaCapable)

        var verdict: String? = nil
        if arms.count == 2, !arms[0].rounds.isEmpty, !arms[1].rounds.isEmpty {
            let on = arms[0].medianDecode, off = arms[1].medianDecode
            let ratio = off > 0 ? on / off : 0
            let actualPrompt = arms[0].rounds[0].promptTokens
            if actualPrompt > threshold {
                verdict = String(format: "上下文 %d tokens > 阈值 %d，QSA 触发条件满足。QSA 开 decode 中位 %.1f tok/s，关 %.1f tok/s，比值 %.2fx。%@",
                                 actualPrompt, threshold, on, off, ratio,
                                 ratio > 1.05 ? "稀疏注意力带来实测加速，QSA 生效。" : (ratio < 0.95 ? "开反而更慢，需检查阈值与上下文。" : "差异不显著（<5%），可能上下文刚过阈值或草稿解码占主导。"))
            } else {
                verdict = "实际 prompt \(actualPrompt) tokens 未超过阈值 \(threshold)，本轮未触发 QSA，结果无效。"
            }
            notes.append(String(format: "TTFT 中位：开 %.0f ms / 关 %.0f ms；Prefill 中位：开 %.1f / 关 %.1f tok/s。",
                                arms[0].medianTTFT, arms[1].medianTTFT, arms[0].medianPrefill, arms[1].medianPrefill))
        }
        let report = BenchReport(
            name: "QSA A/B 对照 · 阈值 \(threshold) · 目标 \(targetTokens) tokens · KV q8", at: Date(),
            model: original.modelName, context: max(original.context, targetTokens + maxTokens + 4096), kv: "q8",
            draftMode: original.draftMode.label, promptKind: "long-ab",
            targetPromptTokens: targetTokens, maxTokens: maxTokens,
            arms: arms, notes: notes, qsaVerdict: verdict)
        save(report)
        progress = verdict ?? "完成"
        progressFraction = 1
    }

    /// 推测解码收益对照：同短 prompt / 同采样，DFlash2 vs 无草稿，每臂重启引擎。
    func runDraftAB(store: ConfigStore, engine: EngineController, rounds: Int) async {
        guard !running else { return }
        // Apple Silicon MLX 后端强制 DFlash2 草稿，无法建立无草稿基线 → 此对照在本机不可行。
        lastError = "本机 MLX 后端要求必须加载 DFlash2 草稿（tqserve: the MLX backend needs the DFlash2 drafter），无法运行「无草稿」基线臂，DFlash2 vs 无草稿对照在此后端不可行。"
        return
    }

    private func save(_ report: BenchReport) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(report) {
            let f = reportsDir().appendingPathComponent("bench-\(Int(report.at.timeIntervalSince1970)).json")
            try? d.write(to: f, options: .atomic)
        }
        loadReports()
    }

    func markdown(_ report: BenchReport) -> String {
        var out = ["# \(report.name)", "",
                   "- 时间：\(ISO8601DateFormatter().string(from: report.at))",
                   "- 模型：\(report.model) · context \(report.context) · KV \(report.kv) · 推测解码 \(report.draftMode)",
                   "- 输出上限：\(report.maxTokens) tokens", ""]
        for arm in report.arms {
            out.append("## \(arm.name)（--qsa-from \(arm.qsaFrom)）")
            out.append("| 轮 | prompt tokens | 输出 tokens | TTFT ms | Prefill tok/s | Decode tok/s | 草稿接受 |")
            out.append("|---|---|---|---|---|---|---|")
            for r in arm.rounds {
                out.append("| \(r.round) | \(r.promptTokens) | \(r.outputTokens) | \(String(format: "%.0f", r.ttftMs)) | \(String(format: "%.1f", r.prefillTps)) | \(String(format: "%.1f", r.decodeTps)) | \(r.accepted)/\(r.drafted) |")
            }
            out.append(String(format: "中位：Decode %.1f tok/s · Prefill %.1f tok/s · TTFT %.0f ms · 接受率 %.1f%%",
                              arm.medianDecode, arm.medianPrefill, arm.medianTTFT, arm.acceptance))
            out.append("")
        }
        if let v = report.qsaVerdict { out.append("## QSA 判定\n\n\(v)\n") }
        out.append("## 条件与备注\n")
        out.append(contentsOf: report.notes.map { "- \($0)" })
        return out.joined(separator: "\n")
    }
}