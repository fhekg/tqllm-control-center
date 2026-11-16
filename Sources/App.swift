import SwiftUI
import AppKit

enum Page: String, CaseIterable, Identifiable {
    case home, service, models, qsa, draft, context, generation, api, performance, logs, presets
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "总览"
        case .service: return "服务控制"
        case .models: return "模型管理"
        case .qsa: return "QSA 加速"
        case .draft: return "推测解码"
        case .context: return "上下文与缓存"
        case .generation: return "生成参数"
        case .api: return "API 服务"
        case .performance: return "实时性能"
        case .logs: return "运行日志"
        case .presets: return "配置预设"
        }
    }
    var icon: Icon {
        switch self {
        case .home: return .sliders
        case .service: return .power
        case .models: return .layers
        case .qsa: return .zap
        case .draft: return .brain
        case .context: return .database
        case .generation: return .sliders
        case .api: return .network
        case .performance: return .activity
        case .logs: return .terminal
        case .presets: return .save
        }
    }
    var desc: String {
        switch self {
        case .home: return ""
        case .service: return "启动、停止、重启、自动启动"
        case .models: return "模型路径、导入、切换、草稿模型"
        case .qsa: return "开启、关闭、触发阈值"
        case .draft: return "DFlash2、Draft Max、Tree"
        case .context: return "Context、KV 精度、Prompt Cache"
        case .generation: return "Temperature、Top-p、输出长度"
        case .api: return "Host、Port、API Key、并发"
        case .performance: return "TTFT、Prefill、Decode、内存"
        case .logs: return "实时日志、错误诊断、参数记录"
        case .presets: return "快速模式、长上下文、性能测试"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var page: Page = .home
    @Published var toast: String?
    let store = ConfigStore()
    let engine = EngineController()
    let scanner = ModelScanner()
    let monitor = MonitorService()
    let logs = LogService()
    let bench = BenchmarkService()

    var qsaCapable: Bool {
        scanner.models.first { $0.path == store.config.modelFile }?.info.qsaCapable ?? false
    }
    var cliVersion: String { engine.cliVersion(cliPath: store.config.cliPath) }

    func boot() {
        engine.startPolling(store: store)
        monitor.start(store: store, engine: engine)
        logs.start(engineLogURL: engine.serverLogURL)
        scanner.startProbing(modelPath: store.config.modelFile, draftPath: store.config.draftFile)
        installTestHooks()
        logs.event("应用启动。CLI：\(store.config.cliPath)，版本 \(cliVersion)。")
        Task {
            await scanner.scan(dirs: [store.config.modelDir,
                                      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/tqllm/models").path])
        }
    }

    func notify(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(nanoseconds: 3_800_000_000)
            if toast == text { toast = nil }
        }
    }

    func go(_ p: Page) { page = p }

    // MARK: 自动化测试钩子（分布式通知）：触发与 UI 按钮完全相同的代码路径。
    // 无辅助功能权限的环境下用于验收全局启停与页面导航；状态写入 gui-state.json。

    func installTestHooks() {
        let nc = DistributedNotificationCenter.default()
        nc.addObserver(forName: .init("tqllm-cc-test-toggle"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                await self?.globalToggle()
                self?.dumpState()
            }
        }
        nc.addObserver(forName: .init("tqllm-cc-test-nav"), object: nil, queue: .main) { [weak self] n in
            let raw = (n.object as? String) ?? "home"
            Task { @MainActor in
                self?.page = Page(rawValue: raw) ?? .home
                self?.dumpState()
            }
        }
        nc.addObserver(forName: .init("tqllm-cc-test-dump"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.dumpState() }
        }
        nc.addObserver(forName: .init("tqllm-cc-test-autostart"), object: nil, queue: .main) { [weak self] n in
            let on = (n.object as? String) == "on"
            Task { @MainActor in
                self?.store.setAutoStart(on)
                self?.dumpState()
            }
        }
        nc.addObserver(forName: .init("tqllm-cc-test-preset"), object: nil, queue: .main) { [weak self] n in
            let action = (n.object as? String) ?? "save"
            Task { @MainActor in
                guard let self else { return }
                switch action {
                case "save":
                    self.store.saveCustom(name: "验收测试预设")
                case "apply-long":
                    self.store.apply(BuiltInPresets.long)
                case "apply-daily":
                    self.store.apply(BuiltInPresets.daily)
                default: break
                }
                self.dumpState()
            }
        }
    }

    func dumpState() {
        let obj: [String: Any] = [
            "page": page.rawValue,
            "engine_state": engine.state.rawValue,
            "ownership": engine.ownership.rawValue,
            "pid": engine.pid ?? 0,
            "decode_rate": monitor.decodeRate ?? -1,
            "memory_gb": (monitor.memoryBytes ?? 0) / 1_073_741_824,
            "autostart_status": store.autoStartStatus,
            "at": ISO8601DateFormatter().string(from: Date())
        ]
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: store.supportDir.appendingPathComponent("gui-state.json"), options: .atomic)
        }
    }

    func globalToggle() async {
        if engine.isRunning || engine.state == .starting {
            if engine.ownership == .externalCLI {
                let ok = confirmExternalStop()
                if !ok { return }
                _ = await engine.stop(store: store, confirmedExternal: true)
            } else {
                _ = await engine.stop(store: store)
            }
            notify("服务已停止。")
        } else {
            await engine.start(store: store, qsaCapable: qsaCapable)
            if engine.isRunning {
                notify("服务已启动：\(store.config.host):\(store.config.port)")
                logs.event("全局启动：\(engine.launchedArguments.joined(separator: " "))")
            } else {
                notify("启动失败：\(engine.lastError ?? "未知错误")")
            }
        }
    }

    /// 无显示器/无录屏权限环境下的真实截图：ImageRenderer 离屏渲染每个页面。
    /// 注意：ImageRenderer 不渲染 ScrollView 内容，故用普通 VStack 组合顶栏/页面/底栏。
    func renderScreenshots(dir: String) async {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileHandle.standardError.write(Data("[render] start \(dir)\n".utf8))
        let pages: [(Page, CGFloat)] = [
            (.home, 1060), (.service, 1150), (.models, 1250), (.qsa, 1150), (.draft, 1050),
            (.context, 1050), (.generation, 1100), (.api, 1150), (.performance, 1300),
            (.logs, 1150), (.presets, 1150)
        ].filter { entry in
            guard let i = CommandLine.arguments.firstIndex(of: "--render-only"),
                  CommandLine.arguments.count > i + 1 else { return true }
            return CommandLine.arguments[i + 1] == entry.0.rawValue
        }
        for (p, height) in pages {
            page = p
            try? await Task.sleep(nanoseconds: 400_000_000)
            let view = VStack(spacing: 0) {
                TopBar()
                PageSwitch(page: p)
                FooterBar()
            }
            .frame(width: 1244, alignment: .top)
            .padding(.horizontal, 38)
            .padding(.top, 28)
            .padding(.bottom, 18)
            .frame(width: 1320, height: height, alignment: .top)
            .background(Theme.bg)
            .environmentObject(self)
            .environmentObject(store)
            .environmentObject(engine)
            .environmentObject(scanner)
            .environmentObject(monitor)
            .environmentObject(logs)
            .environmentObject(bench)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let img = renderer.nsImage,
               let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                let name = String(format: "%02d-%@", pages.firstIndex(where: { $0.0 == p })! + 1, p.rawValue)
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
                FileHandle.standardError.write(Data("[render] wrote \(name).png\n".utf8))
            }
        }
        page = .home
        logs.event("截图渲染完成：\(dir)")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)   // 强制浅色，匹配原型
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let model { model.engine.shutdownIfNeeded(store: model.store) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct TqLLMControlCenterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("tqLLM Control Center") {
            RootView()
                .environmentObject(model)
                .environmentObject(model.store)
                .environmentObject(model.engine)
                .environmentObject(model.scanner)
                .environmentObject(model.monitor)
                .environmentObject(model.logs)
                .environmentObject(model.bench)
                .frame(minWidth: 1080, minHeight: 760)
                .onAppear {
                    FileHandle.standardError.write(Data("[dbg] onAppear args=\(CommandLine.arguments)\n".utf8))
                    delegate.model = model
                    model.boot()
                    if let i = CommandLine.arguments.firstIndex(of: "--render"),
                       CommandLine.arguments.count > i + 1 {
                        RenderMode.active = true
                        let dir = CommandLine.arguments[i + 1]
                        let wait = Double(CommandLine.arguments.firstIndex(of: "--render-wait").map { CommandLine.arguments[$0 + 1] } ?? "4") ?? 4
                        FileHandle.standardError.write(Data("[dbg] render scheduled dir=\(dir) wait=\(wait)\n".utf8))
                        Task {
                            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                            FileHandle.standardError.write(Data("[dbg] render task fired\n".utf8))
                            await model.renderScreenshots(dir: dir)
                            if CommandLine.arguments.contains("--exit-after-render") {
                                NSApp.terminate(nil)
                            }
                        }
                    }
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1320, height: 980)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var engine: EngineController
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 0) {
                    TopBar()
                    PageSwitch(page: model.page)
                    FooterBar()
                }
                .frame(maxWidth: 1320)
                .padding(.horizontal, 38)
                .padding(.top, 28)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.bg)

            if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.paper)
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .background(Theme.accent.opacity(0.94))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.bottom, 26)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .preferredColorScheme(.light)
    }
}

/// 页面路由（RootView 与离屏渲染共用）。
struct PageSwitch: View {
    let page: Page
    var body: some View {
        switch page {
        case .home: HomeView()
        case .service: ServiceView()
        case .models: ModelsView()
        case .qsa: QSAView()
        case .draft: DraftView()
        case .context: ContextView()
        case .generation: GenerationView()
        case .api: APIView()
        case .performance: PerformanceView()
        case .logs: LogsView()
        case .presets: PresetsView()
        }
    }
}

/// 顶部：品牌 + 全局状态 + 全局启停（原型 powerbar）。
struct TopBar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var engine: EngineController
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        HStack(alignment: .center, spacing: 15) {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Theme.paper)
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Theme.border, lineWidth: 1))
                .frame(width: 48, height: 48)
                .overlay(LineIcon(icon: .sliders, size: 27).foregroundStyle(Theme.ink))
            VStack(alignment: .leading, spacing: 4) {
                Text("tqLLM Control Center")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Text("Mac mini · Apple M5 Pro · 48 GB · tqLLM \(model.cliVersion)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
            HStack(spacing: 9) {
                Text("服务控制").font(.system(size: 12)).foregroundStyle(Color(hex: 0x64707C))
                Button {
                    Task { await model.globalToggle() }
                } label: {
                    HStack(spacing: 7) {
                        LineIcon(icon: .power, size: 17)
                        Text(engine.isRunning || engine.state == .starting ? "关闭服务" : "启动服务")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Theme.paper)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(engine.isRunning ? Color(hex: 0x57656C) : Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(engine.busy || engine.state == .stopping)
            }
            .padding(.leading, 12).padding(.trailing, 7).padding(.vertical, 6)
            .background(Theme.paper)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.border, lineWidth: 1))
        }
        .padding(.bottom, 23)
    }

    var statusColor: Color {
        switch engine.state {
        case .running: return Theme.green
        case .starting, .stopping: return Color(hex: 0xC0A371)
        case .fault: return Theme.red
        case .stopped: return Color(hex: 0xC0A371)
        }
    }
    var statusLabel: String {
        switch engine.state {
        case .running: return "运行中 · \(engine.ownership.rawValue)"
        case .starting: return "启动中…"
        case .stopping: return "停止中…"
        case .fault: return "故障"
        case .stopped: return "已停止 · 未连接"
        }
    }
}

struct FooterBar: View {
    var body: some View {
        HStack {
            Text("tqLLM Control Center · Interface Design v2")
            Spacer()
            Text("浅灰背景 · 白色卡片 · 原型")
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.muted)
        .padding(.top, 20)
    }
}