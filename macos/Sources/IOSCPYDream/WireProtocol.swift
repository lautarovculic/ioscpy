import Foundation
import Security

enum Wire {
    static let magic: UInt32 = 0x4943_5059
    static let version: UInt16 = 5
    static let headerSize = 32
    static let maxPayload = 32 * 1024 * 1024
    static let defaultPort: UInt16 = 27183

    static let channelControl: UInt64 = 0
    static let channelVideo: UInt64 = 1
    static let channelAudio: UInt64 = 2

    static let flagH264: UInt32 = 0x1
    static let flagKeyframe: UInt32 = 0x2
    static let flagConfig: UInt32 = 0x4
    static let orientationMask: UInt32 = 0x18
    static let orientationShift: UInt32 = 3
    static let flagHEVC: UInt32 = 0x20
}

enum MessageType: UInt16 {
    case hello = 1
    case helloAck = 2
    case capabilitiesRequest = 3
    case capabilitiesResponse = 4
    case authenticate = 5
    case pairResult = 6
    case startStream = 10
    case stopStream = 11
    case videoFrame = 12
    case requestKeyframe = 13
    case inputTouch = 20
    case inputKey = 21
    case inputText = 22
    case inputScroll = 23
    case clipboardGet = 30
    case clipboardSet = 31
    case clipboardChanged = 32
    case orientationChanged = 40
    case screenInfo = 41
    case systemAction = 50
    case keyboardMode = 51
    case displayMode = 52
    case audioMode = 53
    case unlock = 54
    case ping = 60
    case pong = 61
    case error = 70
    case log = 71
    case stats = 72
    case audioFrame = 73
    case mediaBind = 74
}

struct WireFrame {
    let type: MessageType
    let flags: UInt32
    let streamID: UInt64
    let sequence: UInt64
    let payload: Data
}

struct HelloPayload: Encodable {
    let role = "host"
    let hostVersion = "0.3.0-dream.9"
    let protocolVersion = Wire.version
    let nonce: String
    let hostID: String
    let hostName: String
    let pairToken: String?
    let pairCode: String?

    enum CodingKeys: String, CodingKey {
        case role
        case hostVersion = "host_version"
        case protocolVersion = "protocol_version"
        case nonce
        case hostID = "host_id"
        case hostName = "host_name"
        case pairToken = "pair_token"
        case pairCode = "pair_code"
    }
}

struct HelloAck: Decodable {
    let daemonVersion: String
    let protocolVersion: UInt16
    let sessionToken: String
    let pairToken: String?
    let pairExpiresAt: Date?
    let capabilities: Capabilities

    enum CodingKeys: String, CodingKey {
        case daemonVersion = "daemon_version"
        case protocolVersion = "protocol_version"
        case sessionToken = "session_token"
        case pairToken = "pair_token"
        case pairExpiresAt = "pair_expires_at"
        case capabilities
    }
}

struct Capabilities: Decodable {
    let iosVersion: String
    let deviceModel: String
    let jailbreakLayout: String
    let streamBackends: [String]
    let inputBackends: [String]
    let clipboard: Bool
    let keyboard: Bool
    let orientation: Bool
    let lan: Bool
    let blackScreen: Bool
    let audio: Bool

    enum CodingKeys: String, CodingKey {
        case iosVersion = "ios_version"
        case deviceModel = "device_model"
        case jailbreakLayout = "jailbreak_layout"
        case streamBackends = "stream_backends"
        case inputBackends = "input_backends"
        case clipboard
        case keyboard
        case orientation
        case lan
        case blackScreen = "black_screen"
        case audio
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        iosVersion = try box.decodeIfPresent(String.self, forKey: .iosVersion) ?? ""
        deviceModel = try box.decodeIfPresent(String.self, forKey: .deviceModel) ?? ""
        jailbreakLayout = try box.decodeIfPresent(String.self, forKey: .jailbreakLayout) ?? ""
        streamBackends = try box.decodeIfPresent([String].self, forKey: .streamBackends) ?? []
        inputBackends = try box.decodeIfPresent([String].self, forKey: .inputBackends) ?? []
        clipboard = try box.decodeIfPresent(Bool.self, forKey: .clipboard) ?? false
        keyboard = try box.decodeIfPresent(Bool.self, forKey: .keyboard) ?? false
        orientation = try box.decodeIfPresent(Bool.self, forKey: .orientation) ?? false
        lan = try box.decodeIfPresent(Bool.self, forKey: .lan) ?? false
        blackScreen = try box.decodeIfPresent(Bool.self, forKey: .blackScreen) ?? false
        audio = try box.decodeIfPresent(Bool.self, forKey: .audio) ?? false
    }
}

struct DaemonErrorPayload: Decodable, Error {
    let code: String
    let fatal: Bool
    let message: String
    let suggestion: String?
    let pairingID: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case code, fatal, message, suggestion
        case pairingID = "pairing_id"
        case expiresIn = "expires_in"
    }
}

enum ConnectionFailure: LocalizedError {
    case invalidAddress
    case toolMissing(String)
    case processFailed(String)
    case protocolError(String)
    case pairingRequired(DaemonErrorPayload)
    case disconnected

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "IP 地址无效"
        case .toolMissing(let tool): return "缺少运行依赖：\(tool)"
        case .processFailed(let value): return value
        case .protocolError(let value): return value
        case .pairingRequired: return "需要输入 iPhone 上显示的 4 位配对码"
        case .disconnected: return "连接已断开"
        }
    }
}

struct VideoPacket {
    let width: Int
    let height: Int
    let flags: UInt32
    let bytes: Data

    var codec: VideoCodec {
        (flags & Wire.flagHEVC) != 0 ? .hevc : .h264
    }

    var orientation: Int {
        Int((flags & Wire.orientationMask) >> Wire.orientationShift) + 1
    }

    var isKeyframe: Bool { (flags & Wire.flagKeyframe) != 0 }
}

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }

    func readBE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        let size = MemoryLayout<T>.size
        precondition(offset + size <= count)
        return self[offset..<(offset + size)].withUnsafeBytes { raw in
            T(bigEndian: raw.loadUnaligned(as: T.self))
        }
    }
}

func randomHex(byteCount: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return bytes.map { String(format: "%02x", $0) }.joined()
}

func makeWireFrame(type: MessageType, streamID: UInt64 = Wire.channelControl, sequence: UInt64 = 0, payload: Data = Data()) -> Data {
    var data = Data(capacity: Wire.headerSize + payload.count)
    data.appendBE(Wire.magic)
    data.appendBE(Wire.version)
    data.appendBE(type.rawValue)
    data.appendBE(UInt32(0))
    data.appendBE(streamID)
    data.appendBE(sequence)
    data.appendBE(UInt32(payload.count))
    data.append(payload)
    return data
}

func parseVideoPacket(_ payload: Data) -> VideoPacket? {
    guard payload.count >= 16 else { return nil }
    let width = Int(payload.readBE(UInt32.self, at: 0))
    let height = Int(payload.readBE(UInt32.self, at: 4))
    let flags = payload.readBE(UInt32.self, at: 8)
    let length = Int(payload.readBE(UInt32.self, at: 12))
    guard length >= 0, 16 + length <= payload.count else { return nil }
    return VideoPacket(width: width, height: height, flags: flags, bytes: payload.subdata(in: 16..<(16 + length)))
}

func makeStreamConfig(_ settings: VideoSettings) -> Data {
    var normalized = settings
    normalized.normalize()
    var data = Data(repeating: 0, count: 16)
    data[0] = normalized.codec.rawValue
    data[1] = 2
    data.replaceSubrange(2..<4, with: withUnsafeBytes(of: UInt16(normalized.targetFPS).bigEndian, Array.init))
    data.replaceSubrange(4..<6, with: withUnsafeBytes(of: UInt16(normalized.maxDimension).bigEndian, Array.init))
    data[6] = 0
    let bitrate = UInt32(normalized.bitrateMbps * 1_000_000).bigEndian
    data.replaceSubrange(8..<12, with: withUnsafeBytes(of: bitrate, Array.init))
    let keyFrames = UInt16(normalized.targetFPS * normalized.keyframeSeconds).bigEndian
    data.replaceSubrange(12..<14, with: withUnsafeBytes(of: keyFrames, Array.init))
    return data
}

func makeTouchPayload(phase: UInt8, x: Float, y: Float) -> Data {
    var data = Data([phase, 0])
    var xb = x.bitPattern.bigEndian
    var yb = y.bitPattern.bigEndian
    Swift.withUnsafeBytes(of: &xb) { data.append(contentsOf: $0) }
    Swift.withUnsafeBytes(of: &yb) { data.append(contentsOf: $0) }
    return data
}

func makeScrollPayload(
    phase: UInt8,
    momentumPhase: UInt8,
    precise: Bool,
    deltaX: Float,
    deltaY: Float,
    x: Float,
    y: Float,
    timestampNanos: UInt64
) -> Data {
    var data = Data([phase, momentumPhase, precise ? 1 : 0, 0])
    for value in [deltaX, deltaY, x, y] {
        var bits = value.bitPattern.bigEndian
        Swift.withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
    data.appendBE(timestampNanos)
    return data
}

func mergeScrollPayload(_ older: Data?, _ newer: Data) -> Data {
    guard newer.count >= 28 else { return newer }
    guard let older, older.count >= 28 else { return newer }

    func readFloat(_ data: Data, _ offset: Int) -> Float {
        Float(bitPattern: data.readBE(UInt32.self, at: offset))
    }

    let deltaX = min(max(readFloat(older, 4) + readFloat(newer, 4), -240), 240)
    let deltaY = min(max(readFloat(older, 8) + readFloat(newer, 8), -240), 240)
    return makeScrollPayload(
        phase: newer[0],
        momentumPhase: newer[1],
        precise: older[2] != 0 || newer[2] != 0,
        deltaX: deltaX,
        deltaY: deltaY,
        x: readFloat(newer, 12),
        y: readFloat(newer, 16),
        timestampNanos: newer.readBE(UInt64.self, at: 20)
    )
}
