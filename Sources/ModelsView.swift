import SwiftUI

struct ModelsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var scanner: ModelScanner
    @EnvironmentObject var store: ConfigStore
    @EnvironmentObject var engine: EngineController

    var selectedMain: ScannedModel? { scanner.models.first { $0.path == store.config.modelFile } }
    var selectedDraft: ScannedModel? { scanner.models.first { $0.path == store.config.draftFile } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DetailHead(title: "模型管理", subtitle: "扫描本地目录，识别主模型、QSA 索引与草稿模型；只引用现有文件，不移动、不下载。", onBack: { model.go(.home) })
            DetailBody {
                Panel(title: "模型与目录") {
                    HStack(alignment: .bottom, spacing: 8) {
                        StyledTextField(label: "模型存储目录", text: $store.config.modelDir, hint: "外置硬盘目录；断开时给出错误提示。", mono: true)
                        ActionButton(label: "选择", icon: .folder) {
                            if let d = chooseDirectory() { store.config.modelDir = d }
                        }
                    }
                    StyledTextField(label: "主模型文件路径", text: $store.config.modelFile, mono: true)
                    StyledTextField(label: "草稿模型路径（-md，需 GGUF）", text: $store.config.draftFile, mono: true)
                    HStack(spacing: 10) {
                        ActionButton(label: scanner.scanning ? "扫描中…" : "扫描模型", icon: .folder, primary: true, disabled: scanner.scanning) {
                            Task {
                                scanner.startProbing(modelPath: store.config.modelFile, draftPath: store.config.draftFile)
                                await scanner.scan(dirs: [store.config.modelDir,
                                                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/tqllm/models").path])
                                model.notify(scanner.scanError ?? "扫描完成：\(scanner.models.count) 个 GGUF 文件。")
                            }
                        }
                        ActionButton(label: "选择主模型", icon: .layers) {
                            if let p = chooseFile(extensions: ["gguf"]) { store.config.modelFile = p }
                        }
                        ActionButton(label: "选择草稿", icon: .brain) {
                            if let p = chooseFile(extensions: ["gguf"]) { store.config.draftFile = p }
                        }
                    }
                    if let err = scanner.scanError {
                        NoteBox(text: err, warn: true)
                    }
                }
                Panel(title: "扫描结果") {
                    if scanner.models.isEmpty {
                        NoteBox(text: "尚未扫描或目录为空。点击“扫描模型”读取 GGUF 元数据（只读头部，不加载权重）。")
                    } else {
                        ForEach(scanner.models) { m in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(m.fileName).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                                    Spacer()
                                    Text(ModelScanner.formatGB(m.sizeBytes)).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                                }
                                HStack(spacing: 6) {
                                    Pill(text: roleLabel(m), tone: m.role == .other ? .amber : .green)
                                    if m.info.qsaCapable { Pill(text: "QSA 索引 ✓", tone: .green) }
                                    if m.info.mtpCapable { Pill(text: "MTP 头 ✓", tone: .green) }
                                    if m.info.isDrafter { Pill(text: "草稿模型", tone: .neutral) }
                                    if let e = m.info.error { Pill(text: e, tone: .red) }
                                }
                                Text(prettyPath(m.path)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.muted).textSelection(.enabled)
                                HStack(spacing: 8) {
                                    if m.role == .main {
                                        ActionButton(label: store.config.modelFile == m.path ? "当前主模型 ✓" : "设为主模型") {
                                            store.config.modelFile = m.path
                                            model.notify("主模型已切换，重启服务后生效。")
                                        }
                                    }
                                    if m.role == .drafter {
                                        ActionButton(label: store.config.draftFile == m.path ? "当前草稿 ✓" : "设为草稿") {
                                            store.config.draftFile = m.path
                                            model.notify("草稿模型已切换，重启服务后生效。")
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 10)
                            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 0.5) }
                        }
                    }
                }
            } right: {
                Panel(title: "模型摘要") {
                    DataRow(name: "模型", value: store.config.modelName)
                    DataRow(name: "主模型文件", value: selectedMain?.fileName ?? "未扫描")
                    DataRow(name: "架构", value: selectedMain?.info.architecture ?? "—")
                    DataRow(name: "量化", value: quantLabel(selectedMain))
                    DataRow(name: "训练上下文", value: selectedMain.map { "\($0.info.contextLength)" } ?? "—")
                    DataRow(name: "QSA 索引状态", value: qsaStatus)
                    DataRow(name: "草稿兼容性", value: draftStatus)
                    DataRow(name: "文件大小", value: selectedMain.map { ModelScanner.formatGB($0.sizeBytes) } ?? "—")
                }
                Panel(title: "外部磁盘状态") {
                    HStack(spacing: 8) {
                        LineIcon(icon: .disk, size: 18).foregroundStyle(scanner.volumeMounted ? Theme.green : Theme.red)
                        Text(scanner.volumeMounted ? "移动硬盘已挂载" : "移动硬盘未挂载")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(scanner.volumeMounted ? Theme.green : Theme.red)
                    }
                    DataRow(name: "主模型可访问", value: scanner.modelFileExists ? "✓" : (scanner.diskResponsive ? "✗ 文件不可达" : "… 磁盘无响应"))
                    if let d = scanner.lastScan {
                        DataRow(name: "最近扫描", value: d.formatted(date: .omitted, time: .standard))
                    }
                    NoteBox(text: "硬盘断开时启动会被阻止并提示；重新挂载后点击“扫描模型”刷新。应用不会移动、覆盖、重命名或删除模型文件。", warn: !scanner.volumeMounted)
                }
                Panel(title: "GGUF 元数据") {
                    if let m = selectedMain {
                        MonoBlock(text: ggufSummary(m))
                    } else {
                        NoteBox(text: "扫描后显示主模型 GGUF 元数据。")
                    }
                }
            }
        }
    }

    func roleLabel(_ m: ScannedModel) -> String {
        switch m.role {
        case .main: return "主模型"
        case .drafter: return "草稿"
        case .other: return "未验证兼容"
        }
    }

    func quantLabel(_ m: ScannedModel?) -> String {
        guard let m else { return "未扫描" }
        if !m.info.quantNote.isEmpty { return m.info.quantNote }
        return "file_type \(m.info.fileType)（TQ 系）"
    }

    var qsaStatus: String {
        guard let m = selectedMain else { return "未验证" }
        if m.info.qsaCapable {
            return "✓ 兼容（阈值默认 \(m.info.qsaSparseFrom ?? 49152)）"
        }
        return "✗ 无 QSA 索引"
    }

    var draftStatus: String {
        guard let d = selectedDraft else { return "未验证" }
        if d.info.isDrafter { return "✓ DFlash2 GGUF，词表 \(d.info.vocabSize)" }
        return "✗ 非草稿架构"
    }

    func ggufSummary(_ m: ScannedModel) -> String {
        var lines = ["architecture: \(m.info.architecture)",
                     "name: \(m.info.name)",
                     "tensors: \(m.info.tensorCount)",
                     "context_length: \(m.info.contextLength)",
                     "block_count: \(m.info.blockCount)",
                     "file_type: \(m.info.fileType)",
                     "vocab: \(m.info.vocabSize)"]
        for (k, v) in m.info.qsaKeys.sorted(by: { $0.key < $1.key }) {
            lines.append("\(k): \(v)")
        }
        lines.append("qsa_tensors: \(m.info.hasQSATensors ? "present" : "absent")")
        lines.append("nextn_predict_layers: \(m.info.nextnPredictLayers)")
        return lines.joined(separator: "\n")
    }
}