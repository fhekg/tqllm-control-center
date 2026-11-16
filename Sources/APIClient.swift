import Foundation

struct HealthInfo: Codable {
    var status: String?
    var engine: String?
    var context: Int?
    var fit: String?
}

struct ModelsResponse: Codable {
    struct Model: Codable { var id: String; var owned_by: String? }
    var data: [Model]
}

struct MonitorSnapshot: Codable {
    var schema_version: Int?
    var instance_id: String?
    var engine: Engine?
    var hardware: Hardware?
    var requests: [Request]?

    struct Engine: Codable {
        var model: String?
        var host: String?
        var build: String?
        var slots: Int?
        var context_per_slot: Int?
        var device_id: String?
    }
    struct Hardware: Codable {
        var gpu_used_bytes: Double?
        var gpu_total_bytes: Double?
        var ram_used_bytes: Double?
        var ram_total_bytes: Double?
        var cpu_percent: Double?
        var gpu_percent: Double?
        var gpu_celsius: Double?
        var gpu_watts: Double?
        var sample_age_ms: Double?
        var device_name: String?
    }
    struct Request: Codable, Identifiable {
        var id: Int
        var phase: String?
        var prompt_tokens: Int?
        var output_tokens: Int?
        var context_tokens: Int?
        var prefill_processed_tokens: Int?
        var first_output_ms: Double?
        var prefill_tokens_per_second: Double?
        var decode_tokens_per_second: Double?
        var elapsed_ms: Double?
        var drafted: Int?
        var accepted: Int?
        var cached_tokens: Int?
    }
}

struct SlotsInfo: Codable {
    var allocated: Int?
    var active: Int?
    var limit: Int?
    var busy: Int?
    var queued: Int?
}

/// 聊天响应（含服务端计时）。
struct ChatResponse: Codable {
    struct Usage: Codable {
        var prompt_tokens: Int?
        var completion_tokens: Int?
        var total_tokens: Int?
    }
    struct Timings: Codable {
        var prompt_n: Int?
        var prompt_ms: Double?
        var prompt_per_second: Double?
        var predicted_n: Int?
        var predicted_ms: Double?
        var predicted_per_second: Double?
        var draft_n: Int?
        var draft_n_accepted: Int?
    }
    struct Choice: Codable {
        struct Message: Codable {
            var role: String?
            var content: String?
            var reasoning_content: String?
        }
        var message: Message?
        var finish_reason: String?
    }
    var id: String?
    var model: String?
    var choices: [Choice]?
    var usage: Usage?
    var timings: Timings?
}

enum APIError: Error, LocalizedError {
    case unreachable(String)
    case http(Int, String)
    case decode(String)
    var errorDescription: String? {
        switch self {
        case .unreachable(let m): return "无法连接服务：\(m)"
        case .http(let code, let body): return "HTTP \(code)：\(body.prefix(300))"
        case .decode(let m): return "响应解析失败：\(m)"
        }
    }
}

/// tqserve HTTP 适配层。所有请求带超时；密钥用 Bearer 头，不进 URL/日志。
struct APIClient {
    var host: String
    var port: Int
    var apiKey: String?

    var baseURL: String { "http://\(host):\(port)" }

    private func request(_ path: String, method: String = "GET", body: Data? = nil, timeout: TimeInterval = 5) -> URLRequest {
        var req = URLRequest(url: URL(string: baseURL + path)!)
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let apiKey, !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw APIError.unreachable("非 HTTP 响应") }
            return (data, http)
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.unreachable(error.localizedDescription)
        }
    }

    func health() async throws -> HealthInfo {
        let (data, http) = try await send(request("/health", timeout: 3))
        guard http.statusCode == 200 else { throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        return try JSONDecoder().decode(HealthInfo.self, from: data)
    }

    func models() async throws -> ModelsResponse {
        let (data, http) = try await send(request("/v1/models", timeout: 3))
        guard http.statusCode == 200 else { throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        return try JSONDecoder().decode(ModelsResponse.self, from: data)
    }

    func snapshot() async throws -> MonitorSnapshot {
        let (data, http) = try await send(request("/api/monitor/v1/snapshot", timeout: 4))
        guard http.statusCode == 200 else { throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        return try JSONDecoder().decode(MonitorSnapshot.self, from: data)
    }

    func slots() async throws -> SlotsInfo {
        let (data, http) = try await send(request("/admin/slots", timeout: 3))
        guard http.statusCode == 200 else { throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        return try JSONDecoder().decode(SlotsInfo.self, from: data)
    }

    func setSlots(_ n: Int) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["slots": n])
        let (_, http) = try await send(request("/admin/slots", method: "POST", body: body, timeout: 5))
        guard http.statusCode == 200 else { throw APIError.http(http.statusCode, "调整并发失败") }
    }

    /// 非流式聊天（基准测试用，响应自带 timings）。
    func chat(messages: [[String: Any]], sampling: [String: Any], timeout: TimeInterval = 1800) async throws -> ChatResponse {
        var body = sampling
        body["messages"] = messages
        body["stream"] = false
        let data = try JSONSerialization.data(withJSONObject: body)
        let (out, http) = try await send(request("/v1/chat/completions", method: "POST", body: data, timeout: timeout))
        guard http.statusCode == 200 else { throw APIError.http(http.statusCode, String(data: out, encoding: .utf8) ?? "") }
        do { return try JSONDecoder().decode(ChatResponse.self, from: out) }
        catch { throw APIError.decode(String(String(data: out, encoding: .utf8)?.prefix(200) ?? "")) }
    }

    /// 流式聊天：逐 SSE 块回调内容增量，返回累计文本与首块时间。
    func chatStream(messages: [[String: Any]], sampling: [String: Any],
                    onDelta: @escaping (String, String) -> Void) async throws -> (text: String, reasoning: String, ttftMs: Double) {
        var body = sampling
        body["messages"] = messages
        body["stream"] = true
        let data = try JSONSerialization.data(withJSONObject: body)
        var req = request("/v1/chat/completions", method: "POST", body: data, timeout: 1800)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, "流式请求失败")
        }
        let start = Date()
        var text = "", reasoning = ""
        var ttft: Double? = nil
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let d = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else { continue }
            if let c = delta["content"] as? String, !c.isEmpty {
                if ttft == nil { ttft = Date().timeIntervalSince(start) * 1000 }
                text += c
                onDelta(c, "")
            }
            if let r = delta["reasoning_content"] as? String, !r.isEmpty {
                if ttft == nil { ttft = Date().timeIntervalSince(start) * 1000 }
                reasoning += r
                onDelta("", r)
            }
        }
        return (text, reasoning, ttft ?? 0)
    }
}