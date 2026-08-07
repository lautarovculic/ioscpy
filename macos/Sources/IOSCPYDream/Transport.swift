import Darwin
import Foundation
import Network

final class TCPTransport: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.ioscpy.transport", qos: .userInteractive)
    // Network.framework callbacks do not align with protocol frame boundaries.
    // A small read-ahead buffer reduces callback/continuation churn and keeps
    // video delivery cadence steadier under USB and Wi-Fi burstiness.
    private var receiveBuffer = Data()
    private var receiveOffset = 0

    init(host: String, port: UInt16) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw ConnectionFailure.invalidAddress
        }
        let parameters = NWParameters.tcp
        // This socket carries only interactive control/input once LAN video is
        // split to UDP. Mark it as responsive user data so macOS and compatible
        // Wi-Fi networks do not schedule a drag event like bulk traffic.
        parameters.serviceClass = .responsiveData
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 8
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 5
            tcp.keepaliveInterval = 2
            tcp.keepaliveCount = 3
        }
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ContinuationGate()
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                gate.resumeOnce {
                    self?.connection.cancel()
                    continuation.resume(throwing: ConnectionFailure.processFailed(
                        "网络路径在 3 秒内没有变为可用状态"
                    ))
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resumeOnce { continuation.resume() }
                case .failed(let error):
                    gate.resumeOnce { continuation.resume(throwing: error) }
                case .waiting:
                    // NWConnection commonly enters .waiting(.posix(ENETDOWN))
                    // for a fraction of a second while Wi-Fi/path evaluation is
                    // settling. Treat it as a recoverable state: Network.framework
                    // will transition this same connection to .ready when the path
                    // becomes usable instead of forcing the user to click Connect
                    // repeatedly.
                    break
                case .cancelled:
                    gate.resumeOnce { continuation.resume(throwing: ConnectionFailure.disconnected) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func enqueue(_ data: Data, completion: (@Sendable (Error?) -> Void)? = nil) {
        connection.send(content: data, completion: .contentProcessed { error in
            completion?(error)
        })
    }

    func receiveExactly(_ count: Int) async throws -> Data {
        guard count >= 0 else { throw ConnectionFailure.protocolError("负数读取长度") }
        if count == 0 { return Data() }
        while receiveBuffer.count - receiveOffset < count {
            let missing = count - (receiveBuffer.count - receiveOffset)
            let chunk = try await receive(
                minimum: 1,
                maximum: max(256 * 1024, min(Wire.maxPayload, missing))
            )
            guard !chunk.isEmpty else { throw ConnectionFailure.disconnected }
            receiveBuffer.append(chunk)
        }
        let start = receiveOffset
        let end = start + count
        let result = receiveBuffer.subdata(in: start..<end)
        receiveOffset = end
        if receiveOffset == receiveBuffer.count {
            receiveBuffer.removeAll(keepingCapacity: true)
            receiveOffset = 0
        } else if receiveOffset >= 512 * 1024 {
            receiveBuffer.removeSubrange(0..<receiveOffset)
            receiveOffset = 0
        }
        return result
    }

    private func receive(minimum: Int, maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: minimum, maximumLength: maximum) {
                data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: ConnectionFailure.disconnected)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    func cancel() {
        connection.cancel()
    }
}

final class USBForward: @unchecked Sendable {
    let localPort: UInt16
    private let process: Process

    init(udid: String) async throws {
        guard let iproxy = ToolLocator.find("iproxy") else {
            throw ConnectionFailure.toolMissing("iproxy（brew install libimobiledevice）")
        }
        localPort = try Self.reservePort()
        process = Process()
        process.executableURL = URL(fileURLWithPath: iproxy)
        process.arguments = ["\(localPort):\(Wire.defaultPort)", "-u", udid, "-l"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if !process.isRunning {
                throw ConnectionFailure.processFailed("USB 转发进程提前退出")
            }
            if Self.canConnect(port: localPort) { return }
            try await Task.sleep(for: .milliseconds(80))
        }
        process.terminate()
        throw ConnectionFailure.processFailed("无法通过 USB 连接 iPhone，请检查数据线、信任状态和 iproxy")
    }

    deinit {
        if process.isRunning { process.terminate() }
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }

    private static func reservePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ConnectionFailure.processFailed("无法分配本地端口") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let rc = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { throw ConnectionFailure.processFailed("无法绑定本地端口") }
        var output = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let grc = withUnsafeMutablePointer(to: &output) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard grc == 0 else { throw ConnectionFailure.processFailed("无法读取本地端口") }
        return UInt16(bigEndian: output.sin_port)
    }

    private static func canConnect(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

enum ToolLocator {
    static func find(_ name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        if let direct = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return direct
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }
}

enum USBDiscovery {
    static func listUDIDs() async -> [String] {
        guard let tool = ToolLocator.find("idevice_id") else { return [] }
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = ["-l"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return [] }
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                return output.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
            } catch {
                return []
            }
        }.value
    }
}

final class IOSCPYSession: @unchecked Sendable {
    let mode: ConnectionMode
    let profileID: String
    private let transport: TCPTransport
    private let usbForward: USBForward?
    private let lanVideoReceiver: LANVideoReceiver?
    private let sendLock = NSLock()
    private let realtimeSendQueue = DispatchQueue(
        label: "com.ioscpy.realtime-control",
        qos: .userInteractive
    )
    private var readTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var lanMediaWatchdogTask: Task<Void, Never>?
    private var stopped = false
    private var sequence: UInt64 = 1
    private let inputStateLock = NSLock()
    private var pendingTouchMove: Data?
    private var pendingTouchMoveAtNanos: UInt64 = 0
    private var touchMoveInFlight = false
    private var pendingScroll: Data?
    private var pendingScrollAtNanos: UInt64 = 0
    private var scrollInFlight = false
    private var lastKeyframeRequestNanos: UInt64 = 0
    private let lanFallbackLock = NSLock()
    private var lanFallbackActivated = false

    let capabilities: Capabilities
    let issuedPairToken: String?
    let pairExpiresAt: Date?

    var onVideo: (@Sendable (VideoPacket) -> Void)?
    var onAudio: (@Sendable (Data) -> Void)?
    var onStats: (@Sendable (Data) -> Void)?
    var onRTT: (@Sendable (Double) -> Void)?
    var onLANVideoTelemetry: (@Sendable (LANVideoTelemetry) -> Void)?
    var onVideoReferenceLoss: (@Sendable () -> Void)?
    var onRealtimeSendLatency: (@Sendable (Double) -> Void)?
    var onLog: (@Sendable (String) -> Void)?
    var onDisconnected: (@Sendable (Error?) -> Void)?

    private init(
        mode: ConnectionMode,
        profileID: String,
        transport: TCPTransport,
        usbForward: USBForward?,
        lanVideoReceiver: LANVideoReceiver?,
        capabilities: Capabilities,
        issuedPairToken: String?,
        pairExpiresAt: Date?
    ) {
        self.mode = mode
        self.profileID = profileID
        self.transport = transport
        self.usbForward = usbForward
        self.lanVideoReceiver = lanVideoReceiver
        self.capabilities = capabilities
        self.issuedPairToken = issuedPairToken
        self.pairExpiresAt = pairExpiresAt
    }

    static func connect(
        profile: DeviceProfile,
        mode: ConnectionMode,
        hostID: String,
        pairCode: String? = nil
    ) async throws -> IOSCPYSession {
        let forward: USBForward?
        let host: String
        let port: UInt16
        switch mode {
        case .usb:
            guard let udid = profile.udid, !udid.isEmpty else {
                throw ConnectionFailure.processFailed("该设备没有 USB UDID")
            }
            let created = try await USBForward(udid: udid)
            forward = created
            host = "127.0.0.1"
            port = created.localPort
        case .lan:
            guard !profile.lanHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (1...65535).contains(profile.lanPort) else {
                throw ConnectionFailure.invalidAddress
            }
            forward = nil
            host = profile.lanHost.trimmingCharacters(in: .whitespacesAndNewlines)
            port = UInt16(profile.lanPort)
        }

        let transport: TCPTransport
        if mode == .lan {
            let retryDelaysMs = [0, 200, 500, 1_000, 2_000]
            var connectedTransport: TCPTransport?
            var lastStartError: Error?
            for delay in retryDelaysMs {
                if delay > 0 {
                    try await Task.sleep(for: .milliseconds(delay))
                }
                let candidate = try TCPTransport(host: host, port: port)
                do {
                    try await candidate.start()
                    connectedTransport = candidate
                    break
                } catch {
                    lastStartError = error
                    candidate.cancel()
                }
            }
            guard let connectedTransport else {
                throw ConnectionFailure.processFailed(
                    "无法连接 \(host):\(port)。已自动等待并重试局域网路径；请确认 Mac 与 iPhone 在同一局域网、IP 正确，并已安装 dream.9 手机端。系统错误：\(lastStartError?.localizedDescription ?? "未知错误")"
                )
            }
            transport = connectedTransport
        } else {
            let candidate = try TCPTransport(host: host, port: port)
            try await candidate.start()
            transport = candidate
        }
        do {
            let hello = HelloPayload(
                nonce: randomHex(byteCount: 16),
                hostID: hostID,
                hostName: Host.current().localizedName ?? "Mac",
                pairToken: mode == .lan ? profile.pairToken : nil,
                pairCode: pairCode
            )
            let helloData = try JSONEncoder().encode(hello)
            try await transport.send(makeWireFrame(type: .hello, payload: helloData))
            let response = try await readFrame(from: transport)
            if response.type == .error {
                let daemonError = try JSONDecoder().decode(DaemonErrorPayload.self, from: response.payload)
                if daemonError.code == "PAIR_REQUIRED" || daemonError.code == "PAIR_CODE_INVALID" {
                    throw ConnectionFailure.pairingRequired(daemonError)
                }
                throw ConnectionFailure.protocolError("\(daemonError.code)：\(daemonError.message)")
            }
            guard response.type == .helloAck else {
                throw ConnectionFailure.protocolError("握手响应类型错误：\(response.type.rawValue)")
            }
            let decoder = JSONDecoder.configured
            let ack = try decoder.decode(HelloAck.self, from: response.payload)
            guard ack.protocolVersion == Wire.version else {
                throw ConnectionFailure.protocolError("协议版本不一致：Mac \(Wire.version)，iPhone \(ack.protocolVersion)")
            }
            try await transport.send(makeWireFrame(type: .authenticate, payload: Data(ack.sessionToken.utf8)))

            // ioscpyd can be ready a fraction of a second before the SpringBoard
            // tweak has reattached to its loopback frame channel (notably after
            // sbreload/reboot). START_STREAM sent during that gap is intentionally
            // fire-and-forget on the daemon side and would be lost, which made the
            // new app appear unable to connect until an older client happened to
            // wake the bridge first. Poll the live capability map before binding
            // media or starting capture so the first connection is deterministic.
            var liveCapabilities = ack.capabilities
            if liveCapabilities.streamBackends.isEmpty {
                let deadline = ContinuousClock.now + .seconds(5)
                while ContinuousClock.now < deadline, liveCapabilities.streamBackends.isEmpty {
                    try await Task.sleep(for: .milliseconds(150))
                    try await transport.send(makeWireFrame(type: .capabilitiesRequest))
                    let readiness = try await readFrame(from: transport)
                    switch readiness.type {
                    case .capabilitiesResponse:
                        liveCapabilities = try JSONDecoder().decode(Capabilities.self, from: readiness.payload)
                    case .error:
                        let daemonError = try JSONDecoder().decode(DaemonErrorPayload.self, from: readiness.payload)
                        if daemonError.fatal {
                            throw ConnectionFailure.protocolError("\(daemonError.code)：\(daemonError.message)")
                        }
                    default:
                        break
                    }
                }
                guard !liveCapabilities.streamBackends.isEmpty else {
                    throw ConnectionFailure.processFailed(
                        "iPhone 的 SpringBoard 控制桥接尚未就绪。请确认 dream.9 手机端已安装；无需先打开旧版 App，等待几秒后会自动重试。"
                    )
                }
            }

            let lanVideoReceiver: LANVideoReceiver?
            if mode == .lan {
                let receiver = try LANVideoReceiver()
                receiver.start()
                try await transport.send(makeWireFrame(
                    type: .mediaBind,
                    payload: receiver.mediaBindPayload()
                ))
                lanVideoReceiver = receiver
            } else {
                lanVideoReceiver = nil
            }

            let session = IOSCPYSession(
                mode: mode,
                profileID: profile.id,
                transport: transport,
                usbForward: forward,
                lanVideoReceiver: lanVideoReceiver,
                capabilities: liveCapabilities,
                issuedPairToken: ack.pairToken,
                pairExpiresAt: ack.pairExpiresAt
            )
            session.installLANVideoCallbacks()
            return session
        } catch {
            transport.cancel()
            forward?.stop()
            throw error
        }
    }

    private func installLANVideoCallbacks() {
        lanVideoReceiver?.onVideo = { [weak self] packet in
            self?.onVideo?(packet)
        }
        lanVideoReceiver?.onFrameLoss = { [weak self] in
            self?.onVideoReferenceLoss?()
            self?.requestKeyframe()
        }
        lanVideoReceiver?.onTelemetry = { [weak self] telemetry in
            self?.onLANVideoTelemetry?(telemetry)
        }
    }

    private static func readFrame(from transport: TCPTransport) async throws -> WireFrame {
        let header = try await transport.receiveExactly(Wire.headerSize)
        guard header.readBE(UInt32.self, at: 0) == Wire.magic else {
            throw ConnectionFailure.protocolError("收到无效协议魔数")
        }
        let version = header.readBE(UInt16.self, at: 4)
        guard version == Wire.version else {
            throw ConnectionFailure.protocolError("协议版本不一致：\(version)")
        }
        let typeRaw = header.readBE(UInt16.self, at: 6)
        guard let type = MessageType(rawValue: typeRaw) else {
            throw ConnectionFailure.protocolError("未知消息类型：\(typeRaw)")
        }
        let flags = header.readBE(UInt32.self, at: 8)
        let streamID = header.readBE(UInt64.self, at: 12)
        let sequence = header.readBE(UInt64.self, at: 20)
        let length = Int(header.readBE(UInt32.self, at: 28))
        guard length <= Wire.maxPayload else {
            throw ConnectionFailure.protocolError("消息过大：\(length)")
        }
        let payload = try await transport.receiveExactly(length)
        return WireFrame(type: type, flags: flags, streamID: streamID, sequence: sequence, payload: payload)
    }

    func start(settings: VideoSettings, audio: Bool) async throws {
        try await send(type: .keyboardMode, payload: Data([1]))
        try await send(type: .audioMode, payload: Data([audio ? 1 : 0]))
        try await send(type: .startStream, payload: makeStreamConfig(settings))
        readTask = Task.detached(priority: .high) { [weak self] in
            await self?.readLoop()
        }
        pingTask = Task.detached(priority: .utility) { [weak self] in
            while let self, !Task.isCancelled, !self.stopped {
                try? await Task.sleep(for: .seconds(2))
                var sentAt = DispatchTime.now().uptimeNanoseconds.bigEndian
                let payload = Swift.withUnsafeBytes(of: &sentAt) { Data($0) }
                try? await self.send(type: .ping, payload: payload)
            }
        }
        if let receiver = lanVideoReceiver {
            lanMediaWatchdogTask = Task.detached(priority: .utility) { [weak self, weak receiver] in
                let startedAt = DispatchTime.now().uptimeNanoseconds
                while let self, let receiver, !Task.isCancelled, !self.stopped {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled, !self.stopped else { return }
                    let now = DispatchTime.now().uptimeNanoseconds
                    let startupSeconds = Double(now &- startedAt) / 1_000_000_000
                    let stalled = receiver.secondsSinceLastDeliveredFrame().map { $0 > 1.5 } ?? false
                    let neverStarted = startupSeconds > 1.2 && !receiver.hasDeliveredFrame()
                    guard stalled || neverStarted else { continue }

                    // Some firewalls/APs may reject or later interrupt UDP. A
                    // permanent frozen mirror is worse than falling back to the
                    // older TCP media path, so degrade transport—not quality—once
                    // the low-latency channel has been silent for a sustained
                    // interval. The next reconnect will try UDP again.
                    self.fallbackLANVideoToTCP(reason: "UDP media watchdog timeout")
                    return
                }
            }
        }
    }

    private func readLoop() async {
        do {
            while !stopped, !Task.isCancelled {
                let frame = try await Self.readFrame(from: transport)
                switch frame.type {
                case .videoFrame:
                    if let packet = parseVideoPacket(frame.payload) { onVideo?(packet) }
                case .audioFrame:
                    onAudio?(frame.payload)
                case .stats:
                    onStats?(frame.payload)
                case .pong:
                    if frame.payload.count >= 8 {
                        let sentAt = frame.payload.readBE(UInt64.self, at: 0)
                        let now = DispatchTime.now().uptimeNanoseconds
                        if sentAt <= now {
                            onRTT?(Double(now - sentAt) / 1_000_000)
                        }
                    }
                case .log:
                    if let object = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any],
                       let message = object["message"] as? String {
                        onLog?(message)
                    }
                case .error:
                    let payload = try? JSONDecoder().decode(DaemonErrorPayload.self, from: frame.payload)
                    if payload?.fatal == true {
                        throw ConnectionFailure.protocolError(payload?.message ?? "iPhone 端返回致命错误")
                    }
                default:
                    break
                }
            }
        } catch {
            if !stopped { onDisconnected?(error) }
        }
    }

    func send(type: MessageType, payload: Data = Data(), streamID: UInt64 = Wire.channelControl) async throws {
        let current = nextSequence()
        try await transport.send(makeWireFrame(type: type, streamID: streamID, sequence: current, payload: payload))
    }

    private func nextSequence() -> UInt64 {
        sendLock.lock()
        defer { sendLock.unlock() }
        let current = sequence
        sequence &+= 1
        return current
    }

    private func enqueue(type: MessageType, payload: Data = Data(), streamID: UInt64 = Wire.channelControl) {
        let createdAtNanos = DispatchTime.now().uptimeNanoseconds
        let current = nextSequence()
        let frame = makeWireFrame(type: type, streamID: streamID, sequence: current, payload: payload)
        realtimeSendQueue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.transport.enqueue(frame) { error in
                let finishedAtNanos = DispatchTime.now().uptimeNanoseconds
                self.onRealtimeSendLatency?(
                    Double(finishedAtNanos &- createdAtNanos) / 1_000_000
                )
                if let error {
                    NSLog("[ioscpy] realtime send failed: %@", error.localizedDescription)
                }
            }
        }
    }

    private func enqueueLatestTouchMove(_ payload: Data) {
        inputStateLock.lock()
        pendingTouchMove = payload
        pendingTouchMoveAtNanos = DispatchTime.now().uptimeNanoseconds
        let shouldStart = !touchMoveInFlight
        if shouldStart { touchMoveInFlight = true }
        inputStateLock.unlock()
        if shouldStart {
            realtimeSendQueue.async { [weak self] in self?.drainLatestTouchMove() }
        }
    }

    private func drainLatestTouchMove() {
        inputStateLock.lock()
        guard let payload = pendingTouchMove else {
            touchMoveInFlight = false
            inputStateLock.unlock()
            return
        }
        let createdAtNanos = pendingTouchMoveAtNanos
        pendingTouchMove = nil
        pendingTouchMoveAtNanos = 0
        inputStateLock.unlock()

        guard !stopped else {
            inputStateLock.lock()
            touchMoveInFlight = false
            pendingTouchMove = nil
            pendingTouchMoveAtNanos = 0
            inputStateLock.unlock()
            return
        }
        let frame = makeWireFrame(
            type: .inputTouch,
            streamID: Wire.channelControl,
            sequence: nextSequence(),
            payload: payload
        )
        transport.enqueue(frame) { [weak self] error in
            guard let self else { return }
            let finishedAtNanos = DispatchTime.now().uptimeNanoseconds
            if createdAtNanos > 0 {
                self.onRealtimeSendLatency?(
                    Double(finishedAtNanos &- createdAtNanos) / 1_000_000
                )
            }
            if let error {
                NSLog("[ioscpy] touch send failed: %@", error.localizedDescription)
            }
            self.realtimeSendQueue.async { [weak self] in
                self?.drainLatestTouchMove()
            }
        }
    }

    private func discardPendingTouchMove() {
        inputStateLock.lock()
        pendingTouchMove = nil
        pendingTouchMoveAtNanos = 0
        inputStateLock.unlock()
    }

    private func enqueueCoalescedScroll(_ payload: Data) {
        inputStateLock.lock()
        pendingScroll = mergeScrollPayload(pendingScroll, payload)
        pendingScrollAtNanos = DispatchTime.now().uptimeNanoseconds
        let shouldStart = !scrollInFlight
        if shouldStart { scrollInFlight = true }
        inputStateLock.unlock()
        if shouldStart {
            realtimeSendQueue.async { [weak self] in self?.drainCoalescedScroll() }
        }
    }

    private func drainCoalescedScroll() {
        inputStateLock.lock()
        guard let payload = pendingScroll else {
            scrollInFlight = false
            inputStateLock.unlock()
            return
        }
        let createdAtNanos = pendingScrollAtNanos
        pendingScroll = nil
        pendingScrollAtNanos = 0
        inputStateLock.unlock()

        guard !stopped else {
            inputStateLock.lock()
            scrollInFlight = false
            pendingScroll = nil
            pendingScrollAtNanos = 0
            inputStateLock.unlock()
            return
        }
        let frame = makeWireFrame(
            type: .inputScroll,
            streamID: Wire.channelControl,
            sequence: nextSequence(),
            payload: payload
        )
        transport.enqueue(frame) { [weak self] error in
            guard let self else { return }
            let finishedAtNanos = DispatchTime.now().uptimeNanoseconds
            if createdAtNanos > 0 {
                self.onRealtimeSendLatency?(
                    Double(finishedAtNanos &- createdAtNanos) / 1_000_000
                )
            }
            if let error {
                NSLog("[ioscpy] scroll send failed: %@", error.localizedDescription)
            }
            self.realtimeSendQueue.async { [weak self] in
                self?.drainCoalescedScroll()
            }
        }
    }

    private func takePendingScroll(merging payload: Data) -> Data {
        inputStateLock.lock()
        let merged = mergeScrollPayload(pendingScroll, payload)
        pendingScroll = nil
        pendingScrollAtNanos = 0
        inputStateLock.unlock()
        return merged
    }

    private func discardPendingScroll() {
        inputStateLock.lock()
        pendingScroll = nil
        pendingScrollAtNanos = 0
        inputStateLock.unlock()
    }

    func updateVideo(_ settings: VideoSettings) async throws {
        try await send(type: .startStream, payload: makeStreamConfig(settings))
    }

    func requestKeyframe() {
        inputStateLock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        let due = now &- lastKeyframeRequestNanos >= 300_000_000
        if due { lastKeyframeRequestNanos = now }
        inputStateLock.unlock()
        guard due else { return }
        enqueue(type: .requestKeyframe)
    }

    func fallbackLANVideoToTCP(reason: String) {
        guard mode == .lan, let receiver = lanVideoReceiver else { return }
        lanFallbackLock.lock()
        guard !lanFallbackActivated else {
            lanFallbackLock.unlock()
            return
        }
        lanFallbackActivated = true
        lanFallbackLock.unlock()

        Task { [weak self, weak receiver] in
            guard let self else { return }
            try? await self.send(type: .mediaBind, payload: Data(repeating: 0, count: 12))
            receiver?.stop()
            self.onLog?("LAN UDP degraded; using stable TCP video fallback (\(reason))")
        }
    }

    func sendTouch(phase: UInt8, x: Float, y: Float) {
        let payload = makeTouchPayload(phase: phase, x: x, y: y)
        if phase == 1 {
            // Pointer callbacks can arrive faster than Network.framework can
            // commit writes. Retain only the newest move so stale coordinates
            // never accumulate behind the user's hand.
            enqueueLatestTouchMove(payload)
        } else {
            discardPendingTouchMove()
            enqueue(type: .inputTouch, payload: payload)
        }
    }

    func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        enqueue(type: .inputText, payload: Data(text.utf8))
    }

    func sendKey(_ code: UInt8) {
        enqueue(type: .inputKey, payload: Data([code]))
    }

    func sendScroll(_ payload: Data) {
        guard payload.count >= 28 else { return }
        let phase = payload[0]
        let momentum = payload[1]
        if phase == 1 || momentum == 1 {
            discardPendingScroll()
            enqueue(type: .inputScroll, payload: payload)
        } else if phase == 3 || phase == 4 || momentum == 3 || momentum == 4 {
            enqueue(type: .inputScroll, payload: takePendingScroll(merging: payload))
        } else {
            // Trackpads can generate hundreds of tiny delta events per second.
            // Accumulate their movement while keeping one network write active;
            // this preserves total distance and momentum without queuing history.
            enqueueCoalescedScroll(payload)
        }
    }

    func systemAction(_ code: UInt16) {
        var value = code.bigEndian
        let payload = Swift.withUnsafeBytes(of: &value) { Data($0) }
        enqueue(type: .systemAction, payload: payload)
    }

    func setBlackScreen(_ enabled: Bool) {
        enqueue(type: .displayMode, payload: Data([enabled ? 1 : 0]))
    }

    func setAudio(_ enabled: Bool) {
        enqueue(type: .audioMode, payload: Data([enabled ? 1 : 0]))
    }

    func stop(userInitiated: Bool = true) {
        guard !stopped else { return }
        stopped = true
        readTask?.cancel()
        pingTask?.cancel()
        lanMediaWatchdogTask?.cancel()
        discardPendingTouchMove()
        discardPendingScroll()
        Task { try? await send(type: .stopStream) }
        transport.cancel()
        lanVideoReceiver?.stop()
        usbForward?.stop()
    }
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func resumeOnce(_ action: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return }
        completed = true
        action()
    }
}
