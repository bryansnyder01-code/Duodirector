import CoreGraphics
import Foundation

// =====================================================================================
//  ReframePlanner (Phase 11): pure maths for the 9:16 vertical export. Unit-tested.
//
//  SocialExporter samples the take about once a second, finds the main face (Vision)
//  and hands the horizontal centres here. We fill gaps, smooth them so the crop glides
//  instead of jumping, clamp so the crop never leaves the frame, and turn each centre
//  into the transform that puts that 9:16 window onto a 1080×1920 canvas.
// =====================================================================================

enum ReframePlanner {
    static let verticalSize = CGSize(width: 1080, height: 1920)

    /// Gaps (nil = no face in that sample) take the nearest known centre, or 0.5 when the
    /// whole take has none. Then a centred moving average (window 5) and a dead zone, so a
    /// talking head that sways a little doesn't make the crop drift.
    static func smoothedCenters(_ raw: [Double?], window: Int = 5, deadZone: Double = 0.03) -> [Double] {
        guard !raw.isEmpty else { return [] }
        let known = raw.enumerated().compactMap { i, v in v.map { (i, $0) } }
        guard !known.isEmpty else { return Array(repeating: 0.5, count: raw.count) }
        let filled: [Double] = raw.indices.map { i in
            if let v = raw[i] { return v }
            return known.min { abs($0.0 - i) < abs($1.0 - i) }!.1
        }
        let half = window / 2
        let averaged: [Double] = filled.indices.map { i in
            let lo = max(0, i - half), hi = min(filled.count - 1, i + half)
            return filled[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }
        var out: [Double] = []
        for v in averaged {
            if let last = out.last, abs(v - last) < deadZone { out.append(last) } else { out.append(v) }
        }
        return out
    }

    /// Width of the 9:16 window as a fraction of the source width (1 for sources that are
    /// already as narrow as 9:16).
    static func cropWidthFraction(source: CGSize) -> Double {
        guard source.width > 0, source.height > 0 else { return 1 }
        return min(1, Double(source.height * 9 / 16 / source.width))
    }

    /// Keeps the window inside the frame.
    static func clampedCenter(_ x: Double, source: CGSize) -> Double {
        let half = cropWidthFraction(source: source) / 2
        return min(max(x, half), 1 - half)
    }

    /// Transform from the ORIENTED source (preferredTransform already applied, origin at
    /// 0,0) onto the vertical canvas, with the window centred on `centerX` (0…1).
    static func transform(orientedSize source: CGSize, centerX: Double,
                          canvas: CGSize = verticalSize) -> CGAffineTransform {
        guard source.width > 0, source.height > 0 else { return .identity }
        let sourceAspect = source.width / source.height
        let canvasAspect = canvas.width / canvas.height
        if sourceAspect > canvasAspect {
            // Wider than 9:16: fill the height, pan horizontally.
            let scale = canvas.height / source.height
            let x = clampedCenter(centerX, source: source) * source.width * scale
            return CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: canvas.width / 2 - x, y: 0))
        } else {
            // Already vertical or narrower: fill the width, centre vertically.
            let scale = canvas.width / source.width
            return CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: 0, y: (canvas.height - source.height * scale) / 2))
        }
    }

    /// Sample times: about one per second, at most `maxSamples`, always including 0.
    static func sampleTimes(duration: TimeInterval, maxSamples: Int = 120) -> [TimeInterval] {
        guard duration > 0 else { return [0] }
        let count = max(2, min(maxSamples, Int(duration.rounded(.up)) + 1))
        return (0..<count).map { duration * Double($0) / Double(count - 1) }
    }
}

/// Phase 11: when a social export may run. Lighter than CompositeRenderPolicy (no need to
/// be plugged in: a 1080p vertical encode is short), but never mid-take or when hot.
enum SocialExportPolicy {
    static func verdict(isRecording: Bool, isRendering: Bool, thermal: ProcessInfo.ThermalState,
                        isCharging: Bool, batteryLevel: Float?) -> CompositeRenderPolicy.Verdict {
        if isRecording { return .blocked(String(localized: "Finish the take first.")) }
        if isRendering { return .blocked(String(localized: "Wait for the current render to finish.")) }
        if thermal.rawValue > ProcessInfo.ThermalState.fair.rawValue {
            return .blocked(String(localized: "iPhone is too warm. Let it cool down first."))
        }
        if let batteryLevel, batteryLevel < 0.2, !isCharging {
            return .blocked(String(localized: "Battery is under 20%. Plug in to export."))
        }
        return .allowed
    }
}
