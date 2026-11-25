import SwiftUI

// =====================================================================================
//  Phase 4: Dual-Cam Podcast previews
//
//  Two feeds from one AVCaptureMultiCamSession, each with its OWN
//  AVCaptureVideoPreviewLayer (CaptureSessionController.makePreviewLayer(for:)):
//    • rear  = Guest: 48MP Fusion Main, the primary picture (and the cover monitor)
//    • inner = Host: under-display camera, shown as a movable PiP or a split pane
//
//  WHY THE PIP READS ITS OWN RESERVED REGIONS
//  While the inner camera is capturing, iOS 27.1 reports its pixels as an ACTIVE
//  `.occlusion` ReservedRegion. That's exactly where a naive "bottom-right PiP" could end
//  up on some orientations. Each preview below wraps itself in a GeometryReader and asks
//  `reservedRegions(kind:)` for the regions in ITS OWN coordinate space, every layout
//  pass, then:
//    – PiP: picks the preferred corner (state.pipCorner) if it's clear, else the next
//      clear corner; drags snap to the nearest clear corner.
//    – Split: insets the Host pane so its picture and label never sit under an occlusion
//      or the crease.
// =====================================================================================

/// Rear (Guest) full-frame + movable Host PiP. Used for `.pictureInPicture` and
/// `.separateSyncedTracks` (the edit gets separate lanes, but the operator still needs to
/// see the host).
struct DualCamPiPPreview: View {
    @Bindable var state: StudioSessionState
    let engine: CameraEngine
    var tileSize = CGSize(width: 116, height: 154)

    var body: some View {
        ZStack {
            PreviewSurface(state: state, engine: engine, role: .rear)
            MovableHostPiP(state: state, engine: engine, tileSize: tileSize)
        }
    }
}

/// The draggable Host tile. Lays itself out in its own GeometryReader so it can be placed
/// over any container (inner viewfinder, cover monitor) and still respect that container's
/// reserved regions.
struct MovableHostPiP: View {
    @Bindable var state: StudioSessionState
    let engine: CameraEngine
    var tileSize: CGSize
    var margin: CGFloat = 12

    @GestureState private var dragOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let regions = DuoRegions(proxy)          // fresh snapshot, never cached
            let corner = Self.clearCorner(preferred: state.pipCorner, tile: tileSize,
                                          container: proxy.size, regions: regions, margin: margin)
            let rect = Self.rect(for: corner, tile: tileSize, container: proxy.size,
                                 insets: regions.occlusionInsets, margin: margin)

            HostTile(state: state, engine: engine, label: "HOST")
                .frame(width: tileSize.width, height: tileSize.height)
                .scaleEffect(dragOffset == .zero ? 1 : 1.05)
                .position(x: rect.midX + dragOffset.width, y: rect.midY + dragOffset.height)
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .updating($dragOffset) { value, offset, _ in offset = value.translation }
                        .onEnded { value in
                            let drop = CGPoint(x: rect.midX + value.translation.width,
                                               y: rect.midY + value.translation.height)
                            state.pipCorner = Self.nearestClearCorner(to: drop, tile: tileSize, container: proxy.size,
                                                                      regions: regions, margin: margin)
                        }
                )
                .animation(.snappy, value: corner)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Host camera preview")
                .accessibilityHint("Drag to move to another corner")
                .accessibilityAction(named: "Move to next corner") {
                    let all = PiPCorner.allCases
                    state.pipCorner = all[((all.firstIndex(of: corner) ?? 0) + 1) % all.count]
                }
        }
    }

    // MARK: Placement (pure functions; easy to unit-test)

    static func rect(for corner: PiPCorner, tile: CGSize, container: CGSize,
                     insets: EdgeInsets, margin: CGFloat) -> CGRect {
        let x: CGFloat = switch corner {
        case .topLeading, .bottomLeading: insets.leading + margin
        case .topTrailing, .bottomTrailing: container.width - insets.trailing - margin - tile.width
        }
        let y: CGFloat = switch corner {
        case .topLeading, .topTrailing: insets.top + margin + 28     // leave the badge row free
        case .bottomLeading, .bottomTrailing: container.height - insets.bottom - margin - tile.height - 34  // above the meters/timecode
        }
        return CGRect(origin: CGPoint(x: max(0, x), y: max(0, y)), size: tile)
    }

    /// Preferred corner if clear, else the first clear one (trailing-bottom first), else
    /// the preferred one anyway (insets already pushed it off the occlusion's edge).
    static func clearCorner(preferred: PiPCorner, tile: CGSize, container: CGSize,
                            regions: DuoRegions, margin: CGFloat) -> PiPCorner {
        let order = [preferred] + [.bottomTrailing, .bottomLeading, .topTrailing, .topLeading].filter { $0 != preferred }
        return order.first {
            !regions.collides(rect(for: $0, tile: tile, container: container, insets: regions.occlusionInsets, margin: margin))
        } ?? preferred
    }

    static func nearestClearCorner(to point: CGPoint, tile: CGSize, container: CGSize,
                                   regions: DuoRegions, margin: CGFloat) -> PiPCorner {
        let candidates = PiPCorner.allCases.map { corner in
            (corner, rect(for: corner, tile: tile, container: container, insets: regions.occlusionInsets, margin: margin))
        }
        let clear = candidates.filter { !regions.collides($0.1) }
        let pool = clear.isEmpty ? candidates : clear
        return pool.min { hypot($0.1.midX - point.x, $0.1.midY - point.y) < hypot($1.1.midX - point.x, $1.1.midY - point.y) }!.0
    }
}

/// Side-by-side Guest | Host, used for `.splitScreenComposite` (what the FCPXML builds).
struct DualCamSplitPreview: View {
    let state: StudioSessionState
    let engine: CameraEngine

    var body: some View {
        GeometryReader { proxy in
            let regions = DuoRegions(proxy)
            let insets = regions.occlusionInsets
            HStack(spacing: 2) {
                GuestTile(state: state, engine: engine)
                HostTile(state: state, engine: engine, label: "HOST · inner")
                    // The inner camera's occlusion sits on this side of the screen when the
                    // device is held for a podcast. Inset the pane so nothing is hidden.
                    .padding(.top, insets.top)
                    .padding(.trailing, insets.trailing)
                    .padding(.bottom, insets.bottom)
            }
            .padding(.leading, insets.leading)
        }
    }
}

/// Tabletop + Dual: Host (inner) and Guest (rear) previews side by side ABOVE the fold.
/// The caller already constrained us to `fold.minY`, so this just splits the width.
struct HostGuestPreviewPair: View {
    let state: StudioSessionState
    let engine: CameraEngine

    var body: some View {
        GeometryReader { proxy in
            let insets = DuoRegions(proxy).occlusionInsets
            HStack(spacing: 8) {
                HostTile(state: state, engine: engine, label: "HOST · inner",
                         talkLevel: state.leftChannelDB)
                GuestTile(state: state, engine: engine, talkLevel: state.rightChannelDB)
            }
            .padding(.top, insets.top + 6)
            .padding(.leading, insets.leading + 8)
            .padding(.trailing, insets.trailing + 8)
            .padding(.bottom, 6)
        }
    }
}

// MARK: - Tiles

/// Inner camera tile. Mirrored, like a selfie preview, so the host's own movements feel
/// natural. The recorded file is NOT mirrored. No analysis overlay: MultiCam has no video
/// data output, and the inner feed isn't the hero shot.
struct HostTile: View {
    let state: StudioSessionState
    let engine: CameraEngine
    var label: String
    /// Optional "talk light": rim glows when this side's mic channel is hot. On device the
    /// L/R split is only a rough proxy for who's talking; in Demo Mode the podcast mock
    /// alternates L (host) and R (guest).
    var talkLevel: Float? = nil

    var body: some View {
        PreviewSurface(state: state, engine: engine, role: .inner, mirrored: true, showsAnalysisOverlay: false)
            .clipShape(.rect(cornerRadius: 12))
            .overlay(TileChrome(label: label, color: .cyan, talkLevel: talkLevel))
    }
}

/// Rear camera tile (keeps peaking/zebras when the analyzer is available).
struct GuestTile: View {
    let state: StudioSessionState
    let engine: CameraEngine
    var talkLevel: Float? = nil

    var body: some View {
        PreviewSurface(state: state, engine: engine, role: .rear)
            .clipShape(.rect(cornerRadius: 12))
            .overlay(TileChrome(label: "GUEST · rear", color: .yellow, talkLevel: talkLevel))
    }
}

private struct TileChrome: View {
    var label: String
    var color: Color
    var talkLevel: Float?

    var body: some View {
        let talking = (talkLevel ?? -160) > -30
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(talking ? color : .white.opacity(0.5), lineWidth: talking ? 3 : 1)
            .overlay(alignment: .topLeading) {
                Text(label)
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(color, in: .capsule)
                    .foregroundStyle(.black)
                    .padding(6)
            }
            .animation(.easeOut(duration: 0.15), value: talking)
            .allowsHitTesting(false)
    }
}
