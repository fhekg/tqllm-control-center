import SwiftUI

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var engine: EngineController
    @EnvironmentObject var monitor: MonitorService
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        VStack(spacing: 20) {
            runtimeCard
            hubCard
        }
    }

    // MARK: 顶部运行状态面板（真实数据，无数据显示 —）

    var runtimeCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    LineIcon(icon: .activity, size: 20).foregroundStyle(Theme.ink)
                    Text("模型运行情况").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                }
                Spacer()
                if engine.isRunning && monitor.connected {
                    if let ms = monitor.prefillElapsedMs {
                        Pill(text: "实时 · 填充中 已等待 \(Int(ms / 1000))s", tone: .green)
                    } else {
                        Pill(text: "实时 · 采样 \(sampleTime)", tone: .green)
                    }
                } else if engine.isRunning && !monitor.connected {
                    Pill(text: "服务繁忙 · 遥测暂不可用", tone: .amber)
                } else if engine.state == .starting {
                    Pill(text: "启动中 · 等待引擎就绪", tone: .amber)
                } else if engine.state == .fault {
                    Pill(text: "故障 · 查看日志", tone: .red)
                } else {
                    Pill(text: "未连接 · 无实时数据", tone: .amber)
                }
            }
            .padding(.bottom, 14)

            HStack(spacing: 10) {
                Text(store.config.modelName).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink)
                dot
                Text("tqLLM \(model.cliVersion)").font(.system(size: 12.5)).foregroundStyle(Theme.text)
                dot
                Text("Apple M5 Pro").font(.system(size: 12.5)).foregroundStyle(Theme.text)
                if let ctx = engine.health?.context {
                    dot
                    Text("引擎 context \(ctx)").font(.system(size: 12.5)).foregroundStyle(Theme.text)
                }
            }
            .padding(.bottom, 18)

            HStack(spacing: 12) {
                MetricTile(value: fmt(monitor.decodeRate, digits: 0), unit: "tok/s", caption: "生成速度 · Answering")
                MetricTile(value: fmt(monitor.prefillRate, digits: 0), unit: "tok/s", caption: "填充速度 · Prefill")
                MetricTile(value: fmt(monitor.ttftMs, digits: 0), unit: "ms", caption: "首字延迟 · TTFT")
                MetricTile(value: contextText, unit: "", caption: "上下文上限 · Context")
                MetricTile(value: memoryText, unit: memoryText == "—" ? "" : "GB", caption: "内存占用 · Memory")
            }

            Rectangle().fill(Theme.border).frame(height: 0.5).padding(.top, 20)

            HStack {
                if let p = monitor.prefillPromptTokens, let ms = monitor.prefillElapsedMs {
                    Text("实时快照　输入 \(p) Tokens · 引擎填充中（\(Int(ms / 1000))s）· 首 token 产出后显示速度指标")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                } else if let input = monitor.inputTokens, let out = monitor.outputTokensTotal {
                    Text("实时快照　输入 \(input) Tokens · 已输出 \(out) Tokens")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                } else {
                    Text("等待请求数据　发起请求后此处显示输入 / 输出 Tokens")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Text("数据来源 /api/monitor/v1/snapshot")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            }
            .padding(.top, 13)
        }
        .padding(.horizontal, 30).padding(.top, 26).padding(.bottom, 22)
        .card()
    }

    var dot: some View {
        Circle().fill(Theme.border).frame(width: 3, height: 3)
    }

    var sampleTime: String {
        guard let d = monitor.lastSampleAt else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    var contextText: String {
        guard let c = monitor.contextLimit ?? engine.health?.context else { return "—" }
        if c >= 1024 { return "\(c / 1024)K" }
        return "\(c)"
    }

    var memoryText: String {
        guard let b = monitor.memoryBytes else { return "—" }
        return String(format: "%.1f", b / 1_073_741_824)
    }

    func fmt(_ v: Double?, digits: Int) -> String {
        guard let v else { return "—" }
        return String(format: "%.\(digits)f", v)
    }

    // MARK: 双列功能入口

    var hubCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    LineIcon(icon: .sliders, size: 22).foregroundStyle(Theme.ink)
                    Text("tqLLM Control Center").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                }
                Spacer()
                Pill(text: "功能导航")
            }
            .padding(.bottom, 10)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0)], spacing: 2) {
                ForEach(Page.allCases.filter { $0 != .home }) { page in
                    Button { model.go(page) } label: {
                        HStack(spacing: 14) {
                            LineIcon(icon: page.icon, size: 22).foregroundStyle(Theme.text)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(page.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                                Text(page.desc).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            LineIcon(icon: .arrow, size: 16).foregroundStyle(Theme.muted)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 26).padding(.top, 22).padding(.bottom, 16)
        .card()
    }
}

struct MetricTile: View {
    let value: String
    let unit: String
    let caption: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 33, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if !unit.isEmpty {
                    Text(unit).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            Text(caption).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.soft)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.border.opacity(0.6), lineWidth: 0.5))
    }
}