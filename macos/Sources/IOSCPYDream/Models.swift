import Foundation
import SwiftUI

enum ConnectionMode: String, Codable, CaseIterable, Identifiable {
    case usb
    case lan

    var id: String { rawValue }
    var title: String { self == .usb ? "USB" : "局域网" }
    var symbol: String { self == .usb ? "cable.connector" : "wifi" }
}

enum VideoCodec: UInt8, Codable, CaseIterable, Identifiable {
    case h264 = 1
    case hevc = 2

    var id: UInt8 { rawValue }
    var title: String { self == .hevc ? "HEVC" : "H.264" }
}

struct VideoSettings: Codable, Equatable {
    var codec: VideoCodec = .h264
    var targetFPS: Int = 120
    var maxDimension: Int = 4096
    var bitrateMbps: Int = 45
    var keyframeSeconds: Int = 1

    /// Native-resolution H.264 avoids the synchronous VTPixelTransfer scaling
    /// stage. On the target iPhone this is the only profile that can improve
    /// quality and capture cadence at the same time; the encoder is separately
    /// pipelined and bounded on the device.
    static let extreme = VideoSettings()

    static let compatibility120 = VideoSettings(
        codec: .h264,
        targetFPS: 120,
        maxDimension: 2160,
        bitrateMbps: 40,
        keyframeSeconds: 1
    )

    static let nativeHEVC = VideoSettings(
        codec: .hevc,
        targetFPS: 120,
        maxDimension: 4096,
        bitrateMbps: 45,
        keyframeSeconds: 1
    )

    mutating func normalize() {
        targetFPS = min(max(targetFPS, 1), 240)
        maxDimension = min(max(maxDimension, 320), 4096)
        bitrateMbps = min(max(bitrateMbps, 1), 100)
        keyframeSeconds = min(max(keyframeSeconds, 1), 10)
    }
}

struct DeviceProfile: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var udid: String?
    var lanHost: String
    var lanPort: Int
    var pairToken: String?
    var pairExpiresAt: Date?
    var lockPassword: String
    var preferredMode: ConnectionMode
    var autoConnect: Bool
    var alwaysOnTop: Bool
    var deviceFrame: Bool
    var audioEnabled: Bool
    var video: VideoSettings
    var lastConnectedAt: Date?

    init(
        id: String = UUID().uuidString,
        name: String = "iPhone",
        udid: String? = nil,
        lanHost: String = "",
        lanPort: Int = 27183,
        pairToken: String? = nil,
        pairExpiresAt: Date? = nil,
        lockPassword: String = "",
        preferredMode: ConnectionMode = .usb,
        autoConnect: Bool = true,
        alwaysOnTop: Bool = false,
        deviceFrame: Bool = true,
        audioEnabled: Bool = false,
        video: VideoSettings = .extreme,
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.udid = udid
        self.lanHost = lanHost
        self.lanPort = lanPort
        self.pairToken = pairToken
        self.pairExpiresAt = pairExpiresAt
        self.lockPassword = lockPassword
        self.preferredMode = preferredMode
        self.autoConnect = autoConnect
        self.alwaysOnTop = alwaysOnTop
        self.deviceFrame = deviceFrame
        self.audioEnabled = audioEnabled
        self.video = video
        self.lastConnectedAt = lastConnectedAt
    }

    var pairingValid: Bool {
        guard pairToken?.isEmpty == false, let pairExpiresAt else { return false }
        return pairExpiresAt > Date()
    }
}

struct AppPreferences: Codable, Equatable {
    var autoConnectLastDevice: Bool = true
    var lastDeviceID: String?
    var toolbarAutoHideDelay: Double = 0.85
    var diagnosticsOverlay: Bool = false
}

struct PersistedState: Codable {
    var version: Int = 4
    var preferences = AppPreferences()
    var devices: [DeviceProfile] = []
}

struct RuntimeStats: Equatable {
    var receiveFPS: Double = 0
    var presentFPS: Double = 0
    var sourceFPS: Double = 0
    var captureFPS: Double = 0
    var encodeFPS: Double = 0
    var bitrateMbps: Double = 0
    var latencyMs: Double = 0
    var droppedFrames: UInt64 = 0
    var captureMs: Double = 0
    var encodeMs: Double = 0
    var sendMs: Double = 0
    var captureMsMax: Double = 0
    var encodeMsMax: Double = 0
    var sendMsMax: Double = 0
    var captureGapMsMax: Double = 0
    var effectiveDimension: Int = 0
    var encodeInFlight: Int = 0
    var sendBacklog: Int = 0
    var encodeInFlightMax: Int = 0
    var sendBacklogMax: Int = 0
    var dropCapturePressure: UInt64 = 0
    var dropEncoderPressure: UInt64 = 0
    var dropSendPressure: UInt64 = 0
    var dropTransport: UInt64 = 0
    var dropReferenceChain: UInt64 = 0
    var lanPacketsPerSecond: Double = 0
    var lanRecoveredFrames: UInt64 = 0
    var lanLostFrames: UInt64 = 0
    var lanLateFrames: UInt64 = 0
    var lanFrameReceiveMs: Double = 0
    var lanFrameReceiveMsMax: Double = 0
    var transport: String = ""
}

enum AppScreen: Equatable {
    case home
    case connecting
    case mirror
}

enum SessionStatus: Equatable {
    case idle
    case connecting(String)
    case pairing(String)
    case connected(String)
    case reconnecting(Int, String)
    case failed(String)

    var message: String {
        switch self {
        case .idle: return "未连接"
        case .connecting(let value): return value
        case .pairing(let value): return value
        case .connected(let value): return value
        case .reconnecting(let attempt, let value): return "重连第 \(attempt) 次 · \(value)"
        case .failed(let value): return value
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var state: PersistedState

    private let directoryURL: URL
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directoryURL = base.appendingPathComponent("ioscpy", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("settings-v1.json")
        let loaded = Self.load(from: fileURL)
        let migrated = Self.migrate(loaded)
        state = migrated
        if migrated.version != loaded.version || migrated.devices != loaded.devices {
            save()
        }
    }

    private static func load(from url: URL) -> PersistedState {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder.configured.decode(PersistedState.self, from: data) else {
            return PersistedState()
        }
        return decoded
    }

    private static func migrate(_ input: PersistedState) -> PersistedState {
        guard input.version < 4 else { return input }
        var output = input
        output.version = 4
        for index in output.devices.indices {
            // Only the original performance migration resets video settings.
            // Stability-only schema bumps must preserve the user's explicit
            // resolution, codec, bitrate, and FPS choices.
            if input.version < 3 {
                output.devices[index].video = .extreme
            }
            output.devices[index].deviceFrame = true
        }
        return output
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder.configured.encode(state)
            let temporary = fileURL.appendingPathExtension("tmp")
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: fileURL)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("[ioscpy] settings save failed: %@", error.localizedDescription)
        }
    }

    func upsert(_ device: DeviceProfile) {
        if let index = state.devices.firstIndex(where: { $0.id == device.id }) {
            state.devices[index] = device
        } else {
            state.devices.append(device)
        }
        save()
    }

    func remove(id: String) {
        state.devices.removeAll { $0.id == id }
        if state.preferences.lastDeviceID == id {
            state.preferences.lastDeviceID = nil
        }
        save()
    }
}

extension JSONEncoder {
    static var configured: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var configured: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
