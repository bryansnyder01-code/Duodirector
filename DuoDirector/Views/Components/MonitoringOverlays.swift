import SwiftUI

// MARK: - Safe-zone framing guides

/// 16:9 (YouTube) and 9:16 (Reels / TikTok) safe-zone guides, centred in the frame.
/// The 9:16 guide also shades the bottom ~20% where Reels/TikTok put captions and UI.
struct FramingGuidesOverlay: View {
    let show16x9: Bool
    let show9x16: Bool
    var showThirds = false
    var opacity: Double = 1    // Phase 3 "Grid opacity" (overflow menu)

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                if showThirds {
                    Path { p in
                        for i in 1...2 {
                            let x = size.width * CGFloat(i) / 3, y = size.height * CGFloat(i) / 3
                            p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                        }
                    }
                    .stroke(.white.opacity(0.6), lineWidth: 0.75)
                }
                if show16x9 {
                    let r = Self.fitted(aspect: 16.0 / 9.0, in: size)
                    Path(r).stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [8, 5]))
                    tag("16:9 YouTube", .white, in: r, at: .topLeading)
                }
                if show9x16 {
                    let r = Self.fitted(aspect: 9.0 / 16.0, in: size)
                    Path(r).stroke(.yellow.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [8, 5]))
                    Path(CGRect(x: r.minX, y: r.maxY - r.height * 0.2, width: r.width, height: r.height * 0.2))
                        .fill(.yellow.opacity(0.08))
                    // Bottom corner: the top of a portrait frame is under the teleprompter.
                    tag("9:16 Reels/TikTok", .yellow, in: r, at: .bottomTrailing)
                }
            }
            .opacity(opacity)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static func fitted(aspect: CGFloat, in size: CGSize) -> CGRect {
        var w = size.width, h = size.width / aspect
        if h > size.height { h = size.height; w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// A label tucked inside a corner of its guide, measured so it never hangs off the
    /// edge of the screen (it used to be centred on a fixed point and got clipped).
    private func tag(_ text: LocalizedStringKey, _ color: Color, in rect: CGRect, at corner: Alignment) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.black.opacity(0.6), in: .capsule)
            .padding(6)
            .frame(width: max(0, rect.width), height: max(0, rect.height), alignment: corner)
            .position(x: rect.midX, y: rect.midY)
    }
}

// MARK: - Stereo audio meter

/// High-visibility stereo peak bars (-60…0 dBFS) with RMS ticks and a peak-hold CLIP lamp.
struct StereoAudioMeter: View {
    let state: StudioSessionState
    var axis: Axis = .vertical
    var thickness: CGFloat = 10
    var showsLabels = true

    var body: some View {
        let stack = axis == .vertical
            ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 6))
        stack {
            clipLamp
            let bars = axis == .vertical
                ? AnyLayout(HStackLayout(spacing: 3)) : AnyLayout(VStackLayout(spacing: 3))
            bars {
                MeterBar(peakDB: state.leftChannelDB, rmsDB: state.leftChannelRMS, axis: axis, thickness: thickness)
                MeterBar(peakDB: state.rightChannelDB, rmsDB: state.rightChannelRMS, axis: axis, thickness: thickness)
            }
            if showsLabels {
                Text("L R").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio level")
        .accessibilityValue("Left \(Int(state.leftChannelDB)) dB, right \(Int(state.rightChannelDB)) dB\(state.isAudioClipping ? ", clipping" : "")")
    }

    private var clipLamp: some View {
        Text("CLIP")
            .font(.system(size: 9, weight: .heavy, design: .monospaced))
            .padding(.horizontal, 4).padding(.vertical, 2)
            .foregroundStyle(state.isAudioClipping ? .white : .white.opacity(0.35))
            .background(state.isAudioClipping ? Color.red : Color.white.opacity(0.1), in: .rect(cornerRadius: 3))
            .animation(.easeOut(duration: 0.1), value: state.isAudioClipping)
    }
}

private struct MeterBar: View {
    let peakDB: Float
    let rmsDB: Float
    let axis: Axis
    let thickness: CGFloat

    private func fraction(_ db: Float) -> CGFloat { CGFloat(max(0, min(1, (db + 60) / 60))) }

    var body: some View {
        GeometryReader { proxy in
            let length = axis == .vertical ? proxy.size.height : proxy.size.width
            ZStack(alignment: axis == .vertical ? .bottom : .leading) {
                Capsule().fill(.white.opacity(0.12))
                // Green → yellow at -12 → red at -3 dBFS.
                LinearGradient(stops: [.init(color: .green, location: 0), .init(color: .green, location: 0.8),
                                       .init(color: .yellow, location: 0.8), .init(color: .yellow, location: 0.95),
                                       .init(color: .red, location: 0.95), .init(color: .red, location: 1)],
                               startPoint: axis == .vertical ? .bottom : .leading,
                               endPoint: axis == .vertical ? .top : .trailing)
                    .mask(alignment: axis == .vertical ? .bottom : .leading) {
                        Rectangle().frame(width: axis == .vertical ? nil : length * fraction(peakDB),
                                          height: axis == .vertical ? length * fraction(peakDB) : nil)
                    }
                    .clipShape(.capsule)
                // RMS tick
                Rectangle().fill(.white)
                    .frame(width: axis == .vertical ? nil : 2, height: axis == .vertical ? 2 : nil)
                    .offset(x: axis == .vertical ? 0 : length * fraction(rmsDB),
                            y: axis == .vertical ? -length * fraction(rmsDB) : 0)
            }
        }
        .frame(width: axis == .vertical ? thickness : nil, height: axis == .vertical ? nil : thickness)
    }
}

// MARK: - Teleprompter

/// Teleprompter text whose position comes from `state.prompterOffset(at:)` inside a
/// `TimelineView(.animation)`: smooth, display-synced scrolling with no state writes per
/// frame, and the inner and outer copies always show the same line.
struct TeleprompterText: View {
    let state: StudioSessionState
    var fontScale: Double = 1

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: nil, paused: !state.isPrompterPlaying)) { context in
                Text(state.scriptText)
                    .font(.system(size: state.prompterFontSize * fontScale, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineSpacing(state.prompterFontSize * 0.25)
                    .frame(width: max(0, proxy.size.width - 24))
                    // Full height, not the box's height: otherwise the script is cut to
                    // a few lines and scrolls away, leaving the prompter blank.
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .offset(y: proxy.size.height * 0.2 - state.prompterOffset(at: context.date) * fontScale)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
            // Beam-splitter rigs need the text flipped.
            .scaleEffect(x: state.prompterMirrored ? -1 : 1, y: 1)
        }
        .clipped()
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.15),
                                     .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .accessibilityLabel("Teleprompter")
        .accessibilityValue(state.scriptText)
    }
}

/// Play / Pause / Reset pill.
struct PrompterTransportPill: View {
    let state: StudioSessionState

    var body: some View {
        HStack(spacing: 0) {
            Button { state.resetPrompter() } label: {
                Image(systemName: "backward.end.fill").frame(width: 40, height: 32)
            }
            .accessibilityLabel("Reset teleprompter")
            Divider().frame(height: 18).overlay(.white.opacity(0.3))
            Button { state.togglePrompter() } label: {
                Image(systemName: state.isPrompterPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 32)
            }
            .accessibilityLabel(state.isPrompterPlaying ? "Pause teleprompter" : "Play teleprompter")
        }
        .buttonStyle(.plain)
        .font(.callout.weight(.semibold))
        .foregroundStyle(.white)
        .background(.white.opacity(0.14), in: .capsule)
    }
}

// MARK: - Recording status

/// Running timecode from `state.recordingDuration`.
struct RecordingTimecode: View {
    let state: StudioSessionState

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(state.isRecording ? .red : .gray).frame(width: 8, height: 8)
                .opacity(state.isRecording ? 1 : 0.6)
            Text(CameraEngine.timecode(state.recordingDuration)).font(.callout.monospacedDigit().bold())
            Text("T\(state.takeNumber)").font(.caption.monospaced()).foregroundStyle(.secondary)
            if state.isDolbyVisionActive {
                Text("DV").font(.caption2.bold()).padding(.horizontal, 3)
                    .background(.white.opacity(0.2), in: .rect(cornerRadius: 3))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.black.opacity(0.6), in: .capsule)
    }
}

/// Big centred countdown digit.
struct CountdownOverlay: View {
    let remaining: Int?
    var body: some View {
        if let remaining {
            Text("\(remaining)")
                .font(.system(size: 140, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 12)
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy, value: remaining)
                .allowsHitTesting(false)
        }
    }
}

/// Small "PEAK" / "ZEBRA" badges so it's obvious an overlay is active.
struct OverlayBadges: View {
    let state: StudioSessionState
    var body: some View {
        HStack(spacing: 4) {
            if state.showFocusPeaking { badge("PEAK", .red) }
            if state.showZebraStripes { badge("ZEBRA \(Int(state.zebraThreshold * 100))", .white) }
        }
        .allowsHitTesting(false)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.monospaced().bold())
            .padding(.horizontal, 5).padding(.vertical, 2)
            .foregroundStyle(.black).background(color, in: .capsule)
    }
}

// MARK: - Luminance histogram (Phase 3)

/// 64-bin luma histogram from FrameAnalyzer (display-referred, 0 = black … 1 = white).
/// The right-most bins are tinted when zebras are on, to show what's over the threshold.
struct LumaHistogramView: View {
    let store: AnalysisOverlayStore
    var zebraThreshold: Double? = nil

    var body: some View {
        Canvas { ctx, size in
            let bins = store.histogram
            guard !bins.isEmpty else { return }
            let barWidth = size.width / CGFloat(bins.count)
            for (i, value) in bins.enumerated() {
                let h = CGFloat(value) * size.height
                let rect = CGRect(x: CGFloat(i) * barWidth, y: size.height - h, width: max(1, barWidth - 0.5), height: h)
                let over = zebraThreshold.map { Double(i) / Double(bins.count) >= $0 } ?? false
                ctx.fill(Path(rect), with: .color(over ? .orange : .white.opacity(0.85)))
            }
        }
        .frame(width: 150, height: 54)
        .padding(6)
        .background(.black.opacity(0.55), in: .rect(cornerRadius: 8))
        .overlay(alignment: .topLeading) {
            if store.histogram.isEmpty {
                Text("Histogram").font(.caption2).foregroundStyle(.secondary).padding(8)
            }
        }
        .allowsHitTesting(false)
        .accessibilityLabel("Luminance histogram")
    }
}
