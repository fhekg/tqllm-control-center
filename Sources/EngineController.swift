import Foundation
import AppKit
import SwiftUI

/// tqLLM 进程控制层：只通过官方 `tqllm serve / stop` 管理子进程。
/// 所有权判定：server.pid 与应用记录的启动 pid 对比；外部服务需确认后才可停止。
@MainActor
final class EngineController: ObservableObject {
    enum State: String {
        case stopped = "已停止"
        case starting = "启动中"
        case running = "运行中"
        case stopping = "停止中"
        case fault = "故障"
    }
    enum Ownership: String {
        case none = "—"
        case app = "本应用启动"
        case externalCLI = "外部终端（tqllm CLI）启动"
        case foreign = "其他程序占用端口"
    }

    @Published var state: State = .stopped
    @Published var ownership: Ownership = .none
    @Published var health: HealthInfo?
    @Published var servedModel: String?
    @Published var pid: Int?
    @Published var lastError: String?
    @Published var statusDetail: String = "尚未连接"
    @Published var launchedArguments: [String] = []
    @Published var launchOutput: String = ""
    @Published var busy = false
    @Published var preflightIssues: [String] = []

    private var appLaunchedPid: Int?
    private var pollTask: Task<Void, Never>?
    private var cliProcess: Process?
    private var startDeadline: Date?

    let stateDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/tqllm")
    var pidFileURL: URL { stateDir.appendingPathComponent("server.pid") }
    var serverLogURL: URL { stateDir.appendingPathComponent("server.log") }

    var isRunning: Bool { state == .running }
    var canStop: Bool { ownership == .app || ownership == .externalCLI }

    func client(config: EngineConfig, apiKey: String?) -> APIClient {
        APIClient(host: config.host, port: config.port, apiKey: apiKey)
    }

    func startPolling(store: ConfigStore) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce(store: store)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func pollOnce(store: ConfigStore) async {
        let cfg = store.config
        let api = client(config: cfg, apiKey: store.apiKey)
        do {
            let h = try await api.health()
            health = h
            let m = try? await api.models()
            let owned = m?.data.first?.owned_by
            servedModel = m?.data.first?.id
            if owned == "tqllm" {
                let filePid = readPidFile()
                pid = filePid
                if let mine = appLaunchedPid, filePid == mine {
                    ownership = .app
                } else if filePid != nil {
                    ownership = .externalCLI
                } else {
                    ownership = .externalCLI
                }
                if state != .running && state != .stopping {
                    state = .running
                    statusDetail = "服务就绪 · \(cfg.host):\(cfg.port)"
                    lastError = nil
                }
                if state == .running {
                    statusDetail = "服务就绪 · \(cfg.host):\(cfg.port) · context \(h.context ?? 0)"
                }
            } else {
                ownership = .foreign
                state = .fault
                lastError = "端口 \(cfg.port) 被其他程序占用（服务 \(m?.data.first?.id ?? "未知")），请更换端口或停止该程序。"
                statusDetail = "端口冲突"
            }
        } catch let e as APIError {
            if case .http = e {
                // 服务有 HTTP 响应但拒绝请求（如长上下文 prefill 期间 "too many connections"）：
                // 引擎仍在运行，不能误判为停止。
                health = nil
                if state != .stopping && state != .fault {
                    state = .running
                    statusDetail = "服务繁忙（长请求处理中，遥测暂不可用）"
                }
            } else {
                health = nil
                servedModel = nil
                if state == .starting {
                    if let deadline = startDeadline, Date() > deadline {
                        state = .fault
                        lastError = "启动超时。查看运行日志排查。"
                        statusDetail = "启动超时"
                    } else if let p = readPidFile(), !processAlive(p) {
                        state = .fault
                        lastError = "引擎进程已退出（pid \(p)）。查看运行日志排查（模型缺失/内存不足/参数错误）。"
                        statusDetail = "启动失败"
                    }
                } else if state == .stopping {
                    state = .stopped
                    ownership = .none
                    pid = nil
                    statusDetail = "服务已停止"
                } else if state != .fault {
                    state = .stopped
                    ownership = .none
                    pid = nil
                    statusDetail = "未检测到服务（\(cfg.host):\(cfg.port)）"
                }
            }
        } catch {
            health = nil
            servedModel = nil
            if state == .starting {
                if let deadline = startDeadline, Date() > deadline {
                    state = .fault
                    lastError = "启动超时。查看运行日志排查。"
                    statusDetail = "启动超时"
                } else if let p = cliProcess, !p.isRunning {
                    state = .fault
                    lastError = "启动进程退出（code \(p.terminationStatus)）。\(launchOutput.suffix(500))"
                    statusDetail = "启动失败"
                }
            } else if state == .stopping {
                state = .stopped
                ownership = .none
                pid = nil
                statusDetail = "服务已停止"
            } else if state != .fault {
                state = .stopped
                ownership = .none
                pid = nil
                statusDetail = "未检测到服务（\(cfg.host):\(cfg.port)）"
            }
        }
    }

    private func readPidFile() -> Int? {
        guard let s = try? String(contentsOf: pidFileURL, encoding: .utf8) else { return nil }
        return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 进程是否存活（kill 0 探测）。启动器分离后，用 pid 文件判断引擎本体是否崩溃。
    private func processAlive(_ pid: Int) -> Bool {
        kill(Int32(pid), 0) == 0
    }

    // MARK: 启动前检查（磁盘探测带超时，绝不阻塞主线程）

    func preflight(config: EngineConfig, qsaCapable: Bool) async -> [String] {
        var issues: [String] = []
        let fm = FileManager.default
        if !fm.isExecutableFile(atPath: config.cliPath) {
            issues.append("CLI 不存在或不可执行：\(config.cliPath)")
        }
        var paths = [config.modelFile]
        if config.draftMode == .dflash2 { paths.append(config.draftFile) }
        let stats = await ModelScanner.statWithTimeout(paths.filter { !$0.isEmpty })
        if config.modelFile.isEmpty {
            issues.append("主模型文件未设置。")
        } else if stats[config.modelFile] == nil {
            issues.append("外置硬盘无响应（stat 超时）：\(config.modelFile)。等待磁盘唤醒或重新挂载后重试。")
        } else if stats[config.modelFile] == false {
            issues.append("主模型文件不存在：\(config.modelFile)（外置硬盘可能未挂载）")
        }
        if config.draftMode == .dflash2 {
            if stats[config.draftFile] == nil {
                issues.append("草稿模型路径无响应（stat 超时）：\(config.draftFile)")
            } else if stats[config.draftFile] == false {
                issues.append("草稿模型文件不存在：\(config.draftFile)")
            }
        }
        if config.draftMode == .mtp && config.parallel != 1 {
            issues.append("MTP 模式要求并发为 1，已自动按 1 启动。")
        }
        // Apple Silicon MLX 后端强制要求 DFlash2 草稿（tqserve: the MLX backend needs the DFlash2 drafter）。
        if config.draftMode == .off {
            issues.append("本机 MLX 后端不支持无草稿模式（引擎要求必须加载 DFlash2 草稿）。请选择 DFlash2。")
        }
        if config.draftMode == .mtp {
            issues.append("本机 MLX 后端不支持 MTP 模式（--mtp 排除 -md，而 MLX 要求 DFlash2 草稿）。请选择 DFlash2。")
        }
        if config.qsaEnabled && !qsaCapable {
            issues.append("当前主模型不含 QSA 索引，QSA 开关不会生效。")
        }
        if config.qsaEnabled && config.qsaFrom < 4096 {
            issues.append("QSA 阈值必须 ≥ 4096。")
        }
        return issues
    }

    // MARK: 启动（直接托管 tqserve，argv 完全由配置决定）
    //
    // 不经过 `tqllm serve`：CLI 的 serve_args 在给定 --model 时会自动补默认 DFlash2 草稿，
    // 导致「关闭」档无法真正无草稿（假开关）。这里直接调用引擎二进制 tqserve，
    // 复用官方 start_background 的分离机制（venv Python：start_new_session + server.pid + server.log），
    // 使 dflash2 / mtp / off 三档都精确对应 UI。停止仍用官方 tqllm stop（killpg pid 文件）。

    /// 从 cliPath 推导 venv 的 python 与 tqserve 路径。
    func enginePaths(cliPath: String) -> (python: String, tqserve: String)? {
        let fm = FileManager.default
        let resolved = (try? fm.destinationOfSymbolicLink(atPath: cliPath)) ?? cliPath
        let abs = resolved.hasPrefix("/") ? resolved : ((cliPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent(resolved)
        let binDir = (abs as NSString).deletingLastPathComponent
        let venvRoot = (binDir as NSString).deletingLastPathComponent
        let python = (binDir as NSString).appendingPathComponent("python")
        guard fm.isExecutableFile(atPath: python) else { return nil }
        let libDir = (venvRoot as NSString).appendingPathComponent("lib")
        guard let pyDirs = try? fm.contentsOfDirectory(atPath: libDir) else { return nil }
        for py in pyDirs where py.hasPrefix("python") {
            let candidate = (libDir as NSString).appendingPathComponent("\(py)/site-packages/tqllm/bin/tqserve")
            if fm.isExecutableFile(atPath: candidate) { return (python, candidate) }
        }
        return nil
    }

    func start(store: ConfigStore, qsaCapable: Bool) async {
        guard !busy else { return }
        let cfg = store.config
        let issues = await preflight(config: cfg, qsaCapable: qsaCapable)
        preflightIssues = issues
        if issues.contains(where: { !$0.hasPrefix("MTP") && !$0.hasPrefix("当前主模型") }) {
            state = .fault
            lastError = issues.joined(separator: "\n")
            return
        }
        guard let paths = enginePaths(cliPath: cfg.cliPath) else {
            state = .fault
            lastError = "无法从 CLI 路径推导 tqserve / venv python：\(cfg.cliPath)"
            return
        }
        busy = true
        state = .starting
        lastError = nil
        launchOutput = ""
        statusDetail = "正在启动 tqserve…"
        startDeadline = Date().addingTimeInterval(900)

        let keyFile = store.materializeAPIKeyFile()
        let serveArgs = cfg.serveArguments(apiKeyFile: keyFile, qsaCapable: qsaCapable)
        launchedArguments = [paths.tqserve] + serveArgs

        // 官方分离启动脚本：Popen(start_new_session=True)，日志追加 server.log，pid 写 server.pid。
        // tqserve 与参数经 argv 传入（避免路径含空格/中文的注入问题），日志/pid 路径经环境变量传入。
        let launcher = """
        import os, subprocess, sys
        argv = sys.argv[1:]
        log = open(os.environ['TQCC_LOG'], 'ab')
        p = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT,
                             stdin=subprocess.DEVNULL, start_new_session=True)
        open(os.environ['TQCC_PID'], 'w').write(str(p.pid))
        print('launched pid', p.pid)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: paths.python)
        process.arguments = ["-c", launcher, paths.tqserve] + serveArgs
        var env = ProcessInfo.processInfo.environment
        env["TQCC_LOG"] = serverLogURL.path
        env["TQCC_PID"] = pidFileURL.path
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        cliProcess = process
        do {
            try process.run()
            process.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            launchOutput += out
            guard process.terminationStatus == 0 else {
                state = .fault
                lastError = "启动器退出（code \(process.terminationStatus)）：\(out.suffix(400))"
                busy = false
                return
            }
        } catch {
            state = .fault
            lastError = "无法运行启动器：\(error.localizedDescription)"
            busy = false
            return
        }
        if let p = readPidFile() { appLaunchedPid = p }
        // 轮询 /health 直至就绪或超时（pollOnce 负责状态迁移与所有权判定）。
        while Date() < startDeadline! {
            await pollOnce(store: store)
            if state == .running || state == .fault { break }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        if state == .starting {
            state = .fault
            lastError = "启动超时（900s）。查看运行日志排查。"
        }
        busy = false
    }

    // MARK: 停止（只走官方 tqllm stop，绝不 pkill）

    func stop(store: ConfigStore, confirmedExternal: Bool = false) async -> Bool {
        guard !busy else { return false }
        if ownership == .foreign {
            lastError = "端口由其他程序占用，本应用不会停止它。"
            return false
        }
        if ownership == .externalCLI && !confirmedExternal {
            lastError = "服务由外部终端启动，需确认后才能停止。"
            return false
        }
        busy = true
        state = .stopping
        statusDetail = "正在停止…"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: store.config.cliPath)
        p.arguments = ["stop"]
        var env = ProcessInfo.processInfo.environment
        env["TQLLM_HOME"] = stateDir.path
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            launchOutput += "\n[stop] " + out
        } catch {
            lastError = "停止命令失败：\(error.localizedDescription)"
        }
        // 等待端口释放
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let api = client(config: store.config, apiKey: store.apiKey)
            if (try? await api.health()) == nil { break }
        }
        appLaunchedPid = nil
        busy = false
        await pollOnce(store: store)
        return state == .stopped
    }

    func restart(store: ConfigStore, qsaCapable: Bool) async {
        if isRunning || ownership == .externalCLI {
            _ = await stop(store: store, confirmedExternal: true)
        }
        await start(store: store, qsaCapable: qsaCapable)
    }

    /// 应用退出时按设置决定是否停止本应用启动的服务。
    func shutdownIfNeeded(store: ConfigStore) {
        guard store.config.stopOnQuit, ownership == .app else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: store.config.cliPath)
        p.arguments = ["stop"]
        var env = ProcessInfo.processInfo.environment
        env["TQLLM_HOME"] = stateDir.path
        p.environment = env
        try? p.run()
        p.waitUntilExit()
    }

    /// 版本从 venv 的 dist-info 读取（CLI 无 --version 命令）。
    func cliVersion(cliPath: String) -> String {
        let fm = FileManager.default
        let resolved = (try? fm.destinationOfSymbolicLink(atPath: cliPath)) ?? cliPath
        let abs = resolved.hasPrefix("/") ? resolved : ((cliPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent(resolved)
        let binDir = (abs as NSString).deletingLastPathComponent
        let venvRoot = (binDir as NSString).deletingLastPathComponent
        let libDir = (venvRoot as NSString).appendingPathComponent("lib")
        guard let pyDirs = try? fm.contentsOfDirectory(atPath: libDir) else { return "未知" }
        for py in pyDirs where py.hasPrefix("python") {
            let sp = (libDir as NSString).appendingPathComponent("\(py)/site-packages")
            guard let entries = try? fm.contentsOfDirectory(atPath: sp) else { continue }
            for e in entries where e.hasPrefix("tqllm-") && e.hasSuffix(".dist-info") {
                return String(e.dropFirst("tqllm-".count).dropLast(".dist-info".count))
            }
        }
        return "未知"
    }
}