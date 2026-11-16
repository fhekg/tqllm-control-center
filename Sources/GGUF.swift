import Foundation

/// 原生 GGUF v3 元数据读取器（只读头部与张量名，不加载权重）。
struct GGUFInfo: Equatable {
    var architecture: String = ""
    var name: String = ""
    var contextLength: Int = 0
    var blockCount: Int = 0
    var fileType: Int = -1
    var quantNote: String = ""
    var qsaKeys: [String: Double] = [:]
    var qsaSparseFrom: Int? = nil
    var nextnPredictLayers: Int = 0
    var hasQSATensors = false
    var tensorCount = 0
    var vocabSize: Int = 0
    var isDrafter = false
    var error: String? = nil

    var qsaCapable: Bool { !qsaKeys.isEmpty && hasQSATensors }
    var mtpCapable: Bool { nextnPredictLayers > 0 }
}

enum GGUFReader {
    static func read(path: String) -> GGUFInfo {
        var info = GGUFInfo()
        guard let fh = FileHandle(forReadingAtPath: path) else {
            info.error = "无法打开文件"
            return info
        }
        defer { try? fh.close() }
        do {
            let r = Cursor(fh: fh)
            let magic = try r.bytes(4)
            guard magic == Data("GGUF".utf8) else { info.error = "不是 GGUF 文件"; return info }
            let version = try r.u32()
            guard version == 2 || version == 3 else { info.error = "不支持的 GGUF 版本 \(version)"; return info }
            let nTensors = try r.u64()
            let nKV = try r.u64()
            info.tensorCount = Int(nTensors)
            for _ in 0..<nKV {
                let key = try r.string()
                let type = try r.u32()
                let value = try r.value(type: type)
                switch (key, value) {
                case ("general.architecture", .str(let s)): info.architecture = s
                case ("general.name", .str(let s)): info.name = s
                case ("general.quantization.tqllm", .str(let s)): info.quantNote = s
                case (_, .num(let n)) where key.hasSuffix(".context_length"): info.contextLength = Int(n)
                case (_, .num(let n)) where key.hasSuffix(".block_count"): info.blockCount = Int(n)
                case ("general.file_type", .num(let n)): info.fileType = Int(n)
                case ("qwen35.qsa.sparse_from", .num(let n)): info.qsaSparseFrom = Int(n)
                case (_, .num(let n)) where key.contains(".qsa."): info.qsaKeys[key] = n
                case (_, .num(let n)) where key.hasSuffix(".nextn_predict_layers"): info.nextnPredictLayers = Int(n)
                case (_, .num(let n)) where key == "tokenizer.ggml.tokens.count": info.vocabSize = Int(n)
                default: break
                }
                if key == "tokenizer.ggml.tokens", case .array(let count, _) = value {
                    info.vocabSize = Int(count)
                }
            }
            // 张量名：检测 QSA 索引张量
            for _ in 0..<nTensors {
                let tname = try r.string()
                if tname.contains("qsa_") { info.hasQSATensors = true }
                let nDims = try r.u32()
                for _ in 0..<nDims { _ = try r.u64() }
                _ = try r.u32() // type
                _ = try r.u64() // offset
            }
            info.isDrafter = info.architecture == "dflash" || info.architecture == "dspark"
        } catch {
            info.error = "解析失败：\(error.localizedDescription)"
        }
        return info
    }

    enum Value {
        case num(Double)
        case str(String)
        case array(UInt64, UInt32)
        case bool(Bool)
    }

    struct ParseError: Error { let message: String }

    final class Cursor {
        let fh: FileHandle
        private var buf = Data()
        private var bufPos = 0
        private var filePos: UInt64 = 0
        private let chunk = 1 << 20
        init(fh: FileHandle) { self.fh = fh }

        private func fill(_ n: Int) throws {
            while buf.count - bufPos < n {
                let remaining = buf.count - bufPos
                if remaining > 0 {
                    buf = buf.subdata(in: bufPos..<buf.count)
                } else {
                    buf = Data()
                }
                bufPos = 0
                guard let d = try fh.read(upToCount: chunk), !d.isEmpty else {
                    throw ParseError(message: "文件截断")
                }
                buf.append(d)
                filePos += UInt64(d.count)
            }
        }
        func bytes(_ n: Int) throws -> Data {
            try fill(n)
            let d = buf.subdata(in: bufPos..<bufPos + n)
            bufPos += n
            return d
        }
        func u8() throws -> UInt8 { try bytes(1)[0] }
        func u16() throws -> UInt16 { try bytes(2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) } }
        func u32() throws -> UInt32 { try bytes(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        func u64() throws -> UInt64 { try bytes(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) } }
        func i32() throws -> Int32 { try bytes(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) } }
        func f32() throws -> Float { try bytes(4).withUnsafeBytes { $0.loadUnaligned(as: Float.self) } }
        func f64() throws -> Double { try bytes(8).withUnsafeBytes { $0.loadUnaligned(as: Double.self) } }
        func string() throws -> String {
            let n = try u64()
            guard n < 50_000_000 else { throw ParseError(message: "字符串长度异常") }
            let d = try bytes(Int(n))
            return String(data: d, encoding: .utf8) ?? ""
        }
        func skip(_ n: UInt64) throws {
            let avail = UInt64(buf.count - bufPos)
            if n <= avail {
                bufPos += Int(n)
            } else {
                let beyond = n - avail
                bufPos = buf.count
                try fh.seek(toOffset: filePos + beyond)
                filePos += beyond
                buf = Data()
                bufPos = 0
            }
        }
        func value(type: UInt32) throws -> Value {
            switch type {
            case 0: return .num(Double(try u8()))
            case 1: return .num(Double(Int8(bitPattern: try u8())))
            case 2: return .num(Double(try u16()))
            case 3: return .num(Double(Int16(bitPattern: try u16())))
            case 4: return .num(Double(try u32()))
            case 5: return .num(Double(try i32()))
            case 6: return .num(Double(try f32()))
            case 7: return .bool(try u8() != 0)
            case 8: return .str(try string())
            case 9:
                let et = try u32()
                let count = try u64()
                if et == 8 {
                    for _ in 0..<count { _ = try string() }
                } else {
                    let sizes: [UInt32: UInt64] = [0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8]
                    guard let s = sizes[et] else { throw ParseError(message: "未知数组元素类型 \(et)") }
                    try skip(count * s)
                }
                return .array(count, et)
            case 10: return .num(Double(try u64()))
            case 11: return .num(Double(Int64(bitPattern: try u64())))
            case 12: return .num(try f64())
            default: throw ParseError(message: "未知值类型 \(type)")
            }
        }
    }
}