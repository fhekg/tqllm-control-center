import SwiftUI
import Charts

struct PerformanceView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: ConfigStore
    @EnvironmentObject var engine: EngineController
    @EnvironmentObject var monitor: MonitorService
    @EnvironmentObject var bench: BenchmarkService
    @EnvironmentObject var scanner: ModelScanner
    private var _rounds = State(initialValue: 3)
    private var rounds: Int {
        get { _rounds.wrappedValue }
        nonmutating set { _rounds.wrappedValue = newValue }
    }
    private var _selectedReport = State<BenchReport?>(initialValue: nil)
    private var selectedReport: BenchReport? {
        get { _selectedReport.wrappedValue }
        nonmutating set { _selectedReport.wrappedValue = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DetailHead(title: "实时性能", subtitle: "全部数字来自 /api/monitor/v1/snapshot 与服务端 timings；无数据显示 —。", onBack: { model.go(.home) })
            DetailBody {
                Panel(title: "实时指标") {
                    HStack(spacing: 12) {
                        smallMetric(fmt(monitor.decodeRate, 1), "tok/s", "Decode")
                        smallMetric(fmt(monitor.prefillRate, 1), "tok/s", "Prefill")
                        smallMetric(fmt(monitor.ttftMs, 0), "ms", "TTFT")
                        smallMetric(monitor.memoryBytes.map { String(format: "%.1f", $0 / 1_073_741_824) } ?? "—", "GB", "Memory")
                    }
                    if monitor.connected && !monitor.samples.isEmpty {
                        Chart(monitor.samples.suffix(120)) { s in
                            if let r = s.decodeRate {
                                LineMark(x: .value("时间", s.at), y: .value("tok/s", r))
                                    .foregroundStyle(Theme.green)
                            }
                        }
                        .chartYAxis { AxisMarks(position: .leading) }
                        .frame(height: 140)
                        Text("最近 \(min(120, monitor.samples.count)) 个采样 · Decode tok/s")
                            .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    } else {
                        NoteBox(text: "未连接或无请求：发起请求后显示实时曲线。")
                    }
                }
                Panel(title: "请求统计（服务端记录）") {
                    if monitor.requestHistory.isEmpty {
                        NoteBox(text: "暂无请求记录。")
                    } else {
                        VStack(spacing: 0) {
                            HStack {
                                Text("ID").frame(width: 40, alignment: .leading)
                                Text("阶段").frame(width: 70, alignment: .leading)
                                Text("输入/输出").frame(maxWidth: .infinity, alignment: .leading)
                                Text("TTFT").frame(width: 70, alignment: .trailing)
                                Text("tok/s").frame(width: 60, alignment: .trailing)
                            }
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                            .padding(.vertical, 6)
                            ForEach(monitor.requestHistory.prefix(12)) { r in
                                HStack {
                                    Text("\(r.id)").frame(width: 40, alignment: .leading)
                                    Text(r.phase ?? "—").frame(width: 70, alignment: .leading)
                                        .foregroundStyle(r.phase == "decode" ? Theme.green : Theme.text)
                                    Text("\(r.prompt_tokens ?? 0) / \(r.output_tokens ?? 0)").frame(maxWidth: .infinity, alignment: .leading)
                                    Text(r.first_output_ms.map { String(format: "%.0f", $0) } ?? "—").frame(width: 70, alignment: .trailing)
                                    Text(fmt(r.phase == "prefill" ? r.prefill_tokens_per_second : r.decode_tokens_per_second, 1)).frame(width: 60, alignment: .trailing)
                                }
                                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.text)
                                .padding(.vertical, 5)
                                .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 0.5) }
                            }
                        }
                    }
                    DataRow(name: "草稿接受率", value: monitor.acceptance.map { String(format: "%.1f%%（\(monitor.acceptedTotal)/\(monitor.draftedTotal)）", $0) } ?? "—")
                }
                Panel(title: "基准测试") {
                    ChoiceRow(title: "重复轮数", options: [(3, "3 次"), (5, "5 次")],
                              selection: _rounds.projectedValue)
                    HStack(spacing: 10) {
                        ActionButton(label: bench.running ? "测试中…" : "短上下文基准", icon: .play, primary: true, disabled: bench.running || !engine.isRunning) {
                            Task { await bench.runShort(store: store, engine: engine, rounds: rounds) }
                        }
                        ActionButton(label: "QSA A/B 对照", icon: .zap, disabled: bench.running || !model.qsaCapable) {
                            Task { await bench.runQSAAB(store: store, engine: engine, scanner: scanner, rounds: 2) }
                        }
                        if bench.running {
                            ActionButton(label: "取消") { bench.cancel() }
                        }
                    }
                    if bench.running {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: bench.progressFraction).tint(Theme.green)
                            Text(bench.progress).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                        }
                    }
                    if let err = bench.lastError { NoteBox(text: err, warn: true) }
                    NoteBox(text: "测试固定模型、量化、prompt、采样（temperature=0）、上下文与输出上限；计时来自服务端 timings（prompt_ms / predicted_per_second）。QSA A/B 每臂重启引擎，仅 --qsa-from 不同。")
                }
            } right: {
                Panel(title: "性能历史与报告") {
                    if bench.reports.isEmpty {
                        NoteBox(text: "还没有测试报告。运行基准后在此查看与导出。")
                    } else {
                        ForEach(bench.reports.prefix(6)) { r in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(r.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink)
                                Text(r.at.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                                ForEach(r.arms) { arm in
                                    Text(String(format: "%@：%.1f tok/s（中位）", arm.name, arm.medianDecode))
                                        .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.text)
                                }
                                HStack(spacing: 8) {
                                    ActionButton(label: "查看") { selectedReport = r }
                                    ActionButton(label: "导出 MD", icon: .save) {
                                        savePanel(defaultName: "bench-report.md", content: bench.markdown(r))
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 0.5) }
                        }
                    }
                }
                Panel(title: "需要观察的指标") {
                    DataRow(name: "TTFT / 首字", value: fmt(monitor.ttftMs, 0) + " ms")
                    DataRow(name: "Prefill tok/s", value: fmt(monitor.prefillRate, 1))
                    DataRow(name: "Decode tok/s", value: fmt(monitor.decodeRate, 1))
                    DataRow(name: "QSA 实际触发", value: model.qsaCapable ? (store.config.qsaEnabled ? "已配置 · 待长上下文证据" : "已关闭") : "模型不支持")
                    DataRow(name: "草稿接受率", value: monitor.acceptance.map { String(format: "%.1f%%", $0) } ?? "—")
                }
            }
        }
        .sheet(item: _selectedReport.projectedValue) { r in
            ReportSheet(report: r)
        }
    }

    func smallMetric(_ value: String, _ unit: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.ink)
                Text(unit).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.soft)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    func fmt(_ v: Double?, _ d: Int) -> String {
        guard let v else { return "—" }
        return String(format: "%.\(d)f", v)
    }
}

struct ReportSheet: View {
    let report: BenchReport
    @EnvironmentObject var bench: BenchmarkService
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(report.name).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.ink)
                Spacer()
                ActionButton(label: "关闭") { dismiss() }
            }
            ScrollView {
                Text(bench.markdown(report))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(width: 760, height: 620)
        .background(Theme.bg)
    }
}