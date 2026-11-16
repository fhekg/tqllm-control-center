import SwiftUI

struct ServiceView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var engine: EngineController
    @EnvironmentObject var store: ConfigStore
    @EnvironmentObject var logs: LogService

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DetailHead(title: "服务控制", subtitle: "顶部工具栏可全局启停；此页管理路径、自动启动与启动策略。", onBack: { model.go(.home) })
            DetailBody {
                Panel(title: "启动环境") {
                    StyledTextField(label: "tqLLM 可执行文件", text: $store.config.cliPath,
                                    hint: "已核验：\(FileManager.default.isExecutableFile(atPath: store.config.cliPath) ? "文件存在且可执行" : "不存在或不可执行")", mono: true)
                    SwitchRow(title: "登录时自动启动", desc: "通过 macOS SMAppService 注册登录项。\(store.autoStartStatus)", isOn: Binding(
                        get: { store.config.autoStart },
                        set: { store.setAutoStart($0) }))
                    SwitchRow(title: "退出应用时停止服务", desc: "默认关闭：应用退出后服务继续运行（与官方 tqllm 行为一致）。", isOn: $store.config.stopOnQuit)
                    HStack(spacing: 10) {
                        ActionButton(label: "检查环境", icon: .info) { checkEnvironment() }
                        ActionButton(label: "重新检测状态", icon: .refresh) { model.notify("状态每 2 秒自动轮询。") }
                    }
                }
                Panel(title: "启动策略") {
                    NoteBox(text: "启动前自动检查 CLI、模型文件、外置硬盘与端口。停止只调用官方 tqllm stop（按 pid 文件精确停止），不会结束其他同名进程。外部终端启动的服务需确认后才停止。", warn: true)
                    HStack(spacing: 10) {
                        ActionButton(label: engine.isRunning ? "重启服务" : "启动服务", icon: .refresh, primary: true, disabled: engine.busy) {
                            Task {
                                if engine.isRunning {
                                    await engine.restart(store: store, qsaCapable: model.qsaCapable)
                                } else {
                                    await engine.start(store: store, qsaCapable: model.qsaCapable)
                                }
                                model.notify(engine.isRunning ? "服务运行中。" : (engine.lastError ?? "启动失败"))
                            }
                        }
                        ActionButton(label: "停止服务", disabled: engine.busy || !engine.canStop) {
                            Task {
                                if engine.ownership == .externalCLI {
                                    let ok = confirmExternalStop()
                                    guard ok else { return }
                                    _ = await engine.stop(store: store, confirmedExternal: true)
                                } else {
                                    _ = await engine.stop(store: store)
                                }
                            }
                        }
                    }
                    if !engine.preflightIssues.isEmpty {
                        NoteBox(text: engine.preflightIssues.joined(separator: "\n"), warn: true)
                    }
                }
                Panel(title: "启动参数预览") {
                    MonoBlock(text: previewCommand)
                    HStack {
                        ActionButton(label: "复制命令", icon: .copy) {
                            copyToPasteboard(previewCommand)
                            model.notify("已复制启动命令。")
                        }
                        Spacer()
                        RestartBadge()
                    }
                }
            } right: {
                Panel(title: "当前设置") {
                    DataRow(name: "执行路径", value: store.config.cliPath, mono: true)
                    DataRow(name: "CLI 版本", value: model.cliVersion)
                    DataRow(name: "服务端口", value: "\(store.config.host):\(store.config.port)")
                    DataRow(name: "运行状态", value: engine.state.rawValue)
                    DataRow(name: "进程归属", value: engine.ownership.rawValue)
                    DataRow(name: "进程 PID", value: engine.pid.map(String.init) ?? "—")
                    DataRow(name: "引擎 build", value: engine.health?.engine ?? "—")
                    DataRow(name: "可用 CLI 命令", value: "serve · stop · pull · claude/codex/opencode")
                    DataRow(name: "日志文件", value: engine.serverLogURL.path, mono: true)
                }
                Panel(title: "健康检查") {
                    DataRow(name: "GET /health", value: engine.health?.status ?? "无响应")
                    DataRow(name: "引擎 context", value: engine.health?.context.map(String.init) ?? "—")
                    if let fit = engine.health?.fit, !fit.isEmpty {
                        DataRow(name: "Memory fit", value: fit)
                    }
                    if let err = engine.lastError {
                        NoteBox(text: err, warn: true)
                    }
                }
                Panel(title: "实施约束") {
                    NoteBox(text: "启动、停止、重启仅管理 tqllm 官方 pid 文件记录的服务；配置启动前进行路径、模型和端口检查。应用关闭后服务默认继续运行。")
                }
            }
        }
    }

    var previewCommand: String {
        let args = store.config.serveArguments(apiKeyFile: store.apiKey.isEmpty ? nil : store.apiKeyFileURL.path,
                                               qsaCapable: model.qsaCapable)
        return ([store.config.cliPath, "serve"] + args).joined(separator: " \\\n  ")
    }

    func checkEnvironment() {
        Task {
            var lines: [String] = []
            lines.append("CLI：\(FileManager.default.isExecutableFile(atPath: store.config.cliPath) ? "✓" : "✗") \(store.config.cliPath)")
            lines.append("版本：\(model.cliVersion)")
            let stats = await ModelScanner.statWithTimeout([store.config.modelFile, store.config.draftFile])
            lines.append("主模型：\(stats[store.config.modelFile] == true ? "✓" : (stats[store.config.modelFile] == nil ? "… 磁盘无响应" : "✗")) \(store.config.modelFile)")
            lines.append("草稿模型：\(stats[store.config.draftFile] == true ? "✓" : (stats[store.config.draftFile] == nil ? "… 磁盘无响应" : "✗")) \(store.config.draftFile)")
            lines.append("外置硬盘：\(model.scanner.volumeMounted ? "✓ 已挂载" : "✗ 未挂载")")
            lines.append("端口：\(engine.isRunning ? "tqLLM 正在监听" : "空闲或无服务")")
            let text = lines.joined(separator: "\n")
            logs.event("环境检查：\n" + text)
            model.notify("环境检查完成，详见运行日志。")
        }
    }
}