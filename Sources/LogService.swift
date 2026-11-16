import Foundation
import SwiftUI

struct LogLine: Identifiable {
    let id = UUID()
    let at: Date
    let source: Source
    let text: String
    enum Source: String { case engine = "引擎", app = "应用" }
    var category: Category {
        let t = text.lowercased()
        if t.contains("error") || t.contains("failed") || t.contains("warning") || t.contains("refused") || t.contains("故障") || t.contains("失败") {
            return .errors
        }
        if t.contains("loading model") || t.contains("listening") || t.contains("fit:") || t.contains("mlx backend") || t.contains("kv format") || t.contains("starting") || t.contains("server ready") || t.contains("启动") {
            return .startup
        }
        if t.contains("request") || t.contains("kv format bf16 for") || t.contains("prefilled") || t.contains("first steps") || t.contains("请求") {
            return .requests
        }
        return .other
    }
    enum Category { case startup, requests, errors, other }
}

/// 运行日志层：增量 tail 官方 server.log + 应用事件日志；筛选与导出。
@MainActor
final class LogService: ObservableObject {
    @Published var lines: [LogLine] = []
    @Published var filter: String = "all"
    @Published var following = true
    private var offset: UInt64 = 0
    private var task: Task<Void, Never>?
    private let cap = 6000
    private var logPath: String = ""

    var filtered: [LogLine] {
        switch filter {
        case "startup": return lines.filter { $0.category == .startup }
        case "requests": return lines.filter { $0.category == .requests }
        case "errors": return lines.filter { $0.category == .errors }
        default: return lines
        }
    }

    func event(_ text: String) {
        lines.append(LogLine(at: Date(), source: .app, text: text))
        trim()
    }

    func start(engineLogURL: URL) {
        logPath = engineLogURL.path
        // 从文件末尾开始，只读新增；首次载入最后 200 行作为上下文
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
           let size = attrs[.size] as? UInt64 {
            offset = size
            loadTail(bytes: 64 * 1024)
        }
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.readNew()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func loadTail(bytes: UInt64) {
        guard let fh = FileHandle(forReadingAtPath: logPath) else { return }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = size > bytes ? size - bytes : 0
        try? fh.seek(toOffset: start)
        guard let d = try? fh.readToEnd(), let s = String(data: d, encoding: .utf8) else { return }
        let parts = s.components(separatedBy: "\n").filter { !$0.isEmpty }
        for p in parts.suffix(200) {
            lines.append(LogLine(at: Date(), source: .engine, text: p))
        }
        trim()
    }

    private func readNew() async {
        guard !logPath.isEmpty,
              let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
              let size = attrs[.size] as? UInt64 else { return }
        if size < offset { offset = 0; event("[日志] server.log 被重置，从头读取。") }
        guard size > offset else { return }
        guard let fh = FileHandle(forReadingAtPath: logPath) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: offset)
        guard let d = try? fh.readToEnd() else { return }
        offset = size
        guard let s = String(data: d, encoding: .utf8) else { return }
        for p in s.components(separatedBy: "\n") where !p.isEmpty {
            lines.append(LogLine(at: Date(), source: .engine, text: p))
        }
        trim()
    }

    private func trim() {
        if lines.count > cap { lines.removeFirst(lines.count - cap) }
    }

    func exportText() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return filtered.map { "[\(fmt.string(from: $0.at))] [\($0.source.rawValue)] \($0.text)" }.joined(separator: "\n")
    }

    /// 错误诊断清单：基于真实状态生成。
    func diagnostics(engine: EngineController, store: ConfigStore, scanner: ModelScanner) -> String {
        var out = ["tqLLM Control Center 诊断清单 · \(ISO8601DateFormatter().string(from: Date()))"]
        out.append("1. CLI：\(store.config.cliPath) \(FileManager.default.isExecutableFile(atPath: store.config.cliPath) ? "✓ 可执行" : "✗ 不可执行")")
        out.append("2. 主模型：\(store.config.modelFile) \(scanner.modelFileExists ? "✓ 存在" : (scanner.diskResponsive ? "✗ 缺失" : "… 磁盘无响应"))")
        out.append("3. 草稿模型：\(store.config.draftFile) \(scanner.draftFileExists ? "✓ 存在" : "✗ 缺失或无响应")")
        out.append("4. 外置硬盘：\(scanner.volumeMounted ? "✓ 已挂载" : "✗ 未挂载")")
        out.append("5. 服务状态：\(engine.state.rawValue) · 归属 \(engine.ownership.rawValue) · PID \(engine.pid.map(String.init) ?? "—")")
        out.append("6. 健康：\(engine.health.map { "status=\($0.status ?? "?") context=\($0.context ?? 0)" } ?? "无响应")")
        if let fit = engine.health?.fit, !fit.isEmpty { out.append("7. Memory fit：\(fit)") }
        if let err = engine.lastError { out.append("8. 最近错误：\(err)") }
        let errs = lines.filter { $0.category == .errors }.suffix(8)
        if !errs.isEmpty {
            out.append("9. 最近错误日志：")
            out.append(contentsOf: errs.map { "   " + $0.text })
        }
        return out.joined(separator: "\n")
    }
}