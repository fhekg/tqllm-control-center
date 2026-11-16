import SwiftUI

struct ContextView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: ConfigStore
    @EnvironmentObject var engine: EngineController
    @EnvironmentObject var monitor: MonitorService

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DetailHead(title: "上下文与缓存", subtitle: "Context、KV 精度、Prompt Cache 与 Memory Fit；设置值与实际加载值分别显示。", onBack: { model.go(.home) })
            DetailBody {
                Panel(title: "上下文窗口") {
                    ChoiceRow(title: "Context 长度（--context）",
                              options: [(32768, "32K"), (65536, "64K"), (131072, "128K"), (262144, "256K")],
                              selection: $store.config.context,
                              desc: "模型训练上限 262144；Memory Fit 可能下调并公告。并发 >1 时按槽均分。")
                    ChoiceRow(title: "KV Cache 精度（--kv）",
                              options: [("bf16", "BF16"), ("tq3", "TQ3"), ("q4", "Q4"), ("q8", "Q8")],
                              selection: $store.config.kvFormat,
                              desc: "KV 缓存精度不等于模型权重量化。fit 可能自动降级并公告。")
                    SwitchRow(title: "Prompt Cache（--prompt-cache）", desc: "重复前缀复用，单槽；默认 off。", isOn: $store.config.promptCache)
                    SwitchRow(title: "Memory Fit（-fit）", desc: "按可用统一内存适配 KV / context / prefill 缓冲；关闭后装不下会拒绝启动。", isOn: $store.config.memoryFit)
                    HStack { RestartBadge() }
                }
                Panel(title: "内存占用监测（实时）") {
                    if let used = monitor.memoryBytes, let total = monitor.memoryTotal {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(String(format: "%.1f", used / 1_073_741_824))
                                    .font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.ink)
                                Text("GB / \(String(format: "%.0f", total / 1_073_741_824)) GB")
                                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            }
                            ProgressView(value: min(1, used / total)).tint(used / total > 0.92 ? Theme.red : Theme.green)
                            Text("来源 hardware.gpu_used_bytes（统一内存）· 采样 \(monitor.lastSampleAt?.formatted(date: .omitted, time: .standard) ?? "—")")
                                .font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }
                    } else {
                        NoteBox(text: "未连接：服务运行后显示真实内存占用。")
                    }
                }
            } right: {
                Panel(title: "设置值 vs 实际加载值") {
                    DataRow(name: "设置 Context", value: "\(store.config.context)")
                    DataRow(name: "实际 Context", value: engine.health?.context.map(String.init) ?? "待加载检测")
                    DataRow(name: "设置 KV", value: store.config.kvFormat)
                    DataRow(name: "KV 实际格式", value: actualKV)
                    DataRow(name: "每槽 Context", value: monitor.contextLimit.map(String.init) ?? "—")
                    if let fit = engine.health?.fit, !fit.isEmpty {
                        NoteBox(text: "Memory fit 公告：\(fit)")
                    }
                }
                Panel(title: "内存管理") {
                    NoteBox(text: "设置值和实际加载值分别显示：自动适配时，运行时可能调整可用上下文或缓存策略（/health 的 fit 字段与启动日志 fit: 行）。")
                }
            }
        }
    }

    var actualKV: String {
        // 从引擎日志解析 "KV format X for …"
        if let line = model.logs.lines.last(where: { $0.text.contains("KV format") }) {
            let parts = line.text.components(separatedBy: " ")
            if let i = parts.firstIndex(of: "format"), i + 1 < parts.count {
                return parts[i + 1]
            }
        }
        return engine.isRunning ? "见日志" : "待加载检测"
    }
}

struct GenerationView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: ConfigStore
    @EnvironmentObject var engine: EngineController
    private var _testOutput = State(initialValue: "")
    private var testOutput: String {
        get { _testOutput.wrappedValue }
        nonmutating set { _testOutput.wrappedValue = newValue }
    }
    private var _testing = State(initialValue: false)
    private var testing: Bool {
        get { _testing.wrappedValue }
        nonmutating set { _testing.wrappedValue = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DetailHead(title: "生成参数", subtitle: "请求级采样参数，随每次请求发送；启动级默认值另行映射。", onBack: { model.go(.home) })
            DetailBody {
                Panel(title: "采样设置") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            FieldLabel(text: "Temperature")
                            Spacer()
                            Text(String(format: "%.2f", store.config.temperature))
                                .font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.text)
                        }
                        Slider(value: $store.config.temperature, in: 0...2, step: 0.05).tint(Theme.accent)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            FieldLabel(text: "Top-p")
                            Spacer()
                            Text(String(format: "%.2f", store.config.topP))
                                .font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.text)
                        }
                        Slider(value: $store.config.topP, in: 0.05...1, step: 0.05).tint(Theme.accent)
                    }
                    StyledNumberField(label: "Top-k", value: $store.config.topK, hint: "0 = 不限制；采样至多 16 候选。")
                    StyledNumberField(label: "最大输出 Tokens（max_tokens）", value: $store.config.maxTokens)
                    SwitchRow(title: "思考模式", desc: "请求级 chat_template_kwargs.enable_thinking；启动默认 --reasoning。", isOn: $store.config.reasoning)
                    HStack(spacing: 10) {
                        ActionButton(label: testing ? "生成中…" : "发送测试请求", icon: .play, primary: true, disabled: testing || !engine.isRunning) {
                            Task { await sendTest() }
                        }
                        if !engine.isRunning {
                            Text("服务未运行").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                        }
                    }
                    if !testOutput.isEmpty {
                        MonoBlock(text: testOutput)
                    }
                }
            } right: {
                Panel(title: "请求参数预览") {
                    MonoBlock(text: previewJSON)
                    ActionButton(label: "复制 JSON", icon: .copy) {
                        copyToPasteboard(previewJSON)
                        model.notify("已复制请求参数。")
                    }
                }
                Panel(title: "请求与引擎") {
                    NoteBox(text: "采样参数通过 API 请求体传递（请求级），不映射成启动选项。启动级默认值（--temperature 等）仅在请求未指定时生效。")
                    DataRow(name: "启动默认 temperature", value: String(store.config.temperature))
                    DataRow(name: "启动默认 max-tokens", value: String(store.config.maxTokens))
                    DataRow(name: "启动默认 reasoning", value: store.config.reasoning ? "on" : "off")
                }
            }
        }
    }

    var previewJSON: String {
        let obj = store.config.requestSampling()
        let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(data: d, encoding: .utf8) ?? "{}"
    }

    func sendTest() async {
        testing = true
        testOutput = ""
        defer { testing = false }
        let api = engine.client(config: store.config, apiKey: store.apiKey)
        do {
            let result = try await api.chatStream(
                messages: [["role": "user", "content": "用一句话介绍你自己。"]],
                sampling: store.config.requestSampling()) { delta, reasoning in
                    Task { @MainActor in
                        if !reasoning.isEmpty { testOutput += "[思考] " + reasoning }
                        if !delta.isEmpty { testOutput += delta }
                    }
                }
            testOutput += "\n\n—— TTFT \(String(format: "%.0f", result.ttftMs)) ms · 输出 \(result.text.count) 字符"
        } catch {
            testOutput = "请求失败：\(error.localizedDescription)"
        }
    }
}