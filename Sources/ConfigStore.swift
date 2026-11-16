import Foundation
import Security
import ServiceManagement
import SwiftUI

/// macOS Keychain：API Key 只存这里，不落明文配置/日志。
enum KeychainStore {
    static let service = "com.xingbin.tqllm-control-center"

    static func set(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

@MainActor
final class ConfigStore: ObservableObject {
    @Published var config: EngineConfig { didSet { save() } }
    @Published var customPresets: [Preset] = [] { didSet { save() } }
    @Published var apiKey: String = "" {
        didSet { KeychainStore.set(apiKey, account: "api-key") }
    }
    @Published var autoStartStatus: String = "未注册"

    let supportDir: URL
    private var configURL: URL { supportDir.appendingPathComponent("config.json") }
    private var presetsURL: URL { supportDir.appendingPathComponent("presets.json") }
    var apiKeyFileURL: URL { supportDir.appendingPathComponent("api-key.txt") }
    var benchmarksDir: URL { supportDir.appendingPathComponent("benchmarks") }
    var historyURL: URL { supportDir.appendingPathComponent("performance-history.json") }

    init() {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tqLLM-Control-Center", isDirectory: true)
        supportDir = dir
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: dir.appendingPathComponent("benchmarks"), withIntermediateDirectories: true)

        var loaded = EngineConfig()
        if let data = try? Data(contentsOf: dir.appendingPathComponent("config.json")),
           let c = try? JSONDecoder().decode(EngineConfig.self, from: data) {
            loaded = c
        }
        var presets: [Preset] = []
        if let data = try? Data(contentsOf: dir.appendingPathComponent("presets.json")),
           let p = try? JSONDecoder().decode([Preset].self, from: data) {
            presets = p
        }
        config = loaded
        customPresets = presets
        apiKey = KeychainStore.get("api-key") ?? ""
        refreshAutoStartStatus()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(config) { try? d.write(to: configURL, options: .atomic) }
        if let d = try? enc.encode(customPresets) { try? d.write(to: presetsURL, options: .atomic) }
    }

    /// 将 Keychain 中的密钥写入 0600 文件供 --api-key-file 使用（命令行不出现密钥）。
    func materializeAPIKeyFile() -> String? {
        guard !apiKey.isEmpty else {
            try? FileManager.default.removeItem(at: apiKeyFileURL)
            return nil
        }
        try? apiKey.write(to: apiKeyFileURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: apiKeyFileURL.path)
        return apiKeyFileURL.path
    }

    // MARK: 预设

    func apply(_ preset: Preset) {
        var c = preset.config
        c.cliPath = config.cliPath
        c.modelDir = config.modelDir
        c.modelFile = config.modelFile
        c.draftFile = config.draftFile
        c.host = config.host
        c.port = config.port
        c.autoStart = config.autoStart
        c.stopOnQuit = config.stopOnQuit
        config = c
    }

    func saveCustom(name: String) {
        customPresets.append(Preset(name: name, config: config))
    }

    func deleteCustom(_ preset: Preset) {
        customPresets.removeAll { $0.id == preset.id }
    }

    func exportJSON() -> String {
        var safe = config
        let obj: [String: Any] = [
            "format": "tqllm-control-center",
            "version": 1,
            "config": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(safe))) ?? [:],
            "customPresets": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(customPresets))) ?? []
        ]
        let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(data: d, encoding: .utf8) ?? "{}"
    }

    func importJSON(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let format = obj["format"] as? String,
              format == "tqllm-control-center" || format == "tqllm-control-center-prototype",
              let cfgObj = obj["config"] else {
            return "不是本应用导出的配置文件。"
        }
        guard let cfgData = try? JSONSerialization.data(withJSONObject: cfgObj),
              var c = try? JSONDecoder().decode(EngineConfig.self, from: cfgData) else {
            return "配置字段无法解析。"
        }
        c.cliPath = config.cliPath
        config = c
        if let arr = obj["customPresets"],
           let pd = try? JSONSerialization.data(withJSONObject: arr),
           let ps = try? JSONDecoder().decode([Preset].self, from: pd) {
            customPresets = ps
        }
        return nil
    }

    // MARK: 登录自动启动

    func setAutoStart(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            config.autoStart = on
        } catch {
            config.autoStart = false
            autoStartStatus = "注册失败：\(error.localizedDescription)"
            return
        }
        refreshAutoStartStatus()
    }

    func refreshAutoStartStatus() {
        switch SMAppService.mainApp.status {
        case .enabled: autoStartStatus = "已注册（登录时启动）"
        case .notRegistered: autoStartStatus = "未注册"
        case .requiresApproval: autoStartStatus = "需在系统设置中批准"
        case .notFound: autoStartStatus = "未找到（应用需位于 /Applications）"
        @unknown default: autoStartStatus = "未知"
        }
    }
}