import Foundation

// 无头集成测试入口：与 GUI 共用同一套服务层（ConfigStore/EngineController/APIClient/BenchmarkService）。
// 用法：tqllmctl scan|start|stop|status|bench-short [N]|bench-ab [N]|reports|snapshot
@main
struct TqLLMCLI {
    static func main() async {
        let args = CommandLine.arguments.dropFirst()
        let cmd = args.first ?? "status"
        await MainActor.run { }
        switch cmd {
        case "scan": await scan()
        case "start": await start()
        case "stop": await stop()
        case "status": await status()
        case "snapshot": await snapshot()
        case "bench-short": await benchShort(rounds: Int(args.dropFirst().first ?? "3") ?? 3)
        case "bench-draft": await benchDraft(rounds: Int(args.dropFirst().first ?? "3") ?? 3)
        case "bench-ab": await benchAB(rounds: Int(args.dropFirst().first ?? "2") ?? 2,
                                       targetTokens: args.dropFirst(2).first.flatMap { Int($0) })
        case "reports": reports()
        case "ui-toggle": postUI("tqllm-cc-test-toggle", object: nil)
        case "ui-nav": postUI("tqllm-cc-test-nav", object: args.dropFirst().first ?? "home")
        case "ui-dump": postUI("tqllm-cc-test-dump", object: nil)
        case "ui-autostart": postUI("tqllm-cc-test-autostart", object: args.dropFirst().first ?? "off")
        case "ui-preset": postUI("tqllm-cc-test-preset", object: args.dropFirst().first ?? "save")
        default:
            print("用法: tqllmctl scan|start|stop|status|snapshot|bench-short [N]|bench-ab [N]|reports|ui-toggle|ui-nav <page>|ui-dump")
        }
    }

    static func postUI(_ name: String, object: String?) {
        DistributedNotificationCenter.default().postNotificationName(
            .init(name), object: object, userInfo: nil, deliverImmediately: true)
        print("posted \(name)")
    }

    @MainActor static func makeStore() -> ConfigStore { ConfigStore() }

    @MainActor static func scan() async {
        let store = makeStore()
        let scanner = ModelScanner()
        await scanner.scan(dirs: [store.config.modelDir,
                                  FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/tqllm/models").path])
        for m in scanner.models {
            print("== \(m.fileName) (\(ModelScanner.formatGB(m.sizeBytes)))")
            print("   arch=\(m.info.architecture) ctx=\(m.info.contextLength) tensors=\(m.info.tensorCount)")
            print("   qsa=\(m.info.qsaCapable) mtp=\(m.info.mtpCapable) drafter=\(m.info.isDrafter) err=\(m.info.error ?? "无")")
        }
        print("volume mounted: \(scanner.volumeMounted)")
    }

    @MainActor static func start() async {
        let store = makeStore()
        let engine = EngineController()
        let scanner = ModelScanner()
        await scanner.scan(dirs: [store.config.modelDir])
        let capable = scanner.models.first { $0.path == store.config.modelFile }?.info.qsaCapable ?? false
        print("启动中… qsaCapable=\(capable)")
        await engine.start(store: store, qsaCapable: capable)
        print("state=\(engine.state.rawValue) ownership=\(engine.ownership.rawValue) pid=\(engine.pid.map(String.init) ?? "—")")
        if let e = engine.lastError { print("ERROR: \(e)") }
        print("args: \(engine.launchedArguments.joined(separator: " "))")
        print(engine.launchOutput.suffix(800))
    }

    @MainActor static func stop() async {
        let store = makeStore()
        let engine = EngineController()
        engine.startPolling(store: store)
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        print("before: state=\(engine.state.rawValue) ownership=\(engine.ownership.rawValue)")
        let ok = await engine.stop(store: store, confirmedExternal: true)
        print("stopped=\(ok) state=\(engine.state.rawValue)")
    }

    @MainActor static func status() async {
        let store = makeStore()
        let api = APIClient(host: store.config.host, port: store.config.port, apiKey: store.apiKey)
        do {
            let h = try await api.health()
            print("health: status=\(h.status ?? "?") engine=\(h.engine ?? "?") context=\(h.context ?? 0)")
            if let f = h.fit { print("fit: \(f)") }
            let m = try await api.models()
            print("models: \(m.data.map { "\($0.id)(\($0.owned_by ?? "?"))" }.joined(separator: ", "))")
        } catch {
            print("health: 无响应 (\(error.localizedDescription))")
        }
    }

    @MainActor static func snapshot() async {
        let store = makeStore()
        let api = APIClient(host: store.config.host, port: store.config.port, apiKey: store.apiKey)
        do {
            let s = try await api.snapshot()
            print("engine: model=\(s.engine?.model ?? "?") slots=\(s.engine?.slots ?? 0) ctx/slot=\(s.engine?.context_per_slot ?? 0)")
            if let hw = s.hardware {
                print(String(format: "memory: %.1f GB / %.0f GB", (hw.gpu_used_bytes ?? 0) / 1e9, (hw.gpu_total_bytes ?? 0) / 1e9))
            }
            for r in (s.requests ?? []).suffix(8) {
                print("req \(r.id) \(r.phase ?? "?") prompt=\(r.prompt_tokens ?? 0) out=\(r.output_tokens ?? 0) ttft=\(r.first_output_ms ?? 0)ms decode=\(r.decode_tokens_per_second ?? 0) prefill=\(r.prefill_tokens_per_second ?? 0) draft=\(r.drafted ?? 0)/\(r.accepted ?? 0)")
            }
        } catch { print("snapshot 失败: \(error.localizedDescription)") }
    }

    @MainActor static func benchShort(rounds: Int) async {
        let store = makeStore()
        let engine = EngineController()
        let bench = BenchmarkService()
        engine.startPolling(store: store)
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        guard engine.isRunning else { print("服务未运行"); return }
        await bench.runShort(store: store, engine: engine, rounds: rounds)
        print(bench.progress)
        if let e = bench.lastError { print("ERROR: \(e)") }
        for r in bench.currentRounds {
            print(String(format: "round %d: prompt=%d out=%d ttft=%.0fms prefill=%.1f decode=%.1f draft=%d/%d",
                         r.round, r.promptTokens, r.outputTokens, r.ttftMs, r.prefillTps, r.decodeTps, r.accepted, r.drafted))
        }
    }

    @MainActor static func benchDraft(rounds: Int) async {
        let store = makeStore()
        let engine = EngineController()
        let bench = BenchmarkService()
        engine.startPolling(store: store)
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        let printer = Task { @MainActor in
            var last = ""
            while !Task.isCancelled {
                if bench.progress != last { last = bench.progress; print("[progress] \(last)") }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        await bench.runDraftAB(store: store, engine: engine, rounds: rounds)
        printer.cancel()
        if let e = bench.lastError { print("ERROR: \(e)") }
        if let r = bench.reports.first { print(bench.markdown(r)) }
    }

    @MainActor static func benchAB(rounds: Int, targetTokens: Int? = nil) async {
        let store = makeStore()
        let engine = EngineController()
        let scanner = ModelScanner()
        let bench = BenchmarkService()
        await scanner.scan(dirs: [store.config.modelDir])
        engine.startPolling(store: store)
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        // 进度打印
        let printer = Task { @MainActor in
            var last = ""
            while !Task.isCancelled {
                if bench.progress != last {
                    last = bench.progress
                    print("[progress] \(last)")
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        await bench.runQSAAB(store: store, engine: engine, scanner: scanner, rounds: rounds, targetTokens: targetTokens)
        printer.cancel()
        if let e = bench.lastError { print("ERROR: \(e)") }
        if let r = bench.reports.first {
            print(bench.markdown(r))
        }
    }

    @MainActor static func reports() {
        let bench = BenchmarkService()
        for r in bench.reports {
            print("== \(r.name) · \(r.at)")
            for a in r.arms {
                print(String(format: "   %@: decode %.1f tok/s, prefill %.1f, ttft %.0f ms, accept %.1f%%",
                             a.name, a.medianDecode, a.medianPrefill, a.medianTTFT, a.acceptance))
            }
            if let v = r.qsaVerdict { print("   verdict: \(v)") }
        }
    }
}