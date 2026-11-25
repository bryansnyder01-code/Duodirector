import ActivityKit
import SwiftUI
import WidgetKit

// =====================================================================================
//  DuoDirectorWidgets (Phase 11): the recording Live Activity
//
//  Lock Screen banner and Dynamic Island: REC dot, take number, running timer, marker
//  count, LIVE when the take is also being streamed. Tapping opens DuoDirector.
// =====================================================================================

@main
struct DuoDirectorWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
    }
}

struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            HStack(spacing: 12) {
                RecDot()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Take \(context.state.takeNumber)").font(.headline)
                    if let shot = context.attributes.shotTitle, !shot.isEmpty {
                        Text(shot).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(context.state.startedAt, style: .timer)
                        .font(.title2.monospacedDigit().bold()).multilineTextAlignment(.trailing)
                    HStack(spacing: 6) {
                        if context.state.isLive { LiveBadge() }
                        Label("\(context.state.markerCount)", systemImage: "bookmark.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .activityBackgroundTint(.black.opacity(0.8))
            .activitySystemActionForegroundColor(.red)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Take \(context.state.takeNumber)", systemImage: "record.circle.fill")
                        .foregroundStyle(.red).font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.startedAt, style: .timer)
                        .font(.headline.monospacedDigit()).multilineTextAlignment(.trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        if context.state.isLive { LiveBadge() }
                        Label("\(context.state.markerCount) markers", systemImage: "bookmark.fill")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            } compactLeading: {
                RecDot()
            } compactTrailing: {
                Text(context.state.startedAt, style: .timer)
                    .monospacedDigit().frame(maxWidth: 52).multilineTextAlignment(.trailing)
            } minimal: {
                RecDot()
            }
        }
    }
}

private struct RecDot: View {
    var body: some View {
        Circle().fill(.red).frame(width: 12, height: 12).accessibilityLabel("Recording")
    }
}

private struct LiveBadge: View {
    var body: some View {
        Text("LIVE").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
            .background(.red, in: .capsule).foregroundStyle(.white)
    }
}
