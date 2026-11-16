import Foundation

/// 用户主目录（用于默认路径，避免硬编码任何用户名）。
private let homeDir = FileManager.default.homeDirectoryForCurrentUser.path

/// 应用配置：与 HTML 原型 defaults 对齐，映射到 tqserve 1.6.0 真实参数。
/// 默认路径均相对主目录；模型路径留空，由用户在「模型管理」页选择自己的 GGUF。
struct EngineConfig: Codable, Equatable {
    var cliPath: String = homeDir + "/.tqllm/venv/bin/tqllm"
    var modelDir: String = ""
    var modelFile: String = ""
    var draftFile: String = homeDir + "/.cache/tqllm/models/Qwen3.8-27B-DFlash2-MLX-4bit.gguf"
    var modelName: String = "Qwen3.8-27B-QSA"

    var qsaEnabled: Bool = true
    var qsaFrom: Int = 49152

    var draftMode: DraftMode = .dflash2
    var draftMax: Int = 7
    var treeVerify: Bool = true

    var context: Int = 131072
    var kvFormat: String = "bf16"
    var promptCache: Bool = false
    var memoryFit: Bool = true

    var temperature: Double = 0.7
    var topP: Double = 0.9
    var topK: Int = 40
    var maxTokens: Int = 4096
    var reasoning: Bool = true

    var host: String = "127.0.0.1"
    var port: Int = 8086
    var parallel: Int = 1

    var autoStart: Bool = false
    var stopOnQuit: Bool = false

    enum DraftMode: String, Codable, CaseIterable {
        case dflash2, mtp, off
        var label: String {
            switch self {
            case .dflash2: return "DFlash2"
            case .mtp: return "MTP"
            case .off: return "关闭"
            }
        }
    }

    /// 生成最终 tqserve 启动参数（不含 `serve` 子命令）。所有映射见 docs/PARAMETER_MAPPING.md。
    func serveArguments(apiKeyFile: String?, qsaCapable: Bool) -> [String] {
        var a: [String] = ["--model", modelFile, "--name", modelName,
                           "--host", host, "--port", String(port),
                           "--context", String(context), "--np", String(draftMode == .mtp ? 1 : parallel)]
        switch draftMode {
        case .dflash2:
            a += ["-md", draftFile, "--draft-max", String(draftMax)]
            if !treeVerify { a += ["--no-tree"] }
        case .mtp:
            a += ["--mtp"]
        case .off:
            break
        }
        if qsaCapable {
            a += ["--qsa-from", qsaEnabled ? String(qsaFrom) : "off"]
        }
        a += ["--kv", kvFormat]
        a += ["--prompt-cache", promptCache ? "on" : "off"]
        a += ["-fit", memoryFit ? "on" : "off"]
        a += ["--temperature", String(temperature), "--top-p", String(topP),
              "--top-k", String(topK), "--max-tokens", String(maxTokens),
              "--reasoning", reasoning ? "on" : "off"]
        if let apiKeyFile { a += ["--api-key-file", apiKeyFile] }
        return a
    }

    /// 请求级采样参数（生成参数页预览 / 基准测试固定条件）。
    func requestSampling(fixed: Bool = false) -> [String: Any] {
        var obj: [String: Any] = [
            "temperature": fixed ? 0.0 : temperature,
            "top_p": fixed ? 1.0 : topP,
            "top_k": fixed ? 1 : topK,
            "max_tokens": maxTokens,
            "stream": false
        ]
        obj["chat_template_kwargs"] = ["enable_thinking": fixed ? false : reasoning]
        return obj
    }
}

struct Preset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var config: EngineConfig
    var builtIn: Bool = false
}

enum BuiltInPresets {
    static var daily: Preset {
        var c = EngineConfig()
        c.context = 32768; c.qsaEnabled = false; c.kvFormat = "bf16"
        c.draftMode = .dflash2; c.draftMax = 7; c.temperature = 0.7; c.maxTokens = 4096
        return Preset(name: "日常交互", config: c, builtIn: true)
    }
    static var long: Preset {
        var c = EngineConfig()
        c.context = 131072; c.qsaEnabled = true; c.qsaFrom = 49152; c.kvFormat = "tq3"
        c.draftMode = .dflash2; c.draftMax = 7; c.maxTokens = 8192
        return Preset(name: "长上下文 QSA", config: c, builtIn: true)
    }
    static var bench: Preset {
        var c = EngineConfig()
        c.context = 65536; c.qsaEnabled = false; c.kvFormat = "bf16"
        c.draftMode = .dflash2; c.temperature = 0; c.topP = 1; c.maxTokens = 4096
        return Preset(name: "性能基准测试", config: c, builtIn: true)
    }
    static var all: [Preset] { [daily, long, bench] }
}