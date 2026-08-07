import AppKit
import CoreVideo
import MetalKit

final class VideoFrameMailbox: @unchecked Sendable {
    struct Snapshot {
        let buffer: CVPixelBuffer
        let width: Int
        let height: Int
        let orientation: Int
        let generation: UInt64
        let publishedAtNanos: UInt64
    }

    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var width = 393
    private var height = 852
    private var orientation = 1
    private var generation: UInt64 = 0
    private var publishedAtNanos: UInt64 = 0

    @discardableResult
    func publish(_ buffer: CVPixelBuffer, width: Int, height: Int, orientation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let geometryChanged = self.width != width || self.height != height || self.orientation != orientation
        self.buffer = buffer
        self.width = max(width, 1)
        self.height = max(height, 1)
        self.orientation = orientation
        publishedAtNanos = DispatchTime.now().uptimeNanoseconds
        generation &+= 1
        return geometryChanged
    }

    func snapshot(after previousGeneration: UInt64) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard generation != previousGeneration, let buffer else { return nil }
        return Snapshot(
            buffer: buffer,
            width: width,
            height: height,
            orientation: orientation,
            generation: generation,
            publishedAtNanos: publishedAtNanos
        )
    }

    func geometry() -> (width: Int, height: Int, orientation: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (width, height, orientation)
    }
}

@MainActor
final class MirrorMetalView: MTKView, MTKViewDelegate, @preconcurrency NSTextInputClient {
    var onTouch: ((UInt8, Float, Float) -> Void)?
    var onScroll: ((Data) -> Void)?
    var onText: ((String) -> Void)?
    var onKey: ((UInt8) -> Void)?
    var onHomeGesture: (() -> Void)?
    var onFramePresented: (() -> Void)?
    var onRenderTelemetry: ((Double, Double) -> Void)?
    var onPointerActivity: (() -> Void)?

    private let mailbox: VideoFrameMailbox
    private var renderedGeneration: UInt64 = 0
    private var commandQueue: MTLCommandQueue!
    private var textureCache: CVMetalTextureCache?
    private var pipelineState: MTLRenderPipelineState!
    private var lastDisplayMaximumFPS = 0
    private var marked = NSMutableAttributedString()
    private var selection = NSRange(location: 0, length: 0)
    private var homeSwipeStart: (x: Float, y: Float)?
    private var homeSwipeTriggered = false

    init(frame frameRect: NSRect, device: MTLDevice?, mailbox: VideoFrameMailbox) {
        self.mailbox = mailbox
        let selectedDevice = device ?? MTLCreateSystemDefaultDevice()
        super.init(frame: frameRect, device: selectedDevice)
        // VideoToolbox already gives us IOSurface-backed NV12 buffers. Render
        // their Y/UV planes directly through CVMetalTextureCache instead of the
        // previous CIImage -> CoreImage -> Metal path, which telemetry showed
        // taking ~14-16 ms at P95 and capping visible presentation near 60 FPS.
        framebufferOnly = true
        enableSetNeedsDisplay = false
        isPaused = false
        autoResizeDrawable = true
        preferredFramesPerSecond = 120
        layer?.isOpaque = true
        wantsLayer = true
        clearColor = MTLClearColorMake(0.015, 0.015, 0.018, 1)
        delegate = self
        if let metalLayer = layer as? CAMetalLayer {
            // Two drawables keep presentation bounded to roughly one display
            // interval instead of allowing an extra queued frame to hide input
            // latency. Presentation remains synchronized to the physical panel.
            metalLayer.maximumDrawableCount = 2
            metalLayer.presentsWithTransaction = false
            metalLayer.displaySyncEnabled = true
        }
        if let selectedDevice {
            commandQueue = selectedDevice.makeCommandQueue()
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, selectedDevice, nil, &cache)
            textureCache = cache
            pipelineState = Self.makeNV12Pipeline(device: selectedDevice, pixelFormat: colorPixelFormat)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        ))
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func draw(in view: MTKView) {
        updateDisplayCadenceIfNeeded()
        guard let snapshot = mailbox.snapshot(after: renderedGeneration) else { return }
        let drawStartedAtNanos = DispatchTime.now().uptimeNanoseconds
        renderedGeneration = snapshot.generation
        let buffer = snapshot.buffer
        let orientation = snapshot.orientation
        guard CVPixelBufferGetPlaneCount(buffer) >= 2,
              let textureCache,
              let pipelineState,
              let drawable = currentDrawable,
              let descriptor = currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = clearColor

        let yWidth = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let yHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let uvWidth = CVPixelBufferGetWidthOfPlane(buffer, 1)
        let uvHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
        var yCVTexture: CVMetalTexture?
        var uvCVTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            buffer,
            nil,
            .r8Unorm,
            yWidth,
            yHeight,
            0,
            &yCVTexture
        ) == kCVReturnSuccess,
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            buffer,
            nil,
            .rg8Unorm,
            uvWidth,
            uvHeight,
            1,
            &uvCVTexture
        ) == kCVReturnSuccess,
        let yCVTexture,
        let uvCVTexture,
        let yTexture = CVMetalTextureGetTexture(yCVTexture),
        let uvTexture = CVMetalTextureGetTexture(uvCVTexture),
        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        let rotated = orientation == 3 || orientation == 4
        let sourceWidth = CGFloat(rotated ? snapshot.height : snapshot.width)
        let sourceHeight = CGFloat(rotated ? snapshot.width : snapshot.height)
        let targetWidth = max(drawableSize.width, 1)
        let targetHeight = max(drawableSize.height, 1)
        let sourceAspect = sourceWidth / max(sourceHeight, 1)
        let targetAspect = targetWidth / targetHeight
        let viewport: MTLViewport
        if targetAspect > sourceAspect {
            let width = targetHeight * sourceAspect
            viewport = MTLViewport(
                originX: Double((targetWidth - width) * 0.5),
                originY: 0,
                width: Double(width),
                height: Double(targetHeight),
                znear: 0,
                zfar: 1
            )
        } else {
            let height = targetWidth / sourceAspect
            viewport = MTLViewport(
                originX: 0,
                originY: Double((targetHeight - height) * 0.5),
                width: Double(targetWidth),
                height: Double(height),
                znear: 0,
                zfar: 1
            )
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setViewport(viewport)
        encoder.setFragmentTexture(yTexture, index: 0)
        encoder.setFragmentTexture(uvTexture, index: 1)
        var orientationValue = UInt32(orientation)
        encoder.setFragmentBytes(&orientationValue, length: MemoryLayout<UInt32>.size, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        // Presentation telemetry must not enqueue another main-thread closure
        // for every frame. The counter is thread-safe and this draw callback is
        // already synchronized with MTKView's display cadence.
        onFramePresented?()
        let committedAtNanos = DispatchTime.now().uptimeNanoseconds
        let frameAgeMs = Double(drawStartedAtNanos &- snapshot.publishedAtNanos) / 1_000_000
        let renderSubmitMs = Double(committedAtNanos &- drawStartedAtNanos) / 1_000_000
        onRenderTelemetry?(frameAgeMs, renderSubmitMs)
    }

    private func updateDisplayCadenceIfNeeded() {
        let screen = window?.screen ?? NSScreen.main
        let maximum = max(screen?.maximumFramesPerSecond ?? 60, 1)
        guard maximum != lastDisplayMaximumFPS else { return }
        lastDisplayMaximumFPS = maximum
        preferredFramesPerSecond = min(120, maximum)
        DiagnosticsLogger.shared.log("display_cadence", fields: [
            "screen": screen?.localizedName ?? "unknown",
            "display_refresh_hz": maximum,
            "preferred_fps": preferredFramesPerSecond,
            "drawable_width": drawableSize.width,
            "drawable_height": drawableSize.height,
        ])
    }

    private static func makeNV12Pipeline(
        device: MTLDevice,
        pixelFormat: MTLPixelFormat
    ) -> MTLRenderPipelineState? {
        let source = #"""
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 uv;
        };

        vertex VertexOut ioscpy_vertex(uint vertexID [[vertex_id]]) {
            constexpr float2 positions[4] = {
                float2(-1.0,  1.0),
                float2( 1.0,  1.0),
                float2(-1.0, -1.0),
                float2( 1.0, -1.0)
            };
            constexpr float2 texcoords[4] = {
                float2(0.0, 0.0),
                float2(1.0, 0.0),
                float2(0.0, 1.0),
                float2(1.0, 1.0)
            };
            VertexOut out;
            out.position = float4(positions[vertexID], 0.0, 1.0);
            out.uv = texcoords[vertexID];
            return out;
        }

        fragment float4 ioscpy_nv12_fragment(
            VertexOut in [[stage_in]],
            texture2d<float, access::sample> yTexture [[texture(0)]],
            texture2d<float, access::sample> uvTexture [[texture(1)]],
            constant uint &orientation [[buffer(0)]]) {
            constexpr sampler s(address::clamp_to_edge, filter::linear);
            float2 uv = in.uv;
            if (orientation == 2) {
                uv = float2(1.0 - uv.x, 1.0 - uv.y);
            } else if (orientation == 3) {
                uv = float2(uv.y, 1.0 - uv.x);
            } else if (orientation == 4) {
                uv = float2(1.0 - uv.y, uv.x);
            }

            // VideoToolbox is configured for bi-planar video-range NV12. Use a
            // BT.709 video-range conversion, appropriate for iPhone display
            // capture and much cheaper than a CoreImage render pass.
            float y = yTexture.sample(s, uv).r;
            float2 cbcr = uvTexture.sample(s, uv).rg - float2(0.5, 0.5);
            float yy = max((y - (16.0 / 255.0)) * (255.0 / 219.0), 0.0);
            float3 rgb;
            rgb.r = yy + 1.5748 * cbcr.y;
            rgb.g = yy - 0.1873 * cbcr.x - 0.4681 * cbcr.y;
            rgb.b = yy + 1.8556 * cbcr.x;
            return float4(clamp(rgb, 0.0, 1.0), 1.0);
        }
        """#

        do {
            let library = try device.makeLibrary(source: source, options: nil)
            guard let vertex = library.makeFunction(name: "ioscpy_vertex"),
                  let fragment = library.makeFunction(name: "ioscpy_nv12_fragment") else {
                return nil
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            DiagnosticsLogger.shared.logMessage(
                "metal_pipeline_error",
                "NV12 pipeline compile failed: \(error.localizedDescription)"
            )
            return nil
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    override func mouseEntered(with event: NSEvent) { reportPointerActivity(event) }
    override func mouseMoved(with event: NSEvent) { reportPointerActivity(event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = normalizedPoint(event)
        homeSwipeStart = point.y >= 0.965 ? point : nil
        homeSwipeTriggered = false
        // The physical Home-indicator area belongs to SpringBoard's system
        // gesture arena, not the foreground app. Reserve it here as well so the
        // app does not receive a stray touch before we decide this is Home.
        if homeSwipeStart != nil { return }
        onTouch?(0, point.x, point.y)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = normalizedPoint(event)
        if !homeSwipeTriggered, let start = homeSwipeStart {
            let upward = start.y - point.y
            let horizontal = abs(point.x - start.x)
            // Mirror the iPhone Home-indicator gesture. IOHID injection does not
            // always enter SpringBoard's system-gesture arena, so a deliberate
            // upward swipe that begins on the bottom indicator is promoted to
            // the same Home action. Keep the start zone narrow so ordinary app
            // scrolling near the bottom remains untouched.
            if upward >= 0.105, horizontal <= 0.28 {
                homeSwipeTriggered = true
                onHomeGesture?()
            }
            return
        }
        onTouch?(1, point.x, point.y)
    }

    override func mouseUp(with event: NSEvent) {
        let point = normalizedPoint(event)
        if homeSwipeStart == nil {
            onTouch?(2, point.x, point.y)
        }
        homeSwipeStart = nil
        homeSwipeTriggered = false
    }

    override func scrollWheel(with event: NSEvent) {
        let point = normalizedPoint(event)
        let payload = makeScrollPayload(
            phase: Self.phaseCode(event.phase),
            momentumPhase: Self.phaseCode(event.momentumPhase),
            precise: event.hasPreciseScrollingDeltas,
            deltaX: Float(event.scrollingDeltaX),
            deltaY: Float(event.scrollingDeltaY),
            x: point.x,
            y: point.y,
            timestampNanos: UInt64(event.timestamp * 1_000_000_000)
        )
        onScroll?(payload)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), let chars = event.charactersIgnoringModifiers?.lowercased() {
            let mapping: [String: UInt8] = ["a": 10, "c": 11, "v": 12, "x": 13, "z": 14]
            if let code = mapping[chars] { onKey?(code); return }
        }
        switch event.keyCode {
        case 36, 76: onKey?(1)
        case 51, 117: onKey?(2)
        case 48: onKey?(3)
        case 53: onKey?(4)
        case 123: onKey?(5)
        case 124: onKey?(6)
        case 126: onKey?(7)
        case 125: onKey?(8)
        default:
            interpretKeyEvents([event])
        }
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)): onKey?(1)
        case #selector(deleteBackward(_:)), #selector(deleteForward(_:)): onKey?(2)
        case #selector(insertTab(_:)): onKey?(3)
        case #selector(cancelOperation(_:)): onKey?(4)
        case #selector(moveLeft(_:)): onKey?(5)
        case #selector(moveRight(_:)): onKey?(6)
        case #selector(moveUp(_:)): onKey?(7)
        case #selector(moveDown(_:)): onKey?(8)
        default: break
        }
    }

    private func normalizedPoint(_ event: NSEvent) -> (x: Float, y: Float) {
        let point = convert(event.locationInWindow, from: nil)
        let geometry = mailbox.geometry()
        let width = geometry.width
        let height = geometry.height
        let orientation = geometry.orientation
        let uprightWidth = (orientation == 3 || orientation == 4) ? height : width
        let uprightHeight = (orientation == 3 || orientation == 4) ? width : height
        let sourceAspect = CGFloat(uprightWidth) / CGFloat(max(uprightHeight, 1))
        let viewAspect = bounds.width / max(bounds.height, 1)
        let contentRect: CGRect
        if viewAspect > sourceAspect {
            let contentWidth = bounds.height * sourceAspect
            contentRect = CGRect(
                x: (bounds.width - contentWidth) * 0.5,
                y: 0,
                width: contentWidth,
                height: bounds.height
            )
        } else {
            let contentHeight = bounds.width / sourceAspect
            contentRect = CGRect(
                x: 0,
                y: (bounds.height - contentHeight) * 0.5,
                width: bounds.width,
                height: contentHeight
            )
        }
        let u = Float(min(max((point.x - contentRect.minX) / max(contentRect.width, 1), 0), 1))
        let v = Float(min(max(1 - (point.y - contentRect.minY) / max(contentRect.height, 1), 0), 1))
        return (u, v)
    }

    private func reportPointerActivity(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let nearTop = point.y >= bounds.maxY - 72
        let nearRight = point.x >= bounds.maxX - 72
        if nearTop || nearRight {
            onPointerActivity?()
        }
    }

    private static func phaseCode(_ phase: NSEvent.Phase) -> UInt8 {
        if phase.contains(.began) { return 1 }
        if phase.contains(.changed) { return 2 }
        if phase.contains(.ended) { return 3 }
        if phase.contains(.cancelled) { return 4 }
        if phase.contains(.mayBegin) { return 5 }
        return 0
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let value: String
        if let attributed = string as? NSAttributedString {
            value = attributed.string
        } else {
            value = String(describing: string)
        }
        marked = NSMutableAttributedString()
        selection = NSRange(location: 0, length: 0)
        onText?(value)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let attributed = string as? NSAttributedString {
            marked = NSMutableAttributedString(attributedString: attributed)
        } else {
            marked = NSMutableAttributedString(string: String(describing: string))
        }
        selection = selectedRange
    }

    func unmarkText() {
        marked = NSMutableAttributedString()
        selection = NSRange(location: 0, length: 0)
    }

    func selectedRange() -> NSRange { selection }

    func markedRange() -> NSRange {
        marked.length == 0 ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: marked.length)
    }

    func hasMarkedText() -> Bool { marked.length > 0 }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard range.location != NSNotFound, NSMaxRange(range) <= marked.length else { return nil }
        actualRange?.pointee = range
        return marked.attributedSubstring(from: range)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .markedClauseSegment, .textAlternatives]
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        guard let window else { return .zero }
        let local = NSRect(x: bounds.midX, y: bounds.maxY - 8, width: 1, height: 22)
        let windowRect = convert(local, to: nil)
        return window.convertToScreen(windowRect)
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func conversationIdentifier() -> Int { Int(bitPattern: ObjectIdentifier(self)) }

    func draw(_: NSRect, forCharacterRange: NSRange, actualRange: NSRangePointer?) {}

    func fractionOfDistanceThroughGlyph(for point: NSPoint) -> CGFloat { 0 }

    func baselineDeltaForCharacter(at index: Int) -> CGFloat { 0 }

    func windowLevel() -> Int { Int(window?.level.rawValue ?? 0) }
}
