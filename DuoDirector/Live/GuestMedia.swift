import AVFoundation
import CoreImage
import os

// =====================================================================================
//  Guest media (Phase 9): the room seam, the latest guest frame, the stream compositor,
//  and the guest-audio mixer.
//
//  Threading: guest frames/audio arrive on the room SDK's threads; host buffers arrive on
//  the capture queues. Everything here is lock-based and never blocks for long.
// =====================================================================================

/// The seam between DuoDirector and a WebRTC room SDK (LiveKit in Platform/
/// LiveKitGuestRoom.swift; MockGuestRoom for the Simulator, Demo Mode and tests).
protocol GuestRoomTransport: AnyObject, Sendable {
    func connect(serverURL: String, token: String) async throws
    func disconnect() async
    /// Host camera/mic buffers from the capture queues (BGRA video, PCM audio).
    func appendHost(_ sampleBuffer: CMSampleBuffer, mediaType: AVMediaType)
    var events: GuestRoomEvents { get }
}

/// Callbacks set by GuestSessionController before connect. Called from any thread.
final class GuestRoomEvents: @unchecked Sendable {
    var guestJoined: (@Sendable (String) -> Void)?
    var guestLeft: (@Sendable () -> Void)?
    var reconnecting: (@Sendable (Bool) -> Void)?
    var disconnected: (@Sendable (String?) -> Void)?
    var guestFrame: (@Sendable (CVPixelBuffer) -> Void)?
    var guestAudio: (@Sendable (AVAudioPCMBuffer) -> Void)?
}

// MARK: - Latest guest frame

/// Holds the newest guest frame for the preview tile and the stream compositor.
final class GuestFrameStore: Sendable {
    private struct Box: @unchecked Sendable { var buffer: CVPixelBuffer?; var at: Date? }
    private let box = OSAllocatedUnfairLock(initialState: Box())

    func put(_ buffer: CVPixelBuffer) { box.withLock { $0 = Box(buffer: buffer, at: .now) } }
    func clear() { box.withLock { $0 = Box() } }
    /// The frame, only if it's fresh (a frozen guest shouldn't stay in the stream).
    func freshFrame(now: Date = .now) -> CVPixelBuffer? {
        box.withLock { GuestPolicy.isFresh(lastFrameAt: $0.at, now: now) ? $0.buffer : nil }
    }
}

// MARK: - Stream compositor

/// Draws the guest over (or beside) the host frame with Core Image and returns a new
/// sample buffer with the host's timing, for the RTMP stream only. Recordings stay clean.
final class GuestStreamCompositor: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero
    private var layout: GuestLayout = .pictureInPicture

    func setLayout(_ layout: GuestLayout) { lock.withLock { self.layout = layout } }

    func composite(host sampleBuffer: CMSampleBuffer, guest: CVPixelBuffer) -> CMSampleBuffer? {
        guard let hostPixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let size = CGSize(width: CVPixelBufferGetWidth(hostPixels), height: CVPixelBufferGetHeight(hostPixels))
        let (layout, pool) = lock.withLock { (self.layout, self.pool(for: size)) }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return nil }

        let rects = layout.rects(canvas: size)
        let host = CIImage(cvPixelBuffer: hostPixels)
        let guestImage = CIImage(cvPixelBuffer: guest)
        let image = Self.fill(guestImage, into: rects.guest)
            .composited(over: Self.fill(host, into: rects.host))
            .composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)))
        context.render(image, to: out)

        var timing = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: out, formatDescriptionOut: &format)
        guard let format else { return nil }
        var result: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: out, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &result)
        return result
    }

    /// Aspect-fill `image` into `rect` (cropping the overflow).
    static func fill(_ image: CIImage, into rect: CGRect) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0, rect.width > 0, rect.height > 0 else { return CIImage.empty() }
        let scale = max(rect.width / e.width, rect.height / e.height)
        let scaled = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY).scaledBy(x: scale, y: scale))
        let dx = rect.midX - scaled.extent.width / 2, dy = rect.midY - scaled.extent.height / 2
        return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: rect)
    }

    private func pool(for size: CGSize) -> CVPixelBufferPool? {
        if let pool, poolSize == size { return pool }
        let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                    kCVPixelBufferWidthKey as String: Int(size.width),
                                    kCVPixelBufferHeightKey as String: Int(size.height),
                                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        var newPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &newPool)
        pool = newPool; poolSize = size
        return newPool
    }
}

// MARK: - Guest audio mixer

/// Mixes guest audio into the host's mic buffers for the stream. Guest PCM is converted
/// to the mic's format and queued; each mic buffer pulls the same number of frames.
/// If the guest falls behind, it's silence; if it races ahead, the queue is trimmed so
/// latency never builds up past `maxQueuedSeconds`.
final class GuestAudioMixer: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Float] = []            // interleaved, in the mic's channel count
    private var converter: AVAudioConverter?
    private var micFormat: AVAudioFormat?
    static let maxQueuedSeconds = 0.25

    func clear() { lock.withLock { queue.removeAll(keepingCapacity: true) } }

    /// Guest side (room SDK thread).
    func pushGuest(_ buffer: AVAudioPCMBuffer) {
        guard let target = lock.withLock({ micFormat }) else { return }
        let floatTarget = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: target.sampleRate,
                                        channels: target.channelCount, interleaved: true)!
        let conv: AVAudioConverter? = lock.withLock {
            if converter?.inputFormat != buffer.format || converter?.outputFormat != floatTarget {
                converter = AVAudioConverter(from: buffer.format, to: floatTarget)
            }
            return converter
        }
        guard let conv else { return }
        let ratio = floatTarget.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: floatTarget, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, let data = out.floatChannelData?[0] else { return }
        let count = Int(out.frameLength) * Int(floatTarget.channelCount)
        let samples = UnsafeBufferPointer(start: data, count: count)
        lock.withLock {
            queue.append(contentsOf: samples)
            let maxSamples = Int(target.sampleRate * Self.maxQueuedSeconds) * Int(target.channelCount)
            if queue.count > maxSamples { queue.removeFirst(queue.count - maxSamples) }
        }
    }

    /// Host side (audio capture queue): returns a new buffer with the guest mixed in, or
    /// the original when there's nothing to mix or the format isn't handled.
    func mix(into sampleBuffer: CMSampleBuffer, gain: Float = GuestPolicy.guestMixGain) -> CMSampleBuffer {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return sampleBuffer }
        let asbd = asbdPtr.pointee
        let format = AVAudioFormat(streamDescription: asbdPtr)
        lock.withLock { if micFormat?.sampleRate != asbd.mSampleRate || micFormat?.channelCount != asbd.mChannelsPerFrame { micFormat = format } }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        let channels = Int(asbd.mChannelsPerFrame)
        let isInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        guard frames > 0, isInterleaved, channels > 0 else { return sampleBuffer }

        let guest: [Float] = lock.withLock {
            let n = min(queue.count, frames * channels)
            defer { queue.removeFirst(n) }
            return Array(queue.prefix(n))
        }
        guard !guest.isEmpty else { return sampleBuffer }
        return Self.mixed(sampleBuffer, asbd: asbd, guest: guest, gain: gain) ?? sampleBuffer
    }

    /// Copies the mic PCM, adds the guest samples with clipping, and wraps it in a new
    /// sample buffer with the same timing. Int16 and Float32 interleaved are handled.
    private static func mixed(_ sb: CMSampleBuffer, asbd: AudioStreamBasicDescription, guest: [Float], gain: Float) -> CMSampleBuffer? {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes) == noErr else { return nil }
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        bytes.withUnsafeMutableBytes { raw in
            if isFloat && asbd.mBitsPerChannel == 32 {
                let p = raw.bindMemory(to: Float.self)
                for i in 0..<min(p.count, guest.count) { p[i] = max(-1, min(1, p[i] + guest[i] * gain)) }
            } else if !isFloat && asbd.mBitsPerChannel == 16 {
                let p = raw.bindMemory(to: Int16.self)
                for i in 0..<min(p.count, guest.count) {
                    let v = Float(p[i]) / 32768 + guest[i] * gain
                    p[i] = Int16(max(-1, min(1, v)) * 32767)
                }
            }
        }
        var newBlock: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &newBlock) == noErr, let newBlock,
              CMBlockBufferReplaceDataBytes(with: bytes, blockBuffer: newBlock, offsetIntoDestination: 0,
                                            dataLength: length) == noErr else { return nil }
        var timing = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(sb, at: 0, timingInfoOut: &timing)
        var out: CMSampleBuffer?
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: newBlock, formatDescription: CMSampleBufferGetFormatDescription(sb),
                                  sampleCount: CMSampleBufferGetNumSamples(sb), sampleTimingEntryCount: 1,
                                  sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                  sampleBufferOut: &out)
        return out
    }
}

// MARK: - Mock room

/// Simulator / Demo Mode room: a guest "joins" after 2 s and sends a moving test card
/// at 15 fps. Nothing touches the network. A server containing "fail" throws.
final class MockGuestRoom: GuestRoomTransport, @unchecked Sendable {
    let events = GuestRoomEvents()
    private var frameTask: Task<Void, Never>?
    private let context = CIContext()

    func connect(serverURL: String, token: String) async throws {
        try await Task.sleep(for: .milliseconds(700))
        if serverURL.contains("fail") { throw URLError(.cannotConnectToHost) }
        frameTask = Task { [events, context] in
            try? await Task.sleep(for: .seconds(2))
            events.guestJoined?("Sam (demo guest)")
            var t = 0.0
            while !Task.isCancelled {
                if let buffer = Self.testCard(t: t, context: context) { events.guestFrame?(buffer) }
                t += 1.0 / 15
                try? await Task.sleep(for: .milliseconds(66))
            }
        }
    }

    func disconnect() async { frameTask?.cancel(); frameTask = nil }
    func appendHost(_ sampleBuffer: CMSampleBuffer, mediaType: AVMediaType) {}

    private static func testCard(t: Double, context: CIContext) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        let hue = (sin(t / 3) + 1) / 2
        let a = CIColor(red: 0.15 + 0.3 * hue, green: 0.2, blue: 0.45 - 0.2 * hue)
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 640, y: 360),
            "inputColor0": a, "inputColor1": CIColor(red: 0.05, green: 0.05, blue: 0.1)])?.outputImage
        let dot = CIImage(color: CIColor(red: 1, green: 0.8, blue: 0.3))
            .cropped(to: CGRect(x: 300 + 120 * cos(t), y: 160 + 60 * sin(t * 1.3), width: 40, height: 40))
        if let image = gradient.map({ dot.composited(over: $0) })?.cropped(to: CGRect(x: 0, y: 0, width: 640, height: 360)) {
            context.render(image, to: buffer)
        }
        return buffer
    }
}
