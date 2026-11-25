import SwiftUI

// =====================================================================================
//  iOS 27.1 / iPhone Duo API surface: every new-in-27.x API the app uses goes through
//  this file, so if a signature differs from what's written here you fix it in ONE place.
//
//  Checked against developer.apple.com on 2026-11-24:
//
//  CONFIRMED (declaration seen on Apple's docs)
//   • CameraCaptureAccessory<Content>                    iOS 27.1
//       init(content:)  /  init(isEnabled: Binding<Bool>, content:)
//   • SceneAccessoryContent.onAvailabilityChange(perform:)  (Apple sample code)
//   • ArrangementView(primary:secondary:)                 iOS 27.1
//       .arrangementViewStyle(.split) / (.overlay) / (.split.axes(_:))
//       .splitArrangementLayoutRatio(_:)  (applied to a child view, not the ArrangementView)
//   • ReservedRegion  { id, kind, frame, margins, isActive }   iOS 27.1
//       Kind: .division (fold), .occlusion (camera, Dynamic Island, window controls)
//       QueryOptions: .includeInactive
//   • GeometryProxy.reservedRegions(kind:options:layoutDirectionBehavior:) -> [ReservedRegion]
//   • ToolbarOverflowMenu { ... }                         iOS 27.0
//   • ToolbarItemVisibilityPriority(higherThan:), .high, .low   iOS 27.0
//   • View.onHingeChange(isEnabled: Bool = true,
//         _ action: @escaping (DeviceHingeContext, DeviceHingeContext) -> Void)   iOS 27.1
//       DeviceHingeContext { var hinge: DeviceHinge? }
//       DeviceHinge { var angle: Angle; var status: DeviceHinge.Status }
//     Apple: "Don't use hinge updates for layout. To adapt your layout to the fold, use
//     ArrangementView or ReservedRegion instead." We follow that: hinge → behaviour,
//     regions → layout. (Checked 2026-11-24.)
//
//  NOT FULLY CONFIRMED (named in docs or third-party posts, declaration not seen)
//   • View.sceneAccessory(content:)  : used in Apple's sample, full signature not shown.
//   • ToolbarContent.visibilityPriority(_:)  : from a third-party iOS 27 article.
//   • DeviceHinge.Status cases: page couldn't be read. UIKit's UIHinge uses .closed /
//     .partiallyOpen / .fullyOpen; we avoid the enum and derive posture from `angle`.
//   • A "fold posture" enum (flat / book / tabletop): none exists. Apple DTS recommends
//     deriving posture from active .division regions, which is what DuoPosture does.
//   • A system "trailing vertical toolbar" placement: none found. RightRailToolbar is our
//     own vertical rail that collapses via ViewThatFits.
//
//  CI COMPAT MODE (`DUO_COMPAT_SDK`): GitHub's macOS runners don't have Xcode 27 / the
//  iOS 27 SDK yet. CI then builds with this flag and a 26.0 deployment target, and every
//  iOS 27 call below falls back to a plain-SwiftUI stand-in, so the other ~95 % of the app
//  is still compiled and unit-tested. Never ship a compat build.
// =====================================================================================

// MARK: - Outer cover display (CameraCaptureAccessory)

extension View {
    /// Registers `content` as the camera-capture accessory shown on iPhone Duo's 5.4" cover
    /// display while a capture session is running and the device is open.
    ///
    /// Behaviour per Apple (AVFoundation article "Registering a camera capture accessory on
    /// iPhone Duo"):
    ///  • The system decides when/where to present, and may withdraw it at any time.
    ///  • It only appears with the app in the foreground and a capture session running.
    ///  • Registration is scoped to this view; navigating away removes it.
    ///  • Content is an enhancement: essential controls must stay in the main capture UI.
    ///  • No Info.plist / scene-manifest configuration is needed.
    ///  • The Simulator has no camera, so the real accessory can't be exercised there; use
    ///    `OuterMonitorSimulatorPreview` instead.
    func duoCaptureAccessory<Content: View>(
        isEnabled: Binding<Bool>,
        onAvailabilityChange: @escaping (Bool) -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        // UNCONFIRMED SIGNATURE: `sceneAccessory(content:)`. If it fails to compile, check
        // the modifier's declaration in Xcode's Quick Help; the CameraCaptureAccessory
        // pieces inside it are confirmed.
        #if DUO_COMPAT_SDK
        self
        #else
        self.sceneAccessory {
            CameraCaptureAccessory(isEnabled: isEnabled) {
                content()
            }
            .onAvailabilityChange { isAvailable in
                onAvailabilityChange(isAvailable)
            }
        }
        #endif
    }
}

// MARK: - Hinge (onHingeChange)

extension View {
    /// Reports the hinge angle in degrees (nil when the device has no hinge, or when
    /// `isEnabled` turns false). SwiftUI calls this with the initial context and again as
    /// the hinge moves, at a pace the system sets. Behaviour only, never layout.
    func duoOnHingeChange(isEnabled: Bool = true, perform: @escaping (Double?) -> Void) -> some View {
        #if DUO_COMPAT_SDK
        self
        #else
        onHingeChange(isEnabled: isEnabled) { _, newContext in
            perform(newContext.hinge?.angle.degrees)
        }
        #endif
    }
}

// MARK: - Fold & occlusion (ReservedRegion)

/// The device posture as far as layout cares, derived fresh from reserved regions on every
/// layout pass. Do NOT cache ReservedRegion values: frames change as the hinge moves, and
/// Apple's guidance is to query inside GeometryReader / onGeometryChange each time.
enum DuoPosture: Equatable {
    /// Fully open (or a device without a fold). No active `.division` region.
    case flat
    /// Partially folded like a book. The fold runs vertically.
    case book(fold: CGRect)
    /// Partially folded ~90° with the fold running horizontally (tabletop / "L" / laptop
    /// pose). Top half stands up as the monitor, bottom half lies flat for controls.
    case tabletop(fold: CGRect)

    var label: String {
        switch self {
        case .flat: "Flat"
        case .book: "Book"
        case .tabletop: "Tabletop"
        }
    }
}

/// Snapshot of the reserved regions for ONE layout pass. Build it inside a GeometryReader
/// and throw it away; never store it in state.
struct DuoRegions: Sendable {
    /// Phase 5: frames only (in the proxy's local space), not ReservedRegion values.
    /// ReservedRegion has no public initializer, so storing frames is what lets the
    /// posture / inset / collision maths be unit-tested with hand-made layouts.
    let divisionFrames: [CGRect]
    let occlusionFrames: [CGRect]
    let size: CGSize

    init(_ proxy: GeometryProxy) {
        // Default options: only *active* regions. `.division` is inactive when fully open,
        // which is exactly what we want (flat = no fold avoidance).
        #if DUO_COMPAT_SDK
        divisionFrames = []; occlusionFrames = []; size = proxy.size
        #else
        divisionFrames = proxy.reservedRegions(kind: .division).map(\.frame)
        // `.occlusion` covers the inner under-display camera (when active), the Dynamic
        // Island / status area, and any trailing system toolbar/window controls.
        occlusionFrames = proxy.reservedRegions(kind: .occlusion).map(\.frame)
        size = proxy.size
        #endif
    }

    /// Test / preview initializer.
    init(divisionFrames: [CGRect] = [], occlusionFrames: [CGRect] = [], size: CGSize) {
        self.divisionFrames = divisionFrames
        self.occlusionFrames = occlusionFrames
        self.size = size
    }

    var posture: DuoPosture {
        posture(override: nil)
    }

    /// `override` lets the Simulator fake a fold (ReservedRegion has no public initializer,
    /// so we can't fabricate regions; we fabricate the posture instead).
    /// Simulated crease width. iPhone Duo's crease band is ~40pt including Apple's margins.
    static let simulatedCrease: CGFloat = 40

    func posture(override: HingePosture?) -> DuoPosture {
        if let override {
            let crease = Self.simulatedCrease
            switch override {
            case .flat, .closed: return .flat   // closed is handled before layout (cover UI)
            case .bookHalfFolded:
                return .book(fold: CGRect(x: size.width / 2 - crease / 2, y: 0, width: crease, height: size.height))
            case .tabletopLShape:
                return .tabletop(fold: CGRect(x: 0, y: size.height / 2 - crease / 2, width: size.width, height: crease))
            }
        }
        guard let fold = divisionFrames.first else { return .flat }
        // Apple: "When you partially fold iPhone Duo like a book, the fold runs vertically."
        return fold.height > fold.width ? .book(fold: fold) : .tabletop(fold: fold)
    }

    /// Edge insets that keep interactive controls clear of every active occlusion.
    /// Each region is attributed to the nearest edge of the container and that edge is
    /// inset by the region's depth. `frame` already includes Apple's recommended margins.
    var occlusionInsets: EdgeInsets {
        var insets = EdgeInsets()
        for f in occlusionFrames {
            let distances: [(Edge, CGFloat)] = [
                (.top, f.minY), (.bottom, size.height - f.maxY),
                (.leading, f.minX), (.trailing, size.width - f.maxX),
            ]
            guard let nearest = distances.min(by: { $0.1 < $1.1 })?.0 else { continue }
            switch nearest {
            case .top: insets.top = max(insets.top, f.maxY)
            case .bottom: insets.bottom = max(insets.bottom, size.height - f.minY)
            case .leading: insets.leading = max(insets.leading, f.maxX)
            case .trailing: insets.trailing = max(insets.trailing, size.width - f.minX)
            }
        }
        return insets
    }

    /// Axis of the active fold, or nil when flat. Safe to hand to state (it's not a frame).
    var foldAxis: Axis? {
        guard let fold = divisionFrames.first else { return nil }
        return fold.height > fold.width ? .vertical : .horizontal
    }

    /// Top/bottom padding that keeps a vertical column (e.g. the trailing rail, given in
    /// the same coordinate space) clear of occlusions that overlap it: the persistent
    /// status area at the top of the rail, or the inner camera when it's active.
    func verticalInsets(forColumn column: CGRect) -> (top: CGFloat, bottom: CGFloat) {
        var top: CGFloat = 0, bottom: CGFloat = 0
        for frame in occlusionFrames where frame.intersects(column) {
            if frame.midY < column.midY {
                top = max(top, frame.maxY - column.minY)
            } else {
                bottom = max(bottom, column.maxY - frame.minY)
            }
        }
        return (max(0, top), max(0, bottom))
    }

    /// True if `rect` (in the same coordinate space) intersects the fold or an occlusion.
    func collides(_ rect: CGRect) -> Bool {
        (divisionFrames + occlusionFrames).contains { $0.intersects(rect) }
    }
}

// MARK: - Toolbar priorities

/// Our own priority names, mapped to ToolbarItemVisibilityPriority (iOS 27) in one place.
enum DuoToolbarPriority {
    case low, high
    /// Record must be the very last thing to collapse.
    case duoCritical
}

extension ToolbarContent {
    /// Thin wrapper so the (not fully confirmed) modifier name lives in one place.
    func duoVisibilityPriority(_ priority: DuoToolbarPriority) -> some ToolbarContent {
        #if DUO_COMPAT_SDK
        return self
        #else
        let value: ToolbarItemVisibilityPriority = switch priority {
        case .low: .low
        case .high: .high
        case .duoCritical: ToolbarItemVisibilityPriority(higherThan: .high)
        }
        return visibilityPriority(value)
        #endif
    }
}

/// ToolbarOverflowMenu (iOS 27.0), or a trailing "•••" menu in compat builds.
struct DuoToolbarOverflowMenu<Content: View>: ToolbarContent {
    @ViewBuilder var content: () -> Content

    var body: some ToolbarContent {
        #if DUO_COMPAT_SDK
        ToolbarItem(placement: .topBarTrailing) {
            Menu { content() } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("More")
        }
        #else
        ToolbarOverflowMenu { content() }
        #endif
    }
}

// MARK: - ArrangementView (iOS 27.1)

/// `.overlay` arrangement: `primary` floats over `secondary`.
struct DuoOverlayArrangement<Primary: View, Secondary: View>: View {
    @ViewBuilder var primary: () -> Primary
    @ViewBuilder var secondary: () -> Secondary

    var body: some View {
        #if DUO_COMPAT_SDK
        ZStack { secondary(); primary() }
        #else
        ArrangementView { primary() } secondary: { secondary() }
            .arrangementViewStyle(.overlay)
        #endif
    }
}

/// `.split` arrangement with `primary` taking `primaryRatio` of the space.
struct DuoSplitArrangement<Primary: View, Secondary: View>: View {
    var primaryRatio: CGFloat
    @ViewBuilder var primary: () -> Primary
    @ViewBuilder var secondary: () -> Secondary

    var body: some View {
        #if DUO_COMPAT_SDK
        GeometryReader { proxy in
            HStack(spacing: 0) {
                primary().frame(width: proxy.size.width * primaryRatio)
                secondary()
            }
        }
        #else
        ArrangementView {
            primary().splitArrangementLayoutRatio(primaryRatio)
        } secondary: {
            secondary()
        }
        .arrangementViewStyle(.split)
        #endif
    }
}
