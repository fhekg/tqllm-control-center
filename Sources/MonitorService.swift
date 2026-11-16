import Foundation
import SwiftUI
import Darwin

/// 进程真实内存占用（统一内存 phys_footprint）。Metal 版 tqserve 的 hardware 采样为 null 时的可靠来源。
func processFootprintBytes(pid: Int32) -> UInt64? {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
        }
    }
    return result == 0 ? usage.ri_phys_footprint : nil
}

struct MetricSample: Identifiable {
    let id = UUID()
    let at: Date
    let decodeRate: Double?
    let prefillRate: Double?
    let memoryBytes: Double?
}

/// API 通信与监控层：轮询 /api/monitor/v1/snapshot，聚合首页五项指标与历史。
@MainActor
final class MonitorService: ObservableObject {
    @Published var snapshot: MonitorSnapshot?
    @Published var samples: [MetricSample] = []
    @Published var lastSampleAt: Date?
    @Published var connected = false
    @Published var monitorError: String?

    // 首页指标（无数据为 nil → UI 显示 —）
    @Published var decodeRate: Double?
    @Published var prefillRate: Double?
    @Published var ttftMs: Double?
    @Published var contextLimit: Int?
    @Published var memoryBytes: Double?
    @Published var memoryTotal: Double?
    @Published var inputTokens: Int?
    @Published var outputTokensTotal: Int?
    @Published var acceptance: Double?
    @Published var draftedTotal: Int = 0
    @Published var acceptedTotal: Int = 0
    @Published var requestHistory: [MonitorSnapshot.Request] = []
    @Published var slots: SlotsInfo?
    /// 正在填充的请求（Metal 后端 prefill 期间不提供实时速率，用等待时长如实呈现进度）。
    @Published var prefillPromptTokens: Int?
    @Published var prefillElapsedMs: Double?

    private var task: Task<Void, Never>?
    private var instanceId: String?
    private var persistedIDs: Set<Int> = []
    private let historyCap = 600

    func start(store: ConfigStore, engine: EngineController) {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if engine.isRunning {
                    await self.poll(store: store, engine: engine)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                } else {
                    self.connected = false
                    self.snapshot = nil
                    self.decodeRate = nil; self.prefillRate = nil; self.ttftMs = nil
                    self.memoryBytes = nil; self.contextLimit = nil
                    self.acceptance = nil
                    self.prefillPromptTokens = nil; self.prefillElapsedMs = nil
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
    }

    private func poll(store: ConfigStore, engine: EngineController) async {
        let api = engine_client(store: store)
        do {
            let snap = try await api.snapshot()
            connected = true
            monitorError = nil
            if snap.instance_id != instanceId {
                instanceId = snap.instance_id
                samples = []
                requestHistory = []
            }
            snapshot = snap
            lastSampleAt = Date()

            let rows = snap.requests ?? []
            let active = rows.filter { !["complete", "failed", "cancelled"].contains($0.phase ?? "") }
            let decoders = active.filter { $0.phase == "decode" }
            let rates = decoders.compactMap { $0.decode_tokens_per_second }
            decodeRate = rates.isEmpty ? nil : rates.reduce(0, +)
            let prefillFocus = active.last(where: { $0.phase == "prefill" }) ?? rows.last(where: { $0.prefill_tokens_per_second != nil })
            prefillRate = prefillFocus?.prefill_tokens_per_second
            if let p = active.last(where: { $0.phase == "prefill" }) {
                prefillPromptTokens = p.prompt_tokens
                prefillElapsedMs = p.elapsed_ms
            } else {
                prefillPromptTokens = nil
                prefillElapsedMs = nil
            }
            ttftMs = rows.last(where: { $0.first_output_ms != nil })?.first_output_ms
            contextLimit = snap.engine?.context_per_slot
            if let hw = snap.hardware, let age = hw.sample_age_ms, age < 10000, let used = hw.gpu_used_bytes {
                memoryBytes = used
                memoryTotal = hw.gpu_total_bytes ?? Double(ProcessInfo.processInfo.physicalMemory)
            } else if let pid = engine.pid, let fp = processFootprintBytes(pid: Int32(pid)) {
                // Metal 版 hardware 采样不可用：读引擎进程 phys_footprint（真实数据）
                memoryBytes = Double(fp)
                memoryTotal = Double(ProcessInfo.processInfo.physicalMemory)
            }
            let drafted = rows.reduce(0) { $0 + ($1.drafted ?? 0) }
            let accepted = rows.reduce(0) { $0 + ($1.accepted ?? 0) }
            draftedTotal = drafted
            acceptedTotal = accepted
            acceptance = drafted > 0 ? Double(accepted) / Double(drafted) * 100 : nil
            inputTokens = rows.last?.prompt_tokens
            outputTokensTotal = rows.reduce(0) { $0 + ($1.output_tokens ?? 0) }
            requestHistory = Array(rows.suffix(60).reversed())

            samples.append(MetricSample(at: Date(), decodeRate: decodeRate, prefillRate: prefillRate, memoryBytes: memoryBytes))
            if samples.count > historyCap { samples.removeFirst(samples.count - historyCap) }

            persistCompleted(rows, store: store)
            if let s = try? await api.slots() { slots = s }
        } catch {
            connected = false
            monitorError = error.localizedDescription
        }
    }

    private func engine_client(store: ConfigStore) -> APIClient {
        APIClient(host: store.config.host, port: store.config.port, apiKey: store.apiKey)
    }

    /// 完成的请求写入性能历史（持久化）。
    private func persistCompleted(_ rows: [MonitorSnapshot.Request], store: ConfigStore) {
        let completed = rows.filter { $0.phase == "complete" && !persistedIDs.contains($0.id) }
        guard !completed.isEmpty else { return }
        for r in completed { persistedIDs.insert(r.id) }
        if persistedIDs.count > 5000 { persistedIDs = Set(completed.map { $0.id }) }
        var history: [[String: Any]] = []
        if let d = try? Data(contentsOf: store.historyURL),
           let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
            history = arr
        }
        let enc = JSONEncoder()
        for r in completed {
            if let d = try? enc.encode(r), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                var entry = obj
                entry["recorded_at"] = ISO8601DateFormatter().string(from: Date())
                entry["instance_id"] = instanceId
                history.append(entry)
            }
        }
        if history.count > 2000 { history = Array(history.suffix(2000)) }
        if let d = try? JSONSerialization.data(withJSONObject: history, options: [.prettyPrinted]) {
            try? d.write(to: store.historyURL, options: .atomic)
        }
    }

    func loadHistory(store: ConfigStore) -> [[String: Any]] {
        guard let d = try? Data(contentsOf: store.historyURL),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
        return arr
    }
}