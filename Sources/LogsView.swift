import SwiftUI

struct LogsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var logs: LogService
    @EnvironmentObject var engine: EngineController
    @EnvironmentObject var store: ConfigStore
    @EnvironmentObject var scanner: ModelScanner

    func logLineView(_ line: LogLine) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(line.source.rawValue)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(line.source == .app ? Theme.green : Theme.muted)
                .frame(width: 30, alignment: .leading)
            Text(line.text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(line.category == .errors ? Theme.red : Theme.text)
                .textSelection(.enabled)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DetailHead(title: "运行日志", subtitle: "官方 server.log 增量 tail + 应用事件；启动参数、请求与错误均可筛选导出。", onBack: { model.go(.home) })
            DetailBody {
                Panel(title: "日志查看器") {
                    HStack(spacing: 6) {
                        ForEach([("all", "全部"), ("startup", "启动"), ("requests", "请求"), ("errors", "错误")], id: \.0) { f in
                            Button {
                                logs.filter = f.0
                            } label: {
                                Text(f.1)
                                    .font(.system(size: 12.5, weight: logs.filter == f.0 ? .semibold : .regular))
                                    .foregroundStyle(logs.filter == f.0 ? Theme.paper : Theme.text)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(logs.filter == f.0 ? Theme.accent : Theme.soft)
                                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                        Text("\(logs.filtered.count) 行").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                    }
                    ScrollViewReader { proxy in
                        Group {
                            if RenderMode.active {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(logs.filtered.suffix(30)) { line in
                                        logLineView(line)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                            } else {
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 2) {
                                        ForEach(logs.filtered.suffix(500)) { line in
                                            logLineView(line)
                                                .id(line.id)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                                }
                                .onChange(of: logs.lines.count) {
                                    if logs.following, let last = logs.filtered.last {
                                        proxy.scrollTo(last.id, anchor: .bottom)
                                    }
                                }
                            }
                        }
                        .frame(height: 420, alignment: .top)
                        .background(Theme.soft)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 1))
                    }
                    HStack(spacing: 10) {
                        ActionButton(label: "诊断清单", icon: .info) {
                            let text = logs.diagnostics(engine: engine, store: store, scanner: scanner)
                            copyToPasteboard(text)
                            logs.event("诊断清单已生成并复制。")
                            model.notify("诊断清单已复制到剪贴板。")
                        }
                        ActionButton(label: "导出日志", icon: .save) {
                            savePanel(defaultName: "tqllm-logs.txt", content: logs.exportText())
                        }
                        Toggle("自动滚动", isOn: $logs.following)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))
                    }
                }
                Panel(title: "启动参数记录") {
                    MonoBlock(text: engine.launchedArguments.isEmpty ? "本应用尚未启动过服务。" : engine.launchedArguments.joined(separator: " "))
                }
            } right: {
                Panel(title: "运行前检查项") {
                    DataRow(name: "可执行文件", value: FileManager.default.isExecutableFile(atPath: store.config.cliPath) ? "✓ 已检测" : "✗ 缺失")
                    DataRow(name: "模型文件", value: FileManager.default.fileExists(atPath: store.config.modelFile) ? "✓ 已检测" : "✗ 缺失")
                    DataRow(name: "API 监听端口", value: engine.isRunning ? "✓ \(store.config.port)" : "未监听")
                    DataRow(name: "日志目录", value: FileManager.default.fileExists(atPath: engine.stateDir.path) ? "✓ \(engine.stateDir.path)" : "将自动创建")
                }
                Panel(title: "错误诊断") {
                    let errs = logs.lines.filter { $0.category == .errors }.suffix(6)
                    if errs.isEmpty {
                        NoteBox(text: "暂无错误记录。")
                    } else {
                        ForEach(Array(errs)) { e in
                            Text(e.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.red)
                                .padding(.vertical, 3)
                        }
                    }
                    if let err = engine.lastError {
                        NoteBox(text: err, warn: true)
                    }
                }
                Panel(title: "日志说明") {
                    NoteBox(text: "引擎日志来自 ~/.cache/tqllm/server.log（tqllm 官方位置），应用事件单独标注。不制造虚假成功事件；密钥不会写入日志。")
                }
            }
        }
    }
}

struct PresetsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: ConfigStore
    @EnvironmentObject var engine: EngineController
    private var _presetName = State(initialValue: "我的 M5 Pro 配置")
    private var presetName: String {
        get { _presetName.wrappedValue }
        nonmutating set { _presetName.wrappedValue = newValue }
    }
    private var _importError = State<String?>(initialValue: nil)
    private var importError: String? {
        get { _importError.wrappedValue }
        nonmutating set { _importError.wrappedValue = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DetailHead(title: "配置预设", subtitle: "内置三种方案 + 自定义保存；应用后重启服务生效，可导出 / 导入 JSON。", onBack: { model.go(.home) })
            DetailBody {
                Panel(title: "内置预设") {
                    presetCard(BuiltInPresets.daily, desc: "32K · 普通问答 · 兼顾响应速度")
                    presetCard(BuiltInPresets.long, desc: "128K · QSA 阈值 48K · 长文档任务")
                    presetCard(BuiltInPresets.bench, desc: "64K · 统一采样 · DFlash2 基线（MLX 后端强制草稿）")
                }
                Panel(title: "自定义预设") {
                    StyledTextField(label: "配置名称", text: _presetName.projectedValue)
                    HStack(spacing: 10) {
                        ActionButton(label: "保存预设", icon: .save, primary: true) {
                            store.saveCustom(name: presetName.isEmpty ? "未命名预设" : presetName)
                            model.notify("已保存预设“\(presetName)”。")
                        }
                        ActionButton(label: "恢复默认配置", icon: .refresh) {
                            var c = EngineConfig()
                            c.cliPath = store.config.cliPath
                            c.modelDir = store.config.modelDir
                            c.modelFile = store.config.modelFile
                            c.draftFile = store.config.draftFile
                            c.host = store.config.host
                            c.port = store.config.port
                            c.autoStart = store.config.autoStart
                            c.stopOnQuit = store.config.stopOnQuit
                            store.config = c
                            model.notify("已恢复默认配置，重启服务后生效。")
                        }
                        ActionButton(label: "导出 JSON", icon: .copy) {
                            savePanel(defaultName: "tqllm-control-center-config.json", content: store.exportJSON())
                            model.notify("已导出 JSON（不包含 API Key）。")
                        }
                        ActionButton(label: "导入 JSON", icon: .folder) {
                            if let text = openPanel() {
                                if let err = store.importJSON(text) {
                                    importError = err
                                } else {
                                    importError = nil
                                    model.notify("配置已导入。重启服务后生效。")
                                }
                            }
                        }
                    }
                    if let err = importError { NoteBox(text: err, warn: true) }
                    if store.customPresets.isEmpty {
                        NoteBox(text: "还没有自定义预设。")
                    } else {
                        ForEach(store.customPresets) { p in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                                    Text("context \(p.config.context) · KV \(p.config.kvFormat) · \(p.config.draftMode.label)")
                                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                ActionButton(label: "应用") {
                                    store.apply(p)
                                    model.notify("已应用“\(p.name)”，重启服务后生效。")
                                }
                                ActionButton(label: "删除") { store.deleteCustom(p) }
                            }
                            .padding(.vertical, 8)
                            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 0.5) }
                        }
                    }
                }
            } right: {
                Panel(title: "当前配置摘要") {
                    DataRow(name: "Context", value: "\(store.config.context)")
                    DataRow(name: "QSA", value: store.config.qsaEnabled ? "开 · \(store.config.qsaFrom)" : "关")
                    DataRow(name: "KV", value: store.config.kvFormat)
                    DataRow(name: "推测解码", value: store.config.draftMode.label)
                    DataRow(name: "采样", value: String(format: "T %.2f · p %.2f · k %d", store.config.temperature, store.config.topP, store.config.topK))
                    DataRow(name: "服务状态", value: engine.state.rawValue)
                    if engine.isRunning {
                        NoteBox(text: "预设修改的是下次启动的配置；点击服务控制页“重启服务”应用。", warn: true)
                    }
                }
                Panel(title: "持久化说明") {
                    NoteBox(text: "配置与预设保存在 ~/Library/Application Support/tqLLM-Control-Center/（config.json / presets.json）。API Key 只存 macOS Keychain，导出 JSON 不含密钥。")
                }
            }
        }
    }

    func presetCard(_ p: Preset, desc: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(p.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(desc).font(.system(size: 12)).foregroundStyle(Theme.muted)
            ActionButton(label: "应用\(p.name)配置") {
                store.apply(p)
                model.notify("已应用“\(p.name)”，重启服务后生效。")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.soft)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
    }
}