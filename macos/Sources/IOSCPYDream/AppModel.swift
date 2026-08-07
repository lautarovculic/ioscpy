import AppKit
import CoreVideo
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let store = SettingsStore()

    @Published var screen: AppScreen = .home
    @Published var status: SessionStatus = .idle
    @Published var currentDeviceID: String?
    @Published var activeMode: ConnectionMode = .usb
    @Published var discoveredUDIDs: [String] = []
    @Published var showingSettings = false
    @Published var showingPairing = false
    @Published var pairingCode = ""
    @Published var toolbarVisible = false
    @Published var blackScreenEnabled = false
    @Published var stats = RuntimeStats()
    @Published var frameSize = CGSize(width: 393, height: 852)

    private var session: IOSCPYSession?
    private let decoder = VideoDecoder()
    private lazy var decodePump = VideoDecodePump(decoder: decoder)
    private let audioPlayer = AudioPlayer()
    private let performanceCounters = PerformanceCounters()
    let frameMailbox = VideoFrameMailbox()
    private weak var mirrorView: MirrorMetalView?
    private var pendingPairing: (DeviceProfile, ConnectionMode)?
    private var reconnectTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var userDisconnected = false
    private var didLaunch = false
    private var toolbarHideTask: Task<Void, Never>?
    private var pointerInsideAccessory = false
    private var lanDegradedWindows = 0
    private let hostID: String

    init() {
        DiagnosticsLogger.shared.start()
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: "host-id"), !existing.isEmpty {
            hostID = existing
        } else {
            let created = UUID().uuidString
            defaults.set(created, forKey: "host-id")
            hostID = created
        }

        let mailbox = frameMailbox
        let counters = performanceCounters
        decoder.onDecodeLatency = { latencyMs in
            counters.recordDecode(latencyMs: latencyMs)
        }
        decodePump.onQueueTelemetry = { waitMs, pending in
            counters.recordDecodeQueue(waitMs: waitMs, pending: pending)
        }
        decoder.onPixelBuffer = { [weak self] envelope, width, height, orientation in
            let geometryChanged = mailbox.publish(
                envelope.buffer,
                width: width,
                height: height,
                orientation: orientation
            )
            if geometryChanged {
                Task { @MainActor [weak self] in
                    self?.handleFrameGeometry(width: width, height: height, orientation: orientation)
                }
            }
        }
        decoder.onDecodeError = { error in
            NSLog("[ioscpy] decode: %@", error)
            DiagnosticsLogger.shared.logMessage("decode_error", error)
        }
    }

    var devices: [DeviceProfile] { store.state.devices }

    var currentDevice: DeviceProfile? {
        guard let currentDeviceID else { return nil }
        return store.state.devices.first { $0.id == currentDeviceID }
    }

    func launch() {
        guard !didLaunch else { return }
        didLaunch = true
        Task {
            await refreshDevices()
            guard store.state.preferences.autoConnectLastDevice,
                  let id = store.state.preferences.lastDeviceID,
                  let device = store.state.devices.first(where: { $0.id == id }),
                  device.autoConnect else { return }
            let mode = device.preferredMode
            if mode == .usb, let udid = device.udid, !discoveredUDIDs.contains(udid) { return }
            await connect(device: device, mode: mode, automatic: true)
        }
    }

    func refreshDevices() async {
        let udids = await USBDiscovery.listUDIDs()
        discoveredUDIDs = udids
        var changed = false
        for udid in udids where !store.state.devices.contains(where: { $0.udid == udid }) {
            var profile = DeviceProfile(name: "iPhone", udid: udid)
            profile.preferredMode = .usb
            store.state.devices.append(profile)
            changed = true
        }
        if changed { store.save() }
    }

    func addLANDevice() {
        let profile = DeviceProfile(
            name: "局域网 iPhone",
            preferredMode: .lan,
            autoConnect: false
        )
        store.state.devices.append(profile)
        store.save()
        currentDeviceID = profile.id
        showingSettings = true
    }

    func connect(device: DeviceProfile, mode: ConnectionMode, automatic: Bool = false) async {
        guard session == nil else { return }
        userDisconnected = false
        reconnectTask?.cancel()
        currentDeviceID = device.id
        activeMode = mode
        screen = .connecting
        status = .connecting(automatic ? "正在自动连接 \(device.name)…" : "正在连接 \(device.name)…")
        DiagnosticsLogger.shared.log("connect_begin", fields: [
            "device_name": device.name,
            "mode": mode.rawValue,
            "automatic": automatic,
            "lan_host": mode == .lan ? device.lanHost : "",
            "target_fps": device.video.targetFPS,
            "max_dimension": device.video.maxDimension,
            "bitrate_mbps": device.video.bitrateMbps,
            "codec": device.video.codec.title,
        ])
        AppWindowManager.shared.setMirrorMode(false)
        do {
            try await establish(device: device, mode: mode, pairCode: nil)
        } catch ConnectionFailure.pairingRequired(let challenge) {
            pendingPairing = (device, mode)
            pairingCode = ""
            showingPairing = true
            status = .pairing(challenge.message)
            screen = .home
        } catch {
            DiagnosticsLogger.shared.logMessage("connect_failed", error.localizedDescription)
            status = .failed(error.localizedDescription)
            screen = .home
        }
    }

    private func establish(device: DeviceProfile, mode: ConnectionMode, pairCode: String?) async throws {
        let connected = try await IOSCPYSession.connect(
            profile: device,
            mode: mode,
            hostID: hostID,
            pairCode: pairCode
        )
        configureCallbacks(connected)
        session = connected

        var updated = device
        if let token = connected.issuedPairToken {
            updated.pairToken = token
            updated.pairExpiresAt = connected.pairExpiresAt ?? Date().addingTimeInterval(30 * 24 * 3600)
        }
        updated.preferredMode = mode
        updated.lastConnectedAt = Date()
        store.upsert(updated)
        store.state.preferences.lastDeviceID = updated.id
        store.save()
        currentDeviceID = updated.id
        activeMode = mode
        blackScreenEnabled = false
        lanDegradedWindows = 0

        try await connected.start(settings: updated.video, audio: updated.audioEnabled)
        DiagnosticsLogger.shared.log("connect_ready", fields: [
            "mode": mode.rawValue,
            "device_model": connected.capabilities.deviceModel,
            "ios_version": connected.capabilities.iosVersion,
            "stream_backends": connected.capabilities.streamBackends,
            "input_backends": connected.capabilities.inputBackends,
            "target_fps": updated.video.targetFPS,
            "max_dimension": updated.video.maxDimension,
            "bitrate_mbps": updated.video.bitrateMbps,
            "codec": updated.video.codec.title,
        ])
        startStatsTask()
        screen = .mirror
        status = .connected("\(mode.title) · \(connected.capabilities.deviceModel) · iOS \(connected.capabilities.iosVersion)")
        stats.transport = mode.title
        AppWindowManager.shared.setMirrorMode(true)
        AppWindowManager.shared.setAlwaysOnTop(updated.alwaysOnTop)
        AppWindowManager.shared.updateAspect(frameSize)
        revealToolbar()

        connected.systemAction(3)
        if !updated.lockPassword.isEmpty {
            try? await Task.sleep(for: .milliseconds(500))
            await sendUnlockPassword(updated.lockPassword)
        }
    }

    private func configureCallbacks(_ connected: IOSCPYSession) {
        let decoder = self.decoder
        let decodePump = self.decodePump
        let counters = performanceCounters
        decoder.onDecodeError = { error in
            NSLog("[ioscpy] decode: %@", error)
            DiagnosticsLogger.shared.logMessage("decode_error", error)
            decodePump.breakReferenceChain()
        }
        decodePump.onNeedKeyframe = { [weak connected] in connected?.requestKeyframe() }
        decodePump.onDroppedStaleChain = {
            NSLog("[ioscpy] decoder backlog discarded; requesting fresh keyframe")
            DiagnosticsLogger.shared.logMessage(
                "decoder_chain_drop",
                "decoder backlog discarded; requesting fresh keyframe"
            )
        }
        connected.onVideo = { packet in
            counters.recordReceived(bytes: packet.bytes.count)
            decodePump.submit(packet)
        }
        connected.onVideoReferenceLoss = {
            decodePump.breakReferenceChain()
        }
        connected.onStats = { data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            DiagnosticsLogger.shared.log("device_stats", fields: object)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let windowMs = max((object["window_ms"] as? NSNumber)?.doubleValue ?? 1000, 1)
                let scale = 1000.0 / windowMs
                if let captured = object["captured_frames"] as? NSNumber {
                    self.stats.captureFPS = captured.doubleValue * scale
                }
                if let encoded = object["encoded_frames"] as? NSNumber {
                    self.stats.encodeFPS = encoded.doubleValue * scale
                }
                if let sent = object["sent_frames"] as? NSNumber {
                    self.stats.sourceFPS = sent.doubleValue * scale
                }
                if let dropped = object["dropped_frames"] as? NSNumber {
                    self.stats.droppedFrames = dropped.uint64Value
                }
                self.stats.captureMs = (object["capture_ms_avg"] as? NSNumber)?.doubleValue ?? 0
                self.stats.encodeMs = (object["encode_ms_avg"] as? NSNumber)?.doubleValue ?? 0
                self.stats.sendMs = (object["send_ms_avg"] as? NSNumber)?.doubleValue ?? 0
                self.stats.captureMsMax = (object["capture_ms_max"] as? NSNumber)?.doubleValue ?? 0
                self.stats.encodeMsMax = (object["encode_ms_max"] as? NSNumber)?.doubleValue ?? 0
                self.stats.sendMsMax = (object["send_ms_max"] as? NSNumber)?.doubleValue ?? 0
                self.stats.captureGapMsMax = (object["capture_gap_ms_max"] as? NSNumber)?.doubleValue ?? 0
                self.stats.effectiveDimension = (object["max_dimension"] as? NSNumber)?.intValue ?? 0
                self.stats.encodeInFlight = (object["encode_inflight"] as? NSNumber)?.intValue ?? 0
                self.stats.sendBacklog = (object["send_backlog"] as? NSNumber)?.intValue ?? 0
                self.stats.encodeInFlightMax = (object["encode_inflight_max"] as? NSNumber)?.intValue ?? 0
                self.stats.sendBacklogMax = (object["send_backlog_max"] as? NSNumber)?.intValue ?? 0
                self.stats.dropCapturePressure = (object["drop_capture_pressure"] as? NSNumber)?.uint64Value ?? 0
                self.stats.dropEncoderPressure = (object["drop_encoder_pressure"] as? NSNumber)?.uint64Value ?? 0
                self.stats.dropSendPressure = (object["drop_send_pressure"] as? NSNumber)?.uint64Value ?? 0
                self.stats.dropTransport = (object["drop_transport"] as? NSNumber)?.uint64Value ?? 0
                self.stats.dropReferenceChain = (object["drop_reference_chain"] as? NSNumber)?.uint64Value ?? 0

                if self.stats.sourceFPS > 0, self.stats.sourceFPS < 90 {
                    NSLog(
                        "[ioscpy] pipeline cap=%.1f encode=%.1f sent=%.1f capture=%.2f/%.2fms encode=%.2f/%.2fms send=%.2f/%.2fms gapMax=%.2f inFlight=%d/%d backlog=%d/%d drops[c=%llu e=%llu s=%llu t=%llu r=%llu] max=%d",
                        self.stats.captureFPS,
                        self.stats.encodeFPS,
                        self.stats.sourceFPS,
                        self.stats.captureMs,
                        self.stats.captureMsMax,
                        self.stats.encodeMs,
                        self.stats.encodeMsMax,
                        self.stats.sendMs,
                        self.stats.sendMsMax,
                        self.stats.captureGapMsMax,
                        self.stats.encodeInFlight,
                        self.stats.encodeInFlightMax,
                        self.stats.sendBacklog,
                        self.stats.sendBacklogMax,
                        self.stats.dropCapturePressure,
                        self.stats.dropEncoderPressure,
                        self.stats.dropSendPressure,
                        self.stats.dropTransport,
                        self.stats.dropReferenceChain,
                        self.stats.effectiveDimension
                    )
                }
            }
        }
        connected.onLog = { message in
            NSLog("[ioscpy] device: %@", message)
            DiagnosticsLogger.shared.logMessage("device_log", message)
        }
        connected.onAudio = { [weak self] packet in self?.audioPlayer.enqueue(packet) }
        connected.onRTT = { [weak self] value in
            Task { @MainActor [weak self] in self?.stats.latencyMs = value }
        }
        connected.onRealtimeSendLatency = { latencyMs in
            counters.recordInputSend(latencyMs: latencyMs)
        }
        connected.onLANVideoTelemetry = { [weak self] sample in
            DiagnosticsLogger.shared.log("lan_video", fields: [
                "packets_per_second": sample.packetsPerSecond,
                "recovered_frames": sample.recoveredFrames,
                "lost_frames": sample.lostFrames,
                "late_frames": sample.lateFrames,
                "late_packets": sample.latePackets,
                "frame_rx_ms_avg": sample.frameReceiveMsAverage,
                "frame_rx_ms_p50": sample.frameReceiveMsP50,
                "frame_rx_ms_p95": sample.frameReceiveMsP95,
                "frame_rx_ms_p99": sample.frameReceiveMsP99,
                "frame_rx_ms_max": sample.frameReceiveMsMax,
                "packet_gap_ms_p95": sample.packetGapMsP95,
                "packet_gap_ms_p99": sample.packetGapMsP99,
                "packet_gap_ms_max": sample.packetGapMsMax,
            ])
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stats.lanPacketsPerSecond = sample.packetsPerSecond
                self.stats.lanRecoveredFrames = sample.recoveredFrames
                self.stats.lanLostFrames = sample.lostFrames
                self.stats.lanLateFrames = sample.lateFrames
                self.stats.lanFrameReceiveMs = sample.frameReceiveMsAverage
                self.stats.lanFrameReceiveMsMax = sample.frameReceiveMsMax
                if sample.lostFrames > 0 || sample.lateFrames > 0 {
                    NSLog(
                        "[ioscpy] LAN UDP %.0f pkt/s recovered=%llu lost=%llu late=%llu frameRx=%.2f/%.2fms",
                        sample.packetsPerSecond,
                        sample.recoveredFrames,
                        sample.lostFrames,
                        sample.lateFrames,
                        sample.frameReceiveMsAverage,
                        sample.frameReceiveMsMax
                    )
                }
            }
        }
        connected.onDisconnected = { [weak self, weak connected] error in
            DiagnosticsLogger.shared.logMessage(
                "transport_disconnected",
                error?.localizedDescription ?? "connection closed"
            )
            Task { @MainActor [weak self] in
                guard let self, let connected, self.session === connected else { return }
                self.handleDisconnect(error)
            }
        }
    }

    func submitPairingCode() {
        let code = pairingCode.filter(\.isNumber)
        guard code.count == 4, let pendingPairing else { return }
        showingPairing = false
        status = .connecting("正在验证配对码…")
        screen = .connecting
        Task {
            do {
                try await establish(device: pendingPairing.0, mode: pendingPairing.1, pairCode: code)
                self.pendingPairing = nil
            } catch ConnectionFailure.pairingRequired(let error) {
                self.screen = .home
                self.status = .failed(error.message)
                self.showingPairing = true
            } catch {
                self.screen = .home
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    func disconnect() {
        DiagnosticsLogger.shared.logMessage("disconnect", "user initiated")
        userDisconnected = true
        reconnectTask?.cancel()
        reconnectTask = nil
        statsTask?.cancel()
        statsTask = nil
        session?.stop(userInitiated: true)
        session = nil
        decodePump.reset()
        audioPlayer.stop()
        blackScreenEnabled = false
        lanDegradedWindows = 0
        screen = .home
        status = .idle
        AppWindowManager.shared.setMirrorMode(false)
    }

    private func handleDisconnect(_ error: Error?) {
        DiagnosticsLogger.shared.logMessage(
            "reconnect_required",
            error?.localizedDescription ?? "connection interrupted"
        )
        session = nil
        statsTask?.cancel()
        statsTask = nil
        decodePump.reset()
        audioPlayer.stop()
        lanDegradedWindows = 0
        guard !userDisconnected, let device = currentDevice else {
            screen = .home
            return
        }
        scheduleReconnect(device: device, mode: activeMode, reason: error?.localizedDescription ?? "连接中断")
    }

    private func scheduleReconnect(device: DeviceProfile, mode: ConnectionMode, reason: String) {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            let ladder: [Double] = [0, 0.25, 0.5, 1, 2, 4, 8, 15, 30]
            var attempt = 0
            while let self, !Task.isCancelled, !self.userDisconnected {
                let base = ladder[min(attempt, ladder.count - 1)]
                let jitter = base == 0 ? 0 : Double.random(in: -0.2...0.2) * base
                let delay = max(0, base + jitter)
                self.status = .reconnecting(attempt + 1, reason)
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                if Task.isCancelled || self.userDisconnected { return }
                do {
                    try await self.establish(device: device, mode: mode, pairCode: nil)
                    return
                } catch ConnectionFailure.pairingRequired {
                    self.screen = .home
                    self.status = .failed("30 天信任已失效，需要重新配对")
                    return
                } catch {
                    attempt += 1
                }
            }
        }
    }

    func attachMirrorView(_ view: MirrorMetalView) {
        mirrorView = view
        view.onTouch = { [weak self] phase, x, y in self?.session?.sendTouch(phase: phase, x: x, y: y) }
        view.onScroll = { [weak self] payload in self?.session?.sendScroll(payload) }
        view.onText = { [weak self] text in self?.session?.sendText(text) }
        view.onKey = { [weak self] code in self?.session?.sendKey(code) }
        view.onHomeGesture = { [weak self] in self?.session?.systemAction(1) }
        view.onPointerActivity = { [weak self] in Task { @MainActor in self?.revealToolbar() } }
        let counters = performanceCounters
        view.onFramePresented = { counters.recordPresented() }
        view.onRenderTelemetry = { frameAgeMs, renderSubmitMs in
            counters.recordRender(frameAgeMs: frameAgeMs, submitMs: renderSubmitMs)
        }
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }

    private func handleFrameGeometry(width: Int, height: Int, orientation: Int) {
        let upright = (orientation == 3 || orientation == 4)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
        if upright.width > 0, upright.height > 0, upright != frameSize {
            frameSize = upright
            AppWindowManager.shared.updateAspect(upright)
        }
    }

    private func startStatsTask() {
        statsTask?.cancel()
        performanceCounters.reset()
        statsTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                let sample = self.performanceCounters.consume()
                self.stats.receiveFPS = sample.receiveFPS
                self.stats.presentFPS = sample.presentFPS
                self.stats.bitrateMbps = sample.bitrateMbps
                DiagnosticsLogger.shared.log("host_stats", fields: [
                    "mode": self.activeMode.rawValue,
                    "transport": self.stats.transport,
                    "mac_rx_fps": sample.receiveFPS,
                    "mac_present_fps": sample.presentFPS,
                    "device_source_fps": self.stats.sourceFPS,
                    "device_capture_fps": self.stats.captureFPS,
                    "device_encode_fps": self.stats.encodeFPS,
                    "bitrate_mbps": sample.bitrateMbps,
                    "rtt_ms": self.stats.latencyMs,
                    "rx_gap_ms_p50": sample.receiveGapP50Ms,
                    "rx_gap_ms_p95": sample.receiveGapP95Ms,
                    "rx_gap_ms_p99": sample.receiveGapP99Ms,
                    "rx_gap_ms_max": sample.receiveGapMaxMs,
                    "decode_queue_ms_p50": sample.decodeQueueP50Ms,
                    "decode_queue_ms_p95": sample.decodeQueueP95Ms,
                    "decode_queue_ms_p99": sample.decodeQueueP99Ms,
                    "decode_ms_p50": sample.decodeP50Ms,
                    "decode_ms_p95": sample.decodeP95Ms,
                    "decode_ms_p99": sample.decodeP99Ms,
                    "frame_age_ms_p50": sample.frameAgeP50Ms,
                    "frame_age_ms_p95": sample.frameAgeP95Ms,
                    "frame_age_ms_p99": sample.frameAgeP99Ms,
                    "render_submit_ms_p50": sample.renderSubmitP50Ms,
                    "render_submit_ms_p95": sample.renderSubmitP95Ms,
                    "render_submit_ms_p99": sample.renderSubmitP99Ms,
                    "input_send_ms_p50": sample.inputSendP50Ms,
                    "input_send_ms_p95": sample.inputSendP95Ms,
                    "input_send_ms_p99": sample.inputSendP99Ms,
                    "decode_pending_max": sample.decodePendingMax,
                ])
                if self.activeMode == .lan,
                   self.stats.sourceFPS >= 45,
                   self.stats.receiveFPS < self.stats.sourceFPS * 0.55 {
                    self.lanDegradedWindows += 1
                } else {
                    self.lanDegradedWindows = 0
                }

                // Safety valve: the low-latency UDP path is preferred, but a
                // pathological Wi-Fi/AP/packetization condition must never leave
                // the user at 5-10 FPS. After two consecutive bad windows, fall
                // back to the already-authenticated TCP video path for this
                // session. Reconnecting will try UDP again.
                if self.lanDegradedWindows >= 2 {
                    let ratio = self.stats.sourceFPS > 0
                        ? self.stats.receiveFPS / self.stats.sourceFPS : 0
                    self.stats.transport = "LAN · TCP recovery"
                    DiagnosticsLogger.shared.log("lan_fallback", fields: [
                        "reason": "Mac RX below 55% of device source FPS for two windows",
                        "mac_rx_fps": self.stats.receiveFPS,
                        "device_source_fps": self.stats.sourceFPS,
                        "ratio": ratio,
                    ])
                    self.session?.fallbackLANVideoToTCP(
                        reason: String(format: "Mac RX only %.0f%% of device FPS", ratio * 100)
                    )
                    self.lanDegradedWindows = 0
                }
            }
        }
    }

    func revealToolbar() {
        toolbarVisible = true
        toolbarHideTask?.cancel()
        guard !pointerInsideAccessory else { return }
        let delay = store.state.preferences.toolbarAutoHideDelay
        toolbarHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.toolbarVisible = false
        }
    }

    func setPointerInsideAccessory(_ inside: Bool) {
        pointerInsideAccessory = inside
        toolbarHideTask?.cancel()
        if inside {
            toolbarVisible = true
        } else {
            revealToolbar()
        }
    }

    func toggleAlwaysOnTop() {
        guard var device = currentDevice else { return }
        device.alwaysOnTop.toggle()
        store.upsert(device)
        AppWindowManager.shared.setAlwaysOnTop(device.alwaysOnTop)
    }

    func toggleBlackScreen() {
        guard let session else { return }
        blackScreenEnabled.toggle()
        session.setBlackScreen(blackScreenEnabled)
        if blackScreenEnabled {
            session.setAudio(true)
        } else if let device = currentDevice {
            session.setAudio(device.audioEnabled)
        }
    }

    func updateCurrentDevice(_ transform: (inout DeviceProfile) -> Void, applyVideo: Bool = false) {
        guard var device = currentDevice else { return }
        transform(&device)
        device.video.normalize()
        store.upsert(device)
        if applyVideo { Task { try? await session?.updateVideo(device.video) } }
        AppWindowManager.shared.setAlwaysOnTop(device.alwaysOnTop)
    }

    func setAudioEnabled(_ enabled: Bool) {
        updateCurrentDevice { $0.audioEnabled = enabled }
        if !blackScreenEnabled { session?.setAudio(enabled) }
    }

    func sendUnlockPassword(_ password: String) async {
        guard !password.isEmpty else { return }
        try? await session?.send(type: .unlock, payload: Data(password.utf8))
    }

    func systemAction(_ code: UInt16) { session?.systemAction(code) }
}

@MainActor
final class AppWindowManager {
    static let shared = AppWindowManager()
    weak var window: NSWindow?
    private var mirrorMode = false
    private var mirrorContentSize = CGSize(width: 393, height: 852)
    private var accessoryPanel: NSPanel?
    private var accessoryHostingView: NSHostingView<AnyView>?
    private var windowObservers: [NSObjectProtocol] = []
    private var mirrorDragStartOrigin: NSPoint?
    private var mirrorResizeActive = false

    func attach(_ window: NSWindow) {
        if self.window === window { return }
        removeWindowObservers()
        self.window = window
        window.isMovableByWindowBackground = !mirrorMode
        window.collectionBehavior = [.fullScreenAuxiliary, .managed]
        window.minSize = NSSize(width: 320, height: 480)
        installWindowObservers(window)
    }

    func setMirrorMode(_ enabled: Bool) {
        guard let window else { return }
        mirrorMode = enabled
        if enabled {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            // Do not expose AppKit's native resize/move interaction in the
            // borderless mirror. Both are implemented by our dedicated edge and
            // toolbar NSViews so there is exactly one frame-mutation path.
            window.styleMask = [.borderless, .miniaturizable]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            // Mirror dragging is entirely application-controlled. Leaving
            // AppKit's native move recognizer enabled lets it enter a window
            // move session at the same time we mutate the parent/child frames,
            // which can trap inside _endWindowMoveWithEvent on macOS 26.
            window.isMovable = false
            // Every mouse drag inside the phone belongs to iOS. Enabling
            // background dragging here caused macOS to move the whole window
            // instead of forwarding the gesture to the device.
            window.isMovableByWindowBackground = false
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.cornerRadius = 42
            window.contentView?.layer?.cornerCurve = .continuous
            window.contentView?.layer?.masksToBounds = true
            updateAspect(mirrorContentSize, forceResize: true)
            repositionMirrorAccessory()
        } else {
            hideMirrorAccessory()
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.isMovableByWindowBackground = true
            window.isMovable = true
            window.contentView?.layer?.cornerRadius = 0
            window.contentView?.layer?.masksToBounds = false
            window.contentAspectRatio = .zero
            window.minSize = NSSize(width: 760, height: 560)
            let current = window.frame
            if current.width < 760 || current.height < 560 {
                window.setContentSize(NSSize(width: 860, height: 620))
                window.center()
            }
        }
    }

    func updateAspect(_ size: CGSize, forceResize: Bool = false) {
        guard mirrorMode, let window, size.width > 0, size.height > 0 else { return }
        let previousAspect = mirrorContentSize.width / max(mirrorContentSize.height, 1)
        let nextAspect = size.width / size.height
        let orientationChanged = (previousAspect < 1) != (nextAspect < 1)
        mirrorContentSize = size
        window.contentAspectRatio = size
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let maxHeight = max(520, screen.height * 0.88)
        let maxWidth = max(560, screen.width * 0.82)
        let aspect = size.width / size.height
        let target: NSSize
        if aspect < 1 {
            let height = maxHeight
            target = NSSize(width: height * aspect, height: height)
            window.minSize = NSSize(width: 280, height: 280 / aspect)
        } else {
            let width = maxWidth
            target = NSSize(width: width, height: width / aspect)
            window.minSize = NSSize(width: 560, height: 560 / aspect)
        }
        let current = window.contentLayoutRect.size
        let currentAspect = current.width / max(current.height, 1)
        let ratioWrong = abs(currentAspect - aspect) > 0.01
        if forceResize || orientationChanged || ratioWrong {
            window.setContentSize(target)
            window.center()
        }
        repositionMirrorAccessory()
    }

    func setAlwaysOnTop(_ enabled: Bool) {
        let level: NSWindow.Level = enabled ? .floating : .normal
        window?.level = level
        accessoryPanel?.level = level
    }

    func showMirrorAccessory(model: AppModel, store: SettingsStore) {
        guard let window else { return }
        let root = AnyView(MirrorAccessoryBar(model: model, store: store))
        if let hosting = accessoryHostingView, let panel = accessoryPanel {
            hosting.rootView = root
            if panel.parent !== window {
                panel.parent?.removeChildWindow(panel)
                window.addChildWindow(panel, ordered: .above)
            }
            repositionMirrorAccessory()
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient]
        panel.level = window.level
        panel.ignoresMouseEvents = false
        // The panel itself must never begin AppKit's native window-drag path.
        // The dedicated handle below moves only the parent mirror window.
        panel.isMovable = false
        panel.isMovableByWindowBackground = false

        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 390, height: 52)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting

        accessoryPanel = panel
        accessoryHostingView = hosting
        window.addChildWindow(panel, ordered: .above)
        repositionMirrorAccessory()
    }

    func setMirrorAccessoryVisible(_ visible: Bool) {
        guard mirrorMode, let panel = accessoryPanel else { return }
        if visible {
            repositionMirrorAccessory()
            panel.orderFront(nil)
        } else {
            panel.orderOut(nil)
        }
    }

    func hideMirrorAccessory() {
        guard let panel = accessoryPanel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        accessoryPanel = nil
        accessoryHostingView = nil
        mirrorDragStartOrigin = nil
        mirrorResizeActive = false
    }

    func beginMirrorWindowDrag() {
        mirrorDragStartOrigin = window?.frame.origin
    }

    func updateMirrorWindowDrag(translation: CGSize) {
        guard let window, let start = mirrorDragStartOrigin else { return }
        window.setFrameOrigin(NSPoint(x: start.x + translation.width,
                                      y: start.y - translation.height))
        // NSWindow child windows follow their parent automatically. Mutating
        // the panel frame from inside the same drag event can collide with
        // AppKit's move bookkeeping and was observed in the supplied crash.
    }

    func endMirrorWindowDrag() {
        mirrorDragStartOrigin = nil
        repositionMirrorAccessory()
    }

    func beginMirrorWindowResize() {
        mirrorResizeActive = true
    }

    func endMirrorWindowResize() {
        mirrorResizeActive = false
        repositionMirrorAccessory()
    }

    private func repositionMirrorAccessory() {
        guard mirrorMode, let window, let panel = accessoryPanel else { return }
        let parent = window.frame
        let size = panel.frame.size
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let gap: CGFloat = 9

        let roomAbove = visible.maxY - parent.maxY
        let roomRight = visible.maxX - parent.maxX
        let roomLeft = parent.minX - visible.minX
        let origin: NSPoint
        if roomAbove >= size.height + gap {
            origin = NSPoint(
                x: min(max(parent.midX - size.width / 2, visible.minX), visible.maxX - size.width),
                y: parent.maxY + gap
            )
        } else if roomRight >= size.width + gap {
            origin = NSPoint(x: parent.maxX + gap,
                             y: min(max(parent.maxY - size.height, visible.minY), visible.maxY - size.height))
        } else if roomLeft >= size.width + gap {
            origin = NSPoint(x: parent.minX - size.width - gap,
                             y: min(max(parent.maxY - size.height, visible.minY), visible.maxY - size.height))
        } else {
            origin = NSPoint(
                x: min(max(parent.midX - size.width / 2, visible.minX), visible.maxX - size.width),
                y: max(visible.minY, parent.minY - size.height - gap)
            )
        }
        panel.setFrameOrigin(origin)
    }

    private func installWindowObservers(_ window: NSWindow) {
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didChangeScreenNotification] {
            windowObservers.append(center.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.mirrorDragStartOrigin == nil,
                          !self.mirrorResizeActive else { return }
                    self.repositionMirrorAccessory()
                }
            })
        }
    }

    private func removeWindowObservers() {
        let center = NotificationCenter.default
        windowObservers.forEach(center.removeObserver)
        windowObservers.removeAll()
    }
}

private struct HostPerformanceSample: Sendable {
    let receiveFPS: Double
    let presentFPS: Double
    let bitrateMbps: Double
    let receiveGapP50Ms: Double
    let receiveGapP95Ms: Double
    let receiveGapP99Ms: Double
    let receiveGapMaxMs: Double
    let decodeQueueP50Ms: Double
    let decodeQueueP95Ms: Double
    let decodeQueueP99Ms: Double
    let decodeP50Ms: Double
    let decodeP95Ms: Double
    let decodeP99Ms: Double
    let frameAgeP50Ms: Double
    let frameAgeP95Ms: Double
    let frameAgeP99Ms: Double
    let renderSubmitP50Ms: Double
    let renderSubmitP95Ms: Double
    let renderSubmitP99Ms: Double
    let inputSendP50Ms: Double
    let inputSendP95Ms: Double
    let inputSendP99Ms: Double
    let decodePendingMax: Int
}

private final class PerformanceCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedFrames = 0
    private var presentedFrames = 0
    private var receivedBytes = 0
    private var startedAt = ContinuousClock.now
    private var lastReceivedAtNanos: UInt64 = 0
    private var receiveGapMaxMs: Double = 0
    private var receiveGapSamples: [Double] = []
    private var decodeQueueSamples: [Double] = []
    private var decodeSamples: [Double] = []
    private var frameAgeSamples: [Double] = []
    private var renderSubmitSamples: [Double] = []
    private var inputSendSamples: [Double] = []
    private var decodePendingMax = 0

    func recordReceived(bytes: Int) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        if lastReceivedAtNanos > 0 {
            let gap = Double(now &- lastReceivedAtNanos) / 1_000_000
            receiveGapMaxMs = max(receiveGapMaxMs, gap)
            appendBounded(gap, to: &receiveGapSamples)
        }
        lastReceivedAtNanos = now
        receivedFrames += 1
        receivedBytes += bytes
        lock.unlock()
    }

    func recordPresented() {
        lock.lock()
        presentedFrames += 1
        lock.unlock()
    }

    func recordDecodeQueue(waitMs: Double, pending: Int) {
        lock.lock()
        appendBounded(waitMs, to: &decodeQueueSamples)
        decodePendingMax = max(decodePendingMax, pending)
        lock.unlock()
    }

    func recordDecode(latencyMs: Double) {
        lock.lock()
        appendBounded(latencyMs, to: &decodeSamples)
        lock.unlock()
    }

    func recordRender(frameAgeMs: Double, submitMs: Double) {
        lock.lock()
        appendBounded(frameAgeMs, to: &frameAgeSamples)
        appendBounded(submitMs, to: &renderSubmitSamples)
        lock.unlock()
    }

    func recordInputSend(latencyMs: Double) {
        lock.lock()
        appendBounded(latencyMs, to: &inputSendSamples)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        receivedFrames = 0
        presentedFrames = 0
        receivedBytes = 0
        lastReceivedAtNanos = 0
        receiveGapMaxMs = 0
        receiveGapSamples.removeAll(keepingCapacity: true)
        decodeQueueSamples.removeAll(keepingCapacity: true)
        decodeSamples.removeAll(keepingCapacity: true)
        frameAgeSamples.removeAll(keepingCapacity: true)
        renderSubmitSamples.removeAll(keepingCapacity: true)
        inputSendSamples.removeAll(keepingCapacity: true)
        decodePendingMax = 0
        startedAt = .now
        lock.unlock()
    }

    func consume() -> HostPerformanceSample {
        lock.lock()
        defer { lock.unlock() }
        let elapsed = startedAt.duration(to: .now)
        let seconds = max(
            0.001,
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        )
        let sample = HostPerformanceSample(
            receiveFPS: Double(receivedFrames) / seconds,
            presentFPS: Double(presentedFrames) / seconds,
            bitrateMbps: Double(receivedBytes * 8) / seconds / 1_000_000,
            receiveGapP50Ms: hostPercentile(receiveGapSamples, 0.50),
            receiveGapP95Ms: hostPercentile(receiveGapSamples, 0.95),
            receiveGapP99Ms: hostPercentile(receiveGapSamples, 0.99),
            receiveGapMaxMs: receiveGapMaxMs,
            decodeQueueP50Ms: hostPercentile(decodeQueueSamples, 0.50),
            decodeQueueP95Ms: hostPercentile(decodeQueueSamples, 0.95),
            decodeQueueP99Ms: hostPercentile(decodeQueueSamples, 0.99),
            decodeP50Ms: hostPercentile(decodeSamples, 0.50),
            decodeP95Ms: hostPercentile(decodeSamples, 0.95),
            decodeP99Ms: hostPercentile(decodeSamples, 0.99),
            frameAgeP50Ms: hostPercentile(frameAgeSamples, 0.50),
            frameAgeP95Ms: hostPercentile(frameAgeSamples, 0.95),
            frameAgeP99Ms: hostPercentile(frameAgeSamples, 0.99),
            renderSubmitP50Ms: hostPercentile(renderSubmitSamples, 0.50),
            renderSubmitP95Ms: hostPercentile(renderSubmitSamples, 0.95),
            renderSubmitP99Ms: hostPercentile(renderSubmitSamples, 0.99),
            inputSendP50Ms: hostPercentile(inputSendSamples, 0.50),
            inputSendP95Ms: hostPercentile(inputSendSamples, 0.95),
            inputSendP99Ms: hostPercentile(inputSendSamples, 0.99),
            decodePendingMax: decodePendingMax
        )
        receivedFrames = 0
        presentedFrames = 0
        receivedBytes = 0
        receiveGapMaxMs = 0
        receiveGapSamples.removeAll(keepingCapacity: true)
        decodeQueueSamples.removeAll(keepingCapacity: true)
        decodeSamples.removeAll(keepingCapacity: true)
        frameAgeSamples.removeAll(keepingCapacity: true)
        renderSubmitSamples.removeAll(keepingCapacity: true)
        inputSendSamples.removeAll(keepingCapacity: true)
        decodePendingMax = 0
        startedAt = .now
        return sample
    }

    private func appendBounded(_ value: Double, to samples: inout [Double]) {
        guard value.isFinite, value >= 0 else { return }
        if samples.count < 512 {
            samples.append(value)
        }
    }
}

private func hostPercentile(_ values: [Double], _ quantile: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let q = min(max(quantile, 0), 1)
    let index = Int((Double(sorted.count - 1) * q).rounded())
    return sorted[min(max(index, 0), sorted.count - 1)]
}
