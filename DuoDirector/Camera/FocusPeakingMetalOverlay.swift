import AVFoundation
import CoreImage
import ImageIO
import Metal
import Observation
import os
import SwiftUI

// =====================================================================================
//  Focus peaking + zebra stripes (Phase 2)
//
//  Pipeline (all off the main thread):
//
//    AVCaptureVideoDataOutput (BGRA, late frames discarded)            ← live
//    MockFrameSource (synthetic CIImage scene, 30fps)                   ← Simulator
//        │
//        ▼  FrameAnalyzer.analyze(_:)  on the analysis queue, throttled to ~15fps
//    CIImage ─ downscale to 540px ─┬─ luma ─ Sobel Gx/Gy ─ |G|² ─ threshold ─ red mask    (peaking)
//                                  └─ luma ─ sRGB curve ─ threshold(zebraThreshold) ─ mask
//                                                      × 45° stripes                       (zebras)
//        │  rendered by a METAL-backed CIContext into one small CGImage
//        ▼
//    AnalysisOverlayStore.overlay (@Observable, main actor)
//        │
//        ▼
//    FocusPeakingMetalOverlay (SwiftUI), drawn aspect-fill inside PreviewSurface on BOTH
//    displays, so it lines up with the aspect-fill preview and mirrors with it.
//
//  Why this can't slow recording: AVCaptureMovieFileOutput encodes from its own
//  connection. This branch runs on a utility-QoS queue, drops frames whenever it's busy
//  (`isBusy` gate + alwaysDiscardsLateVideoFrames) and works on a ~0.3MP downscale.
//
//  Built-in CI filters only, so no .ci.metal kernel or `-fcikernel` build flag is needed.
//  A custom Metal kernel is a drop-in replacement inside `makeOverlay(for:)` later if
//  profiling asks for it.
// =====================================================================================

/// Latest overlay frame for the UI. Shared by both displays.
@Observable
@MainActor
final class AnalysisOverlayStore {
    /// Peaking + zebra overlay (transparent elsewhere), or nil when both are off.
    var overlay: CGImage?
    /// Mock mode only: the synthetic camera picture, so preview and overlay align exactly.
    var mockFrame: CGImage?
    /// Phase 3: 64-bin display-referred luma histogram, normalized 0…1 (empty when off).
    var histogram: [Float] = []
    /// Phase 4 mock mode: the synthetic INNER (Host) camera for dual-cam previews.
    var mockInnerFrame: CGImage?
    /// Phase 4: true while the thermal guard has paused GPU overlays (shown as a pill).
    var isThermallyPaused = false
}

final class FrameAnalyzer: @unchecked Sendable {

    struct Settings: Sendable, Equatable {
        var peaking = false
        var zebra = false
        var zebraThreshold: Double = 0.95
        var peakingSensitivity: Double = 0.06   // |gradient|² threshold on 0…1 luma
        var histogram = false
        var anyEnabled: Bool { peaking || zebra || histogram }
    }

    static let histogramBins = 64

    private let settings = OSAllocatedUnfairLock(initialState: Settings())
    private let busy = OSAllocatedUnfairLock(initialState: false)
    private var lastAnalysis = Date.distantPast
    private let minInterval: TimeInterval = 1.0 / 15
    private let targetWidth: CGFloat = 540

    let context: CIContext
    private let onOverlay: @Sendable (CGImage?) -> Void
    private let onHistogram: @Sendable ([Float]) -> Void

    init(onOverlay: @escaping @Sendable (CGImage?) -> Void,
         onHistogram: @escaping @Sendable ([Float]) -> Void) {
        // Metal-backed Core Image context; half-float working format keeps the negative
        // Sobel gradients intact between filters.
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
        } else {
            context = CIContext(options: [.workingFormat: CIFormat.RGBAh])
        }
        self.onOverlay = onOverlay
        self.onHistogram = onHistogram
    }

    func update(_ newValue: Settings) {
        let changed = settings.withLock { (old: inout Settings) -> Bool in
            defer { old = newValue }
            return old != newValue
        }
        if changed && !newValue.peaking && !newValue.zebra { onOverlay(nil) }
        if changed && !newValue.histogram { onHistogram([]) }
    }

    /// Live path (video data output queue).
    func analyze(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        emitThumbnailIfNeeded(image)
        guard shouldAnalyze() else { return }
        process(image)
    }

    /// Mock path (MockFrameSource queue).
    func analyze(_ image: CIImage) {
        emitThumbnailIfNeeded(image)
        guard shouldAnalyze() else { return }
        process(image)
    }

    // MARK: Phase 6: remote-producer thumbnails

    private let thumbnailSink = OSAllocatedUnfairLock<(@Sendable (Data) -> Void)?>(initialState: nil)
    private let lastThumbnailAt = OSAllocatedUnfairLock(initialState: Date.distantPast)
    /// ~4 fps, 320 pt wide, JPEG q0.5 (≈10–20 KB). nil turns the tap off (zero cost).
    static let thumbnailInterval: TimeInterval = 0.25

    func setThumbnailSink(_ sink: (@Sendable (Data) -> Void)?) {
        thumbnailSink.withLock { $0 = sink }
    }

    private func emitThumbnailIfNeeded(_ image: CIImage) {
        guard let sink = thumbnailSink.withLock({ $0 }) else { return }
        let now = Date()
        let due = lastThumbnailAt.withLock { (last: inout Date) -> Bool in
            guard now.timeIntervalSince(last) >= Self.thumbnailInterval else { return false }
            last = now
            return true
        }
        guard due, image.extent.width > 0 else { return }
        let scale = 320 / image.extent.width
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let data = context.jpegRepresentation(
                of: small, colorSpace: colorSpace,
                options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.5])
        else { return }
        sink(data)
    }

    private func shouldAnalyze() -> Bool {
        let s = settings.withLock { $0 }
        guard s.anyEnabled else { return false }
        let now = Date()
        guard now.timeIntervalSince(lastAnalysis) >= minInterval else { return false }
        // Drop the frame if the previous one is still rendering.
        let acquired = busy.withLock { (isBusy: inout Bool) -> Bool in
            if isBusy { return false }
            isBusy = true
            return true
        }
        if acquired { lastAnalysis = now }
        return acquired
    }

    private func process(_ image: CIImage) {
        defer { busy.withLock { $0 = false } }
        let s = settings.withLock { $0 }
        if s.peaking || s.zebra, let output = makeOverlay(for: image, settings: s) {
            onOverlay(context.createCGImage(output, from: output.extent))
        }
        if s.histogram { onHistogram(histogram(for: image)) }
    }

    /// Luminance histogram via CIAreaHistogram on a small, display-referred luma image.
    /// Reads back 64 RGBA float pixels (one per bin) and normalizes to the tallest bin.
    func histogram(for image: CIImage) -> [Float] {
        let scale = 160 / max(1, image.extent.width)
        let small = image
            .transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let display = Self.luma(small).applyingFilter("CILinearToSRGBToneCurve")
        let bins = Self.histogramBins
        let histogramImage = display.applyingFilter("CIAreaHistogram", parameters: [
            kCIInputExtentKey: CIVector(cgRect: small.extent.integral),
            "inputCount": bins,
            "inputScale": 1,
        ])
        var pixels = [Float](repeating: 0, count: bins * 4)
        pixels.withUnsafeMutableBytes { buffer in
            context.render(histogramImage, toBitmap: buffer.baseAddress!, rowBytes: bins * 4 * MemoryLayout<Float>.size,
                           bounds: CGRect(x: 0, y: 0, width: bins, height: 1), format: .RGBAf, colorSpace: nil)
        }
        let values = stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }   // R channel = luma count
        let peak = max(values.max() ?? 0, .leastNonzeroMagnitude)
        return values.map { $0 / peak }
    }

    // MARK: Filter graph

    func makeOverlay(for image: CIImage, settings s: Settings) -> CIImage? {
        let scale = targetWidth / max(1, image.extent.width)
        let small = image
            .transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = small.extent.integral
        let luma = Self.luma(small)

        var layers: [CIImage] = []
        if s.zebra { layers.append(Self.zebraLayer(luma: luma, threshold: s.zebraThreshold, extent: extent)) }
        if s.peaking { layers.append(Self.peakingLayer(luma: luma, sensitivity: s.peakingSensitivity, extent: extent)) }
        guard var result = layers.first else { return nil }
        for layer in layers.dropFirst() { result = layer.composited(over: result) }
        return result.cropped(to: extent)
    }

    /// Rec. 709 luma in all three channels, alpha 1.
    static func luma(_ image: CIImage) -> CIImage {
        let w = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": w, "inputGVector": w, "inputBVector": w,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    /// Sobel edge magnitude → red highlight where focus is sharp.
    /// CIConvolutionRGB3X3 convolves RGB only and keeps alpha = 1, so the squared
    /// gradients can be combined with ordinary compositing filters.
    static func peakingLayer(luma: CIImage, sensitivity: Double, extent: CGRect) -> CIImage {
        let clamped = luma.clampedToExtent()
        let kx = CIVector(values: [-1, 0, 1, -2, 0, 2, -1, 0, 1], count: 9)
        let ky = CIVector(values: [-1, -2, -1, 0, 0, 0, 1, 2, 1], count: 9)
        let gx = clamped.applyingFilter("CIConvolutionRGB3X3", parameters: ["inputWeights": kx, "inputBias": 0])
        let gy = clamped.applyingFilter("CIConvolutionRGB3X3", parameters: ["inputWeights": ky, "inputBias": 0])
        let gx2 = gx.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: gx])
        let gy2 = gy.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: gy])
        let magnitude2 = gx2.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: gy2])
            .cropped(to: extent)
        let mask = magnitude2.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": sensitivity])
        // White/black mask → premultiplied red with alpha = mask.
        return mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 1, y: 0, z: 0, w: 0),
        ])
    }

    /// Diagonal stripes wherever display-referred luma ≥ threshold (0.70…1.0 ≈ 70–100 IRE).
    static func zebraLayer(luma: CIImage, threshold: Double, extent: CGRect) -> CIImage {
        // Core Image works in linear light; compare in sRGB-gamma space so the threshold
        // reads like IRE on a monitor.
        let display = luma.applyingFilter("CILinearToSRGBToneCurve")
        let mask = display.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": threshold])
        let stripes = CIFilter(name: "CIStripesGenerator", parameters: [
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0.85),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
            "inputWidth": 4, "inputSharpness": 1,
        ])!.outputImage!
            .transformed(by: CGAffineTransform(rotationAngle: .pi / 4))
            .cropped(to: extent)
        return stripes.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask,
        ])
    }
}

// MARK: - Simulator frame source

/// Synthetic "camera" for the Simulator: a gradient set with a bright face (drives
/// zebras), a high-contrast checker chart (drives peaking) and a soft background, so the
/// real analyzer runs on realistic content. Lens zoom is simulated by scaling.
final class MockFrameSource: @unchecked Sendable {
    private let queue = DispatchQueue(label: "duodirector.mock.frames", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let size = CGSize(width: 540, height: 960)   // portrait, like a held phone
    private let lensZoom = OSAllocatedUnfairLock(initialState: CGFloat(1))
    private let start = Date()

    var onFrame: (@Sendable (CGImage) -> Void)?
    /// Phase 4: synthetic Host (inner camera) frames for dual-cam previews, 15fps.
    var onInnerFrame: (@Sendable (CGImage) -> Void)?
    private var tick = 0
    weak var analyzer: FrameAnalyzer?

    func setLens(_ lens: LensOption) {
        let zoom: CGFloat = switch lens { case .ultraWide13: 0.55; case .main26: 1; case .crop52: 2 }
        lensZoom.withLock { $0 = zoom }
    }

    func start(context: CIContext) {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let t = Date().timeIntervalSince(start)
            let image = makeScene(t: t)
            if let cg = context.createCGImage(image, from: image.extent) { onFrame?(cg) }
            analyzer?.analyze(image)
            tick += 1
            if tick % 2 == 0, let onInnerFrame {
                let host = makeHostScene(t: t)
                if let cg = context.createCGImage(host, from: host.extent) { onInnerFrame(cg) }
            }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Host (inner camera) look: warmer key light, closer framing, no test chart.
    private func makeHostScene(t: TimeInterval) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        let background = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0, y: size.height),
            "inputColor0": CIColor(red: 0.22, green: 0.12, blue: 0.08),
            "inputColor1": CIColor(red: 0.45, green: 0.30, blue: 0.20),
        ])!.outputImage!
        let nod = CGFloat(sin(t * 1.7)) * 10
        let face = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: size.width / 2, y: size.height * 0.55 + nod),
            "inputRadius0": 70, "inputRadius1": 150,
            "inputColor0": CIColor(red: 0.95, green: 0.78, blue: 0.65, alpha: 1),
            "inputColor1": CIColor(red: 0.6, green: 0.4, blue: 0.3, alpha: 0),
        ])!.outputImage!
        return face.composited(over: background).cropped(to: rect)
    }

    private func makeScene(t: TimeInterval) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        let zoom = lensZoom.withLock { $0 }
        let sway = CGFloat(sin(t * 0.8)) * 24

        let background = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: size.width, y: size.height),
            "inputColor0": CIColor(red: 0.08, green: 0.12, blue: 0.22),
            "inputColor1": CIColor(red: 0.30, green: 0.36, blue: 0.48),
        ])!.outputImage!

        let center = CIVector(x: size.width / 2 + sway, y: size.height * 0.58)
        let face = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": center, "inputRadius0": 40 * zoom, "inputRadius1": 85 * zoom,
            "inputColor0": CIColor(red: 1, green: 0.97, blue: 0.94, alpha: 1),   // hot highlight
            "inputColor1": CIColor(red: 0.8, green: 0.6, blue: 0.5, alpha: 0),
        ])!.outputImage!

        let chartSide = 120 * zoom
        let chart = CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputCenter": CIVector(x: 0, y: 0), "inputWidth": 10 * zoom, "inputSharpness": 1,
            "inputColor0": CIColor.white, "inputColor1": CIColor.black,
        ])!.outputImage!
            .cropped(to: CGRect(x: 0, y: 0, width: chartSide, height: chartSide))
            .transformed(by: CGAffineTransform(translationX: size.width * 0.5 - chartSide / 2 + sway,
                                               y: size.height * 0.25))

        return chart.composited(over: face.composited(over: background)).cropped(to: rect)
    }
}

// MARK: - SwiftUI overlay

/// Draws the analyzer's overlay. Place it INSIDE the same container as the preview
/// (PreviewSurface does), so it gets the same aspect-fill crop and the same mirroring.
struct FocusPeakingMetalOverlay: View {
    let store: AnalysisOverlayStore

    var body: some View {
        if let overlay = store.overlay {
            Image(decorative: overlay, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .allowsHitTesting(false)
                .transition(.opacity)
                .accessibilityHidden(true)
        }
    }
}
