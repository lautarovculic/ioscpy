import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

final class VideoDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var configuredCodec: VideoCodec?
    private var configuredSignature = Data()

    var onPixelBuffer: (@Sendable (PixelBufferEnvelope, Int, Int, Int) -> Void)?
    var onDecodeError: (@Sendable (String) -> Void)?
    var onDecodeLatency: (@Sendable (Double) -> Void)?

    deinit { invalidate() }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        self.session = nil
        formatDescription = nil
        configuredCodec = nil
        configuredSignature = Data()
    }

    func decode(_ packet: VideoPacket) {
        lock.lock()
        defer { lock.unlock() }

        if packet.isKeyframe || session == nil || configuredCodec != packet.codec {
            do {
                try configureIfNeeded(packet)
            } catch {
                onDecodeError?(error.localizedDescription)
                return
            }
        }
        guard let session, let formatDescription else {
            if packet.isKeyframe { onDecodeError?("关键帧缺少完整参数集") }
            return
        }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: packet.bytes.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: packet.bytes.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            onDecodeError?("无法创建视频块：\(blockStatus)")
            return
        }
        let replaceStatus = packet.bytes.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: packet.bytes.count
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else {
            onDecodeError?("无法写入视频块：\(replaceStatus)")
            return
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = packet.bytes.count
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .invalid,
            decodeTimeStamp: .invalid
        )
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            onDecodeError?("无法创建视频样本：\(sampleStatus)")
            return
        }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        let context = DecodeContext(
            owner: self,
            width: packet.width,
            height: packet.height,
            orientation: packet.orientation,
            submittedAtNanos: DispatchTime.now().uptimeNanoseconds
        )
        let pointer = Unmanaged.passRetained(context).toOpaque()
        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: VTDecodeFrameFlags(rawValue: 1 << 0),
            frameRefcon: pointer,
            infoFlagsOut: &infoFlags
        )
        if status != noErr {
            Unmanaged<DecodeContext>.fromOpaque(pointer).release()
            onDecodeError?("VideoToolbox 解码提交失败：\(status)")
            if status == kVTInvalidSessionErr || status == kVTVideoDecoderMalfunctionErr {
                VTDecompressionSessionInvalidate(session)
                self.session = nil
            }
        }
    }

    private func configureIfNeeded(_ packet: VideoPacket) throws {
        let sets = Self.parameterSets(in: packet.bytes, codec: packet.codec)
        let required = packet.codec == .hevc ? [32, 33, 34] : [7, 8]
        guard required.allSatisfy({ sets[$0] != nil }) else {
            if session == nil {
                throw ConnectionFailure.protocolError("\(packet.codec.title) 关键帧参数集不完整")
            }
            return
        }
        var signature = Data()
        for type in required { signature.append(sets[type]!) }
        if session != nil, configuredCodec == packet.codec, signature == configuredSignature {
            return
        }

        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil

        let descriptions = required.map { sets[$0]! as NSData }
        let pointers = descriptions.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        let sizes = descriptions.map(\.length)
        var format: CMFormatDescription?
        let status: OSStatus
        if packet.codec == .hevc {
            status = pointers.withUnsafeBufferPointer { pointerBuffer in
                sizes.withUnsafeBufferPointer { sizeBuffer in
                    CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: pointers.count,
                        parameterSetPointers: pointerBuffer.baseAddress!,
                        parameterSetSizes: sizeBuffer.baseAddress!,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &format
                    )
                }
            }
        } else {
            status = pointers.withUnsafeBufferPointer { pointerBuffer in
                sizes.withUnsafeBufferPointer { sizeBuffer in
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: pointers.count,
                        parameterSetPointers: pointerBuffer.baseAddress!,
                        parameterSetSizes: sizeBuffer.baseAddress!,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &format
                    )
                }
            }
        }
        guard status == noErr, let videoFormat = format else {
            throw ConnectionFailure.protocolError("无法创建 \(packet.codec.title) 格式描述：\(status)")
        }

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: Self.outputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        var created: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: videoFormat,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &created
        )
        guard createStatus == noErr, let created else {
            throw ConnectionFailure.protocolError("无法创建硬件解码会话：\(createStatus)")
        }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
        formatDescription = videoFormat
        configuredCodec = packet.codec
        configuredSignature = signature
    }

    private static func parameterSets(in data: Data, codec: VideoCodec) -> [Int: Data] {
        var output: [Int: Data] = [:]
        var offset = 0
        while offset + 4 <= data.count {
            let length = Int(data.readBE(UInt32.self, at: offset))
            offset += 4
            guard length > 0, offset + length <= data.count else { break }
            let nal = data.subdata(in: offset..<(offset + length))
            if let first = nal.first {
                let type = codec == .hevc ? Int((first >> 1) & 0x3F) : Int(first & 0x1F)
                if (codec == .hevc && (32...34).contains(type)) ||
                    (codec == .h264 && (type == 7 || type == 8)) {
                    output[type] = nal
                }
            }
            offset += length
        }
        return output
    }

    private static let outputCallback: VTDecompressionOutputCallback = {
        _, frameRefcon, status, _, imageBuffer, _, _ in
        guard let frameRefcon else { return }
        let context = Unmanaged<DecodeContext>.fromOpaque(frameRefcon).takeRetainedValue()
        guard status == noErr, let imageBuffer else {
            context.owner.onDecodeError?("VideoToolbox 解码回调失败：\(status)")
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        context.owner.onDecodeLatency?(Double(now &- context.submittedAtNanos) / 1_000_000)
        context.owner.onPixelBuffer?(PixelBufferEnvelope(imageBuffer), context.width, context.height, context.orientation)
    }
}

/// Decouples socket reads from VideoToolbox submission and enforces a bounded
/// encoded-frame queue. If the decoder falls behind, continuing to decode every
/// old inter-frame only increases visible control latency. Instead, discard the
/// stale chain, request a fresh keyframe, and resume from the newest decodable
/// point.
final class VideoDecodePump: @unchecked Sendable {
    private let decoder: VideoDecoder
    private let queue = DispatchQueue(label: "com.ioscpy.video-decode", qos: .userInteractive)
    private let lock = NSLock()
    private let maxPendingFrames: Int
    private var pendingFrames = 0
    private var generation: UInt64 = 1
    private var waitingForKeyframe = true
    private var resetDecoderBeforeNextKeyframe = true
    private var lastKeyframeRequestNanos: UInt64 = 0

    var onNeedKeyframe: (@Sendable () -> Void)?
    var onDroppedStaleChain: (@Sendable () -> Void)?
    var onQueueTelemetry: (@Sendable (Double, Int) -> Void)?

    init(decoder: VideoDecoder, maxPendingFrames: Int = 12) {
        self.decoder = decoder
        self.maxPendingFrames = max(1, maxPendingFrames)
    }

    func submit(_ packet: VideoPacket) {
        var shouldRequestKeyframe = false
        var shouldReportDrop = false
        var resetDecoder = false
        let currentGeneration: UInt64

        lock.lock()
        if waitingForKeyframe && !packet.isKeyframe {
            shouldRequestKeyframe = keyframeRequestDueLocked()
            lock.unlock()
            if shouldRequestKeyframe { onNeedKeyframe?() }
            return
        }

        if packet.isKeyframe {
            resetDecoder = resetDecoderBeforeNextKeyframe
            resetDecoderBeforeNextKeyframe = false
            waitingForKeyframe = false
        } else if pendingFrames >= maxPendingFrames {
            // Invalidate queued submissions logically. DispatchQueue work items
            // cannot be removed, but their generation check makes them no-ops,
            // allowing the requested keyframe to become the next decoded frame.
            generation &+= 1
            pendingFrames = 0
            waitingForKeyframe = true
            resetDecoderBeforeNextKeyframe = true
            shouldRequestKeyframe = keyframeRequestDueLocked()
            shouldReportDrop = true
            lock.unlock()
            if shouldReportDrop { onDroppedStaleChain?() }
            if shouldRequestKeyframe { onNeedKeyframe?() }
            return
        }

        pendingFrames += 1
        let pendingAtSubmit = pendingFrames
        currentGeneration = generation
        let shouldResetDecoder = resetDecoder
        let enqueuedAtNanos = DispatchTime.now().uptimeNanoseconds
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let startedAtNanos = DispatchTime.now().uptimeNanoseconds
            self.onQueueTelemetry?(
                Double(startedAtNanos &- enqueuedAtNanos) / 1_000_000,
                pendingAtSubmit
            )
            self.lock.lock()
            let valid = self.generation == currentGeneration
            self.lock.unlock()
            if valid {
                if shouldResetDecoder {
                    self.decoder.invalidate()
                }
                self.decoder.decode(packet)
            }
            self.finish(generation: currentGeneration)
        }
    }

    func reset() {
        lock.lock()
        generation &+= 1
        pendingFrames = 0
        waitingForKeyframe = true
        resetDecoderBeforeNextKeyframe = true
        lastKeyframeRequestNanos = 0
        lock.unlock()
        queue.async { [decoder] in decoder.invalidate() }
    }

    /// Mark the current inter-frame reference chain unusable (for example after
    /// an unrecoverable UDP sequence gap or a VideoToolbox decode error). Pending
    /// work becomes a no-op and dependent P-frames are ignored until the next
    /// IDR. The decoder is invalidated immediately before that IDR on the same
    /// serial queue so stale asynchronous callbacks cannot race the fresh chain.
    func breakReferenceChain() {
        var shouldRequestKeyframe = false
        var changed = false
        lock.lock()
        if !waitingForKeyframe || pendingFrames > 0 {
            generation &+= 1
            pendingFrames = 0
            waitingForKeyframe = true
            // Enqueue invalidation before releasing the state lock. Any fresh
            // keyframe submit must acquire this same lock first, so its decode
            // work is guaranteed to enter the serial queue after invalidation.
            // This stops stale asynchronous output from a broken HEVC reference
            // chain instead of letting -12909 callbacks continue until the IDR.
            queue.async { [decoder] in decoder.invalidate() }
            resetDecoderBeforeNextKeyframe = false
            changed = true
        }
        shouldRequestKeyframe = keyframeRequestDueLocked()
        lock.unlock()
        if changed { onDroppedStaleChain?() }
        if shouldRequestKeyframe { onNeedKeyframe?() }
    }

    private func finish(generation completedGeneration: UInt64) {
        lock.lock()
        if generation == completedGeneration, pendingFrames > 0 {
            pendingFrames -= 1
        }
        lock.unlock()
    }

    private func keyframeRequestDueLocked() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastKeyframeRequestNanos >= 300_000_000 else { return false }
        lastKeyframeRequestNanos = now
        return true
    }
}

final class PixelBufferEnvelope: @unchecked Sendable {
    let buffer: CVPixelBuffer

    init(_ buffer: CVPixelBuffer) {
        self.buffer = buffer
    }
}

private final class DecodeContext {
    unowned let owner: VideoDecoder
    let width: Int
    let height: Int
    let orientation: Int
    let submittedAtNanos: UInt64

    init(owner: VideoDecoder, width: Int, height: Int, orientation: Int, submittedAtNanos: UInt64) {
        self.owner = owner
        self.width = width
        self.height = height
        self.orientation = orientation
        self.submittedAtNanos = submittedAtNanos
    }
}
