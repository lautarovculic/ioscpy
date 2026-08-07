import AppKit
import MetalKit
import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore

    init(model: AppModel) {
        self.model = model
        self.store = model.store
    }

    var body: some View {
        ZStack {
            switch model.screen {
            case .home:
                HomeView(model: model, store: store)
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            case .connecting:
                ConnectingView(model: model)
                    .transition(.opacity)
            case .mirror:
                MirrorView(model: model, store: store)
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.28), value: model.screen)
        .background(WindowAccessor())
        .sheet(isPresented: $model.showingPairing) {
            PairingSheet(model: model)
        }
        .sheet(isPresented: $model.showingSettings) {
            SettingsSheet(model: model, store: store)
                .frame(minWidth: 620, minHeight: 650)
        }
    }
}

struct HomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color.accentColor.opacity(0.11), Color.black.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                header
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                        ForEach(store.state.devices) { device in
                            DeviceCard(model: model, store: store, device: device)
                        }
                        AddDeviceCard { model.addLANDevice() }
                    }
                    .padding(.horizontal, 4)
                }
                statusBar
            }
            .padding(28)
        }
        .task { await model.refreshDevices() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .frame(width: 64, height: 64)
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 30, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.primary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("ioscpy dream")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("原生 120 FPS · USB 与局域网 · Apple Silicon")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.refreshDevices() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .buttonStyle(GlassButtonStyle())
            Button {
                model.currentDeviceID = store.state.preferences.lastDeviceID ?? store.state.devices.first?.id
                model.showingSettings = true
            } label: {
                Label("设置", systemImage: "gearshape")
            }
            .buttonStyle(GlassButtonStyle())
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(model.status.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Text("配置自动保存")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var statusColor: Color {
        switch model.status {
        case .failed: return .red
        case .connecting, .reconnecting, .pairing: return .orange
        case .connected: return .green
        default: return .secondary
        }
    }
}

struct DeviceCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore
    let device: DeviceProfile

    private var usbAvailable: Bool {
        guard let udid = device.udid else { return false }
        return model.discoveredUDIDs.contains(udid)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.thinMaterial)
                        .frame(width: 50, height: 58)
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 27, weight: .medium))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name)
                        .font(.headline)
                    HStack(spacing: 6) {
                        connectionBadge(title: "USB", active: usbAvailable)
                        connectionBadge(title: "LAN", active: !device.lanHost.isEmpty)
                    }
                }
                Spacer()
                Button {
                    model.currentDeviceID = device.id
                    model.showingSettings = true
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                infoRow("画质", "\(device.video.codec.title) · 原生 · \(device.video.targetFPS) FPS")
                infoRow("信任", device.pairingValid ? "局域网配对有效" : "未配对或已过期")
                if let date = device.lastConnectedAt {
                    infoRow("上次连接", date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .font(.caption)

            HStack(spacing: 10) {
                Button {
                    Task { await model.connect(device: device, mode: .usb) }
                } label: {
                    Label("USB", systemImage: "cable.connector")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle(prominent: device.preferredMode == .usb))
                .disabled(!usbAvailable)

                Button {
                    Task { await model.connect(device: device, mode: .lan) }
                } label: {
                    Label("局域网", systemImage: "wifi")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle(prominent: device.preferredMode == .lan))
                .disabled(device.lanHost.isEmpty)
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 0.75)
        }
    }

    private func connectionBadge(title: String, active: Bool) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(active ? .primary : .tertiary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(active ? Color.green.opacity(0.16) : Color.secondary.opacity(0.08), in: Capsule())
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.tertiary)
            Spacer()
            Text(value).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct AddDeviceCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 34, weight: .light))
                Text("添加局域网设备")
                    .font(.headline)
                Text("填写 IP 后，iPhone 会显示 4 位配对码")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 192)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6]))
                .foregroundStyle(.secondary.opacity(0.35))
        }
    }
}

struct ConnectingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.92), Color.accentColor.opacity(0.22)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 20) {
                ProgressView().controlSize(.large)
                Text(model.status.message)
                    .font(.headline)
                    .foregroundStyle(.white)
                Button("取消") { model.disconnect() }
                    .buttonStyle(GlassButtonStyle())
            }
            .padding(32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
    }
}

struct MirrorView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore

    private var device: DeviceProfile? { model.currentDevice }
    private var cornerRadius: CGFloat { device?.deviceFrame == true ? 42 : 34 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black)
            MirrorRepresentable(model: model)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    if device?.deviceFrame == true {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.94), lineWidth: 7)
                            .overlay {
                                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                    .strokeBorder(.white.opacity(0.16), lineWidth: 0.7)
                            }
                    }
                }
                .shadow(color: .black.opacity(0.48), radius: 18, y: 8)
            MirrorEdgeResizeRepresentable()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .background(Color.clear)
        .onAppear {
            AppWindowManager.shared.showMirrorAccessory(model: model, store: store)
            AppWindowManager.shared.setMirrorAccessoryVisible(model.toolbarVisible)
        }
        .onChange(of: model.toolbarVisible) { _, visible in
            AppWindowManager.shared.setMirrorAccessoryVisible(visible)
        }
        .onDisappear {
            AppWindowManager.shared.hideMirrorAccessory()
        }
        .ignoresSafeArea()
    }
}

struct MirrorAccessoryBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore

    private var device: DeviceProfile? { model.currentDevice }

    private var displayedFPS: Double {
        // What matters to the user is the complete frame rate that actually
        // reached the Mac. Device-side source FPS can look perfect while TCP
        // retransmission or Wi-Fi jitter starves playback.
        model.stats.receiveFPS > 0 ? model.stats.receiveFPS : model.stats.sourceFPS
    }

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                MirrorWindowDragHandleRepresentable()
            }
            .frame(width: 30, height: 31)
            .help("拖动镜像窗口")

            Text(String(format: "%.0f FPS", displayedFPS))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(displayedFPS >= 100 ? Color.green : Color.primary)
                .frame(minWidth: 53, alignment: .leading)
                .help(String(format: "%@ · Mac RX %.1f · device %.1f · %.1f Mbps · RTT %.1f ms\ncapture %.2f/%.2f ms · encode %.2f/%.2f ms · timer gap %.2f ms\ndrops C:%llu E:%llu S:%llu T:%llu R:%llu\nLAN %.0f pkt/s · frame RX %.2f/%.2f ms · FEC %llu · lost %llu · late %llu",
                             model.stats.transport,
                             model.stats.receiveFPS,
                             model.stats.sourceFPS,
                             model.stats.bitrateMbps,
                             model.stats.latencyMs,
                             model.stats.captureMs,
                             model.stats.captureMsMax,
                             model.stats.encodeMs,
                             model.stats.encodeMsMax,
                             model.stats.captureGapMsMax,
                             model.stats.dropCapturePressure,
                             model.stats.dropEncoderPressure,
                             model.stats.dropSendPressure,
                             model.stats.dropTransport,
                             model.stats.dropReferenceChain,
                             model.stats.lanPacketsPerSecond,
                             model.stats.lanFrameReceiveMs,
                             model.stats.lanFrameReceiveMsMax,
                             model.stats.lanRecoveredFrames,
                             model.stats.lanLostFrames,
                             model.stats.lanLateFrames))

            Divider().frame(height: 22).opacity(0.4)
            toolbarButton("house", help: "主屏幕") { model.systemAction(1) }
            toolbarButton("square.grid.2x2", help: "App 切换器") { model.systemAction(4) }
            toolbarButton(device?.alwaysOnTop == true ? "pin.fill" : "pin", help: "置顶") {
                model.toggleAlwaysOnTop()
            }
            toolbarButton(model.blackScreenEnabled ? "display" : "display.slash", help: "手机黑屏") {
                model.toggleBlackScreen()
            }
            toolbarButton("lock", help: "锁定") { model.systemAction(2) }
            toolbarButton("gearshape", help: "设置") { model.showingSettings = true }
            toolbarButton("rectangle.portrait.and.arrow.right", help: "断开") { model.disconnect() }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
        .glassEffect(.regular, in: .capsule)
        .overlay { Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.7) }
        .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
        .frame(width: 390, height: 52)
        .onHover { model.setPointerInsideAccessory($0) }
    }

    private func toolbarButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 31, height: 31)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(.white.opacity(0.001), in: Circle())
        .help(help)
    }
}

struct SettingsSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore
    @Environment(\.dismiss) private var dismiss

    private var device: DeviceProfile? { model.currentDevice }

    var body: some View {
        NavigationStack {
            Form {
                if let device {
                    Section("设备") {
                        TextField("设备名称", text: binding(\.name))
                        Picker("默认连接", selection: binding(\.preferredMode)) {
                            ForEach(ConnectionMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }
                        TextField("局域网 IP", text: binding(\.lanHost))
                        TextField("端口", value: binding(\.lanPort), format: .number)
                        SecureField("锁屏密码（本地明文保存）", text: binding(\.lockPassword))
                        Toggle("此设备自动连接", isOn: binding(\.autoConnect))
                        LabeledContent("连接状态", value: model.status.message)
                        Button {
                            let profile = device
                            dismiss()
                            Task { await model.connect(device: profile, mode: .lan) }
                        } label: {
                            Label(
                                device.pairingValid ? "通过局域网连接" : "连接并显示 4 位配对码",
                                systemImage: "wifi"
                            )
                        }
                        .disabled(device.lanHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Text("填写 IP 不会自动发起连接。点击上方按钮后，iPhone 才会亮屏并显示配对码；失败原因会显示在主页底部。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section("极致画质") {
                        HStack {
                            Button("原生零缩放 120 FPS") {
                                model.updateCurrentDevice({ $0.video = .extreme }, applyVideo: true)
                            }
                            Button("2160p 兼容 120 FPS") {
                                model.updateCurrentDevice({ $0.video = .compatibility120 }, applyVideo: true)
                            }
                            Button("原生 HEVC（实验）") {
                                model.updateCurrentDevice({ $0.video = .nativeHEVC }, applyVideo: true)
                            }
                        }
                        Picker("编码", selection: videoBinding(\.codec)) {
                            ForEach(VideoCodec.allCases) { codec in Text(codec.title).tag(codec) }
                        }
                        .pickerStyle(.segmented)
                        Picker("帧率", selection: videoBinding(\.targetFPS)) {
                            ForEach([60, 90, 120], id: \.self) { Text("\($0) FPS").tag($0) }
                        }
                        Picker("分辨率", selection: videoBinding(\.maxDimension)) {
                            Text("1440p").tag(1440)
                            Text("1800p").tag(1800)
                            Text("2160p").tag(2160)
                            Text("原生").tag(4096)
                        }
                        Picker("VBR 上限", selection: videoBinding(\.bitrateMbps)) {
                            ForEach([25, 35, 45, 60], id: \.self) { Text("\($0) Mbps").tag($0) }
                        }
                        Text("默认使用原生分辨率 H.264、120 FPS、45 Mbps，绕过手机端同步缩放；2160p 兼容模式保留为回退项。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section("窗口与交互") {
                        Toggle("始终置顶", isOn: binding(\.alwaysOnTop))
                        Toggle("显示 iPhone 设备壳", isOn: binding(\.deviceFrame))
                        Toggle("同步系统播放音频", isOn: Binding(
                            get: { device.audioEnabled },
                            set: { model.setAudioEnabled($0) }
                        ))
                        Text("手机黑屏时会强制同步音频到 Mac，退出黑屏后恢复此开关。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section("信任") {
                        LabeledContent("状态", value: device.pairingValid ? "有效" : "未配对或过期")
                        if let expires = device.pairExpiresAt {
                            LabeledContent("到期", value: expires.formatted(date: .abbreviated, time: .shortened))
                        }
                        Button("清除局域网信任") {
                            model.updateCurrentDevice {
                                $0.pairToken = nil
                                $0.pairExpiresAt = nil
                            }
                        }
                    }

                    Section {
                        Button("忘记此设备", role: .destructive) {
                            store.remove(id: device.id)
                            model.currentDeviceID = nil
                            dismiss()
                        }
                    }
                }

                Section("应用") {
                    Toggle("启动时自动连接上次设备", isOn: Binding(
                        get: { store.state.preferences.autoConnectLastDevice },
                        set: {
                            store.state.preferences.autoConnectLastDevice = $0
                            store.save()
                        }
                    ))
                    Toggle("显示实时性能数据", isOn: Binding(
                        get: { store.state.preferences.diagnosticsOverlay },
                        set: {
                            store.state.preferences.diagnosticsOverlay = $0
                            store.save()
                        }
                    ))
                }
            }
            .formStyle(.grouped)
            .navigationTitle(device?.name ?? "设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<DeviceProfile, Value>) -> Binding<Value> {
        Binding(
            get: { device![keyPath: keyPath] },
            set: { value in model.updateCurrentDevice { $0[keyPath: keyPath] = value } }
        )
    }

    private func videoBinding<Value>(_ keyPath: WritableKeyPath<VideoSettings, Value>) -> Binding<Value> {
        Binding(
            get: { device!.video[keyPath: keyPath] },
            set: { value in
                model.updateCurrentDevice({ $0.video[keyPath: keyPath] = value }, applyVideo: true)
            }
        )
    }
}

struct PairingSheet: View {
    @ObservedObject var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 42, weight: .medium))
                .symbolRenderingMode(.hierarchical)
            Text("输入 iPhone 上的配对码")
                .font(.title2.weight(.semibold))
            Text("配对码由 iPhone 系统级卡片显示，120 秒内有效。")
                .foregroundStyle(.secondary)
            TextField("0000", text: $model.pairingCode)
                .textFieldStyle(.plain)
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .frame(width: 180)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .focused($focused)
                .onChange(of: model.pairingCode) { _, value in
                    model.pairingCode = String(value.filter(\.isNumber).prefix(4))
                }
                .onSubmit { model.submitPairingCode() }
            HStack {
                Button("取消") { model.showingPairing = false }
                Button("配对") { model.submitPairingCode() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.pairingCode.count != 4)
            }
        }
        .padding(34)
        .frame(width: 420)
        .onAppear { focused = true }
    }
}

struct MirrorRepresentable: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> MirrorMetalView {
        let view = MirrorMetalView(
            frame: .zero,
            device: MTLCreateSystemDefaultDevice(),
            mailbox: model.frameMailbox
        )
        model.attachMirrorView(view)
        return view
    }

    func updateNSView(_ nsView: MirrorMetalView, context: Context) {
        // Callbacks and the mailbox are stable for the lifetime of the native
        // view. Reattaching on every SwiftUI state update needlessly churns the
        // hot input/render path.
    }
}

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window { AppWindowManager.shared.attach(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window { AppWindowManager.shared.attach(window) }
        }
    }
}

struct GlassButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(
                prominent ? AnyShapeStyle(Color.accentColor.opacity(configuration.isPressed ? 0.72 : 0.9))
                    : AnyShapeStyle(.ultraThinMaterial),
                in: Capsule()
            )
            .overlay { Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.6) }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
