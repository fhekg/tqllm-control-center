import Foundation
import AppKit
import SwiftUI

struct ScannedModel: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let fileName: String
    let sizeBytes: UInt64
    let info: GGUFInfo
    var role: Role {
        if info.isDrafter { return .drafter }
        if info.architecture == "qwen35" { return .main }
        return .other
    }
    enum Role { case main, drafter, other }
}

@MainActor
final class ModelScanner: ObservableObject {
    @Published var models: [ScannedModel] = []
    @Published var scanning = false
    @Published var volumeMounted = true
    @Published var lastScan: Date? = nil
    @Published var scanError: String? = nil
    // 磁盘探测缓存：外置盘停滞时 stat 会阻塞，全部在后台线程做，主线程只读缓存。
    @Published var modelFileExists = false
    @Published var draftFileExists = false
    @Published var diskResponsive = true
    private var probeTask: Task<Void, Never>?

    private var mountObserver: Any?
    private var unmountObserver: Any?

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        mountObserver = nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.checkVolume() }
        }
        unmountObserver = nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.checkVolume() }
        }
        checkVolume()
    }

    func startProbing(modelPath: String, draftPath: String) {
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                let r: (Bool, Bool, Bool) = await Task.detached(priority: .utility) {
                    let fm = FileManager.default
                    let t0 = Date()
                    let m = fm.fileExists(atPath: modelPath)
                    let d = fm.fileExists(atPath: draftPath)
                    let responsive = Date().timeIntervalSince(t0) < 5
                    return (m, d, responsive)
                }.value
                guard let self else { return }
                self.modelFileExists = r.0
                self.draftFileExists = r.1
                self.diskResponsive = r.2
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    func checkVolume() {
        volumeMounted = FileManager.default.fileExists(atPath: "/Volumes/移动硬盘")
    }

    var mainModel: ScannedModel? { models.first { $0.role == .main && $0.info.qsaCapable } ?? models.first { $0.role == .main } }
    var drafter: ScannedModel? { models.first { $0.role == .drafter } }

    /// 扫描配置目录 + tqLLM 默认模型缓存目录。只读，不移动/改名/删除任何文件。
    /// 全部文件 IO 在后台线程执行，避免外置盘唤醒阻塞主线程。
    func scan(dirs: [String]) async {
        scanning = true
        scanError = nil
        checkVolume()
        let result: (models: [ScannedModel], error: String?) = await Task.detached(priority: .utility) {
            let fm = FileManager.default
            var candidates: [String] = []
            for dir in dirs {
                guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for e in entries where e.lowercased().hasSuffix(".gguf") {
                    candidates.append((dir as NSString).appendingPathComponent(e))
                }
            }
            var found: [String: ScannedModel] = [:]
            for path in candidates {
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let size = attrs[.size] as? UInt64 else { continue }
                let info = GGUFReader.read(path: path)
                found[path] = ScannedModel(path: path, fileName: (path as NSString).lastPathComponent, sizeBytes: size, info: info)
            }
            let models = found.values.sorted { $0.fileName < $1.fileName }
            let mounted = fm.fileExists(atPath: "/Volumes/移动硬盘")
            let err: String? = models.isEmpty ? (mounted ? "目录中没有找到 GGUF 文件。" : "外置硬盘未挂载或目录不可访问。") : nil
            return (models, err)
        }.value
        models = result.models
        scanError = result.error
        volumeMounted = FileManager.default.fileExists(atPath: "/Volumes/移动硬盘")
        lastScan = Date()
        scanning = false
    }

    static func formatGB(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    /// 带超时的后台 stat：外置盘停滞时不阻塞调用方（主线程）。nil = 超时无响应。
    static func statWithTimeout(_ paths: [String], timeout: TimeInterval = 8) async -> [String: Bool?] {
        await withTaskGroup(of: [String: Bool?].self) { group in
            group.addTask(priority: .utility) {
                var out: [String: Bool?] = [:]
                let fm = FileManager.default
                for p in paths { out[p] = fm.fileExists(atPath: p) }
                return out
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return [:]
            }
            let first = await group.next() ?? [:]
            group.cancelAll()
            if first.isEmpty {
                var out: [String: Bool?] = [:]
                for p in paths { out[p] = nil }
                return out
            }
            return first
        }
    }
}