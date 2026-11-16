import SwiftUI

struct APIView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: ConfigStore
    @EnvironmentObject var engine: EngineController
    @EnvironmentObject var monitor: MonitorService
    // CLT 无 SwiftUI 宏插件：手动展开 @State（存储 + 访问器）。
    private var _checkResult = State(initialValue: "")
    private var checkResult: String {
        get { _checkResult.wrappedValue }
        nonmutating set { _checkResult.wrappedValue = newValue }
    }
    private var _tailscaleIP = State<String?>(initialValue: nil)
    private var cachedTailscaleIP: String? {
        get { _tailscaleIP.wrappedValue }
        nonmutating set { _tailscaleIP.wrappedValue = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DetailHead(title: "API 服务", subtitle: "OpenAI 兼容 API：监听、认证、并发与端点地址。", onBack: { model.go(.home) })
            DetailBody {
                Panel(title: "服务连接") {
                    HStack(spacing: 12) {
                        StyledTextField(label: "Host（--host）", text: $store.config.host)
                        StyledNumberField(label: "Port（--port）", value: $store.config.port)
                    }
                    StyledSecureField(label: "API Key（可选，存 macOS Keychain）", text: $store.apiKey,
                                      hint: "通过 --api-key-file 传给引擎；不出现在命令行、配置与日志中。")
                    ChoiceRow(title: "并行请求槽（--np）",
                              options: [(1, "1"), (2, "2"), (4, "4"), (8, "8")],
                              selection: $store.config.parallel,
                              desc: "context 按槽均分；运行时可用 /admin/slots 调整（不超过启动值）。")
                    HStack(spacing: 10) {
                        ActionButton(label: "检查连接", icon: .network, primary: true) {
                            Task { await checkConnection() }
                        }
                        if engine.isRunning && store.config.parallel > 1 {
                            ActionButton(label: "应用并发到运行中服务") {
                                Task {
                                    do {
                                        try await engine.client(config: store.config, apiKey: store.apiKey).setSlots(store.config.parallel)
                                        model.notify("并发已调整为 \(store.config.parallel)。")
                                    } catch { model.notify("调整失败：\(error.localizedDescription)") }
                                }
                            }
                        }
                        RestartBadge()
                    }
                    if !checkResult.isEmpty {
                        NoteBox(text: checkResult, warn: checkResult.contains("失败") || checkResult.contains("✗"))
                    }
                }
                Panel(title: "连接地址") {
                    MonoBlock(text: endpoints)
                    HStack(spacing: 10) {
                        ActionButton(label: "复制地址", icon: .copy) {
                            copyToPasteboard("http://\(store.config.host):\(store.config.port)/v1")
                            model.notify("已复制 API 地址。")
                        }
                        ActionButton(label: "复制 Tailscale 地址", icon: .network) {
                            copyToPasteboard(tailscaleAddress)
                            model.notify("已复制 Tailscale 地址（需 host 设为 0.0.0.0 或 Tailscale IP）。")
                        }
                    }
                    DataRow(name: "健康检测", value: "GET /health")
                    DataRow(name: "模型列表", value: "GET /v1/models")
                    DataRow(name: "聊天补全", value: "POST /v1/chat/completions")
                    DataRow(name: "监控快照", value: "GET /api/monitor/v1/snapshot")
                    DataRow(name: "并发管理", value: "GET/POST /admin/slots")
                }
            } right: {
                Panel(title: "运行状态") {
                    DataRow(name: "监听", value: engine.isRunning ? "\(store.config.host):\(store.config.port)" : "未运行")
                    DataRow(name: "并发槽", value: monitor.slots.map { "\($0.active ?? 0) / \($0.limit ?? 0)（忙 \($0.busy ?? 0)，排队 \($0.queued ?? 0)）" } ?? "—")
                    DataRow(name: "认证", value: store.apiKey.isEmpty ? "未设置密钥" : "Bearer（Keychain）")
                    DataRow(name: "服务模型", value: engine.servedModel ?? "—")
                }
                Panel(title: "远程访问（Tailscale）") {
                    NoteBox(text: "通过 Tailscale 访问：将 Host 设为 0.0.0.0（或本机 Tailscale IP）并重启服务，建议同时设置 API Key。Tailscale 网络本身加密；不要将端口暴露到公网。本机已安装 Tailscale。")
                    MonoBlock(text: tailscaleAddress)
                }
            }
        }
        .task { await probeTailscaleIP() }
    }

    var endpoints: String {
        let base = "http://\(store.config.host):\(store.config.port)"
        return """
        \(base)/v1
        \(base)/v1/chat/completions
        \(base)/v1/models
        \(base)/health
        \(base)/monitor
        """
    }

    var tailscaleAddress: String {
        let ip = cachedTailscaleIP ?? "<本机 Tailscale IP>"
        return "http://\(ip):\(store.config.port)/v1"
    }

    func probeTailscaleIP() async {
        let ip: String? = await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["tailscale", "ip", "-4"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            do {
                try p.run()
                p.waitUntilExit()
                let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return s?.isEmpty == false ? s : nil
            } catch { return nil }
        }.value
        cachedTailscaleIP = ip
    }

    func checkConnection() async {
        let api = engine.client(config: store.config, apiKey: store.apiKey)
        var lines: [String] = []
        do {
            let h = try await api.health()
            lines.append("✓ /health：status=\(h.status ?? "?") context=\(h.context ?? 0) engine=\(h.engine ?? "?")")
        } catch {
            lines.append("✗ /health 失败：\(error.localizedDescription)")
        }
        do {
            let m = try await api.models()
            lines.append("✓ /v1/models：\(m.data.map { $0.id }.joined(separator: ", "))（owned_by \(m.data.first?.owned_by ?? "?")）")
        } catch {
            lines.append("✗ /v1/models 失败：\(error.localizedDescription)")
        }
        checkResult = lines.joined(separator: "\n")
    }
}