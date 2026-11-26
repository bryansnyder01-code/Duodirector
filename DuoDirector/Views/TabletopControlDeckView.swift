import SwiftUI

/// Lower half of the inner display in 90° tabletop L-mode (Phase 3).
///
/// InnerDirectorView places this view strictly BELOW the active `.division`
/// ReservedRegion (the horizontal crease), so it's lying flat on the desk and no control
/// can cross the fold. It's split into three physical-feeling pads:
///
///   ┌────────────── crease (.division, ~40pt, kept empty) ───────────────┐
///   │  LEFT PAD            │  CENTER PAD              │  RIGHT PAD        │
///   │  ● Record / Stop     │  ◎ scroll-speed wheel     │  ▮ audio gain     │
///   │  ⚑ Mark Good Take    │  ▶︎/❚❚ play-pause + reset  │  ☑ shot checklist │
///   └────────────────────────────────────────────────────────────────────┘
///
/// The pads are sized from the deck's own width, so it adapts if an `.occlusion`
/// inset or Split View narrows the deck. Below ~560pt the right pad drops its checklist
/// to keep touch targets at 44pt or more.
///
/// Phase 4, Dual-Cam Podcast: the upper half shows Host (inner) and Guest (rear) side by
/// side, and the left pad becomes the producer's pad: Record, Drop Marker (long-press
/// for a star rating) and a five-star Rate Take row that writes the take's rating into
/// its JSON/FCPXML sidecar.
struct TabletopControlDeckView: View {
    @Bindable var state: StudioSessionState
    let engine: CameraEngine

    var body: some View {
        GeometryReader { proxy in
            let narrow = proxy.size.width < 560
            // Under ~500pt (inner display in portrait) three pads can't fit their 44pt
            // targets, so the audio pad goes (the levels are on the viewfinder too).
            let compact = proxy.size.width < 500
            HStack(spacing: compact ? 8 : 12) {
                leftPad(narrow: narrow)
                    .frame(width: proxy.size.width * (compact ? 0.48 : narrow ? 0.34 : 0.28))
                centerPad
                    .frame(maxWidth: .infinity)
                if !compact {
                    rightPad(showsChecklist: !narrow)
                        .frame(width: proxy.size.width * (narrow ? 0.26 : 0.32))
                }
            }
            .padding(compact ? 8 : 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            LinearGradient(colors: [Color(white: 0.10), Color(white: 0.05)], startPoint: .top, endPoint: .bottom)
        )
        .accessibilityIdentifier("tabletopDeck")
    }

    // MARK: Left pad: record + good-take flag (solo) / marker + rating (dual)

    @ViewBuilder
    private func leftPad(narrow: Bool) -> some View {
        if state.isDualCam {
            DeckPad(title: "ROLL · PODCAST") {
                VStack(spacing: 10) {
                    // No timecode here: the Host tile right above already shows it, and
                    // the space keeps the rating stars on screen.
                    RecordButton(state: state, engine: engine, diameter: 80)
                    DropMarkerButton(state: state, engine: engine)
                    VStack(spacing: 2) {
                        Text(state.isRecording ? "RATE THIS TAKE" : "RATE LAST TAKE")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        RateTakeStars(state: state, engine: engine, starSize: narrow ? 26 : 30)
                    }
                }
            }
        } else {
            soloLeftPad
        }
    }

    private var soloLeftPad: some View {
        DeckPad(title: "ROLL") {
            VStack(spacing: 14) {
                RecordButton(state: state, engine: engine, diameter: 96)
                RecordingTimecode(state: state)
                Button {
                    engine.markTake(goodTake: true)
                } label: {
                    Label("Good Take", systemImage: "flag.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
                .foregroundStyle(.black)
                .disabled(!state.isRecording)
                .sensoryFeedback(.success, trigger: state.chapterMarkers.count)
                CountdownPicker(state: state).font(.caption)
            }
        }
    }

    // MARK: Center pad: teleprompter wheel + transport

    private var centerPad: some View {
        DeckPad(title: "PROMPTER") {
            VStack(spacing: 10) {
                SpeedWheel(speed: Binding(get: { state.prompterScrollSpeed },
                                          set: { state.setPrompterScrollSpeed($0) }))
                    .frame(maxWidth: 190, maxHeight: 190)
                HStack(spacing: 14) {
                    Button { state.resetPrompter() } label: {
                        Image(systemName: "backward.end.fill").frame(width: 48, height: 48)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Reset teleprompter")
                    Button { state.togglePrompter() } label: {
                        Image(systemName: state.isPrompterPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .frame(width: 72, height: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.yellow)               // one accent: yellow for actions, red for record
                    .foregroundStyle(.black)
                    .accessibilityLabel(state.isPrompterPlaying ? "Pause teleprompter" : "Play teleprompter")
                }
            }
        }
    }

    // MARK: Right pad: gain + shot quick-checks

    private func rightPad(showsChecklist: Bool) -> some View {
        DeckPad(title: "AUDIO · SHOTS") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom, spacing: 10) {
                    StereoAudioMeter(state: state, thickness: 10).frame(height: 110)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Gain \(Int(state.audioGain * 100))%").font(.caption.monospacedDigit())
                        Slider(value: $state.audioGain, in: 0...1)
                            .accessibilityLabel("Audio gain")
                    }
                }
                if showsChecklist {
                    Divider()
                    // Active shot first, then the next unfinished ones.
                    ForEach(quickShots) { item in
                        ShotChecklistRow(item: item, isActive: item.id == state.activeShot?.id,
                                         onToggle: { state.toggleCompleted(item.id) },
                                         onSelect: { state.activateShot(item.id) })
                    }
                    Button("Shot list & sketches", systemImage: "pencil.and.list.clipboard") {
                        state.isShotListDrawerOpen = true
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var quickShots: [ShotListItem] {
        guard let index = state.activeShotIndex else { return Array(state.shotList.prefix(3)) }
        return Array(state.shotList[index...].prefix(3))
    }
}

/// A rounded "physical" pad.
private struct DeckPad<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption2.bold()).foregroundStyle(.secondary)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(12)
        .background(Color(white: 0.13), in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.06)))
        .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
    }
}

/// Jog-wheel style speed control: drag around the ring to change speed
/// (clockwise = faster). Ticks give haptic feedback every 5 pt/s. Also adjustable with
/// VoiceOver increment/decrement.
struct SpeedWheel: View {
    @Binding var speed: Double
    var range: ClosedRange<Double> = 5...200
    @State private var lastAngle: Double?

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let fraction = (speed - range.lowerBound) / (range.upperBound - range.lowerBound)

            ZStack {
                Circle().fill(Color(white: 0.18))
                Circle().trim(from: 0, to: fraction)
                    .stroke(.yellow, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(6)
                ForEach(0..<24) { i in
                    Capsule().fill(.white.opacity(0.25))
                        .frame(width: 2, height: 8)
                        .offset(y: -side / 2 + 18)
                        .rotationEffect(.degrees(Double(i) * 15))
                }
                VStack(spacing: 0) {
                    Text("\(Int(speed))").font(.system(size: side * 0.2, weight: .bold, design: .rounded))
                    Text("pt/s").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: side, height: side)
            .position(center)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let angle = atan2(value.location.y - center.y, value.location.x - center.x)
                        if let last = lastAngle {
                            var delta = angle - last
                            if delta > .pi { delta -= 2 * .pi }
                            if delta < -.pi { delta += 2 * .pi }
                            // One full turn ≈ 120 pt/s.
                            speed = min(range.upperBound, max(range.lowerBound, speed + delta / (2 * .pi) * 120))
                        }
                        lastAngle = angle
                    }
                    .onEnded { _ in lastAngle = nil }
            )
            .sensoryFeedback(.selection, trigger: Int(speed / 5))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Teleprompter speed")
        .accessibilityValue("\(Int(speed)) points per second")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: speed = min(range.upperBound, speed + 5)
            case .decrement: speed = max(range.lowerBound, speed - 5)
            @unknown default: break
            }
        }
    }
}

#Preview("Tabletop deck") {
    let state = StudioSessionState()
    state.sourceMode = .mock
    return TabletopControlDeckView(state: state, engine: CameraEngine(state: state))
        .frame(width: 760, height: 360)
        .preferredColorScheme(.dark)
}
