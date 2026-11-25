import ActivityKit
import Foundation

/// Phase 11: starts, updates and ends the recording Live Activity. Failures are silent:
/// the Live Activity is a convenience and must never get in the way of a take.
@MainActor
final class RecordingActivityController {
    private var activity: Activity<RecordingActivityAttributes>?
    private var content: RecordingActivityAttributes.ContentState?

    func start(takeNumber: Int, startedAt: Date, isLive: Bool, projectName: String?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end()
        let state = RecordingActivityAttributes.ContentState(takeNumber: takeNumber, startedAt: startedAt,
                                                             markerCount: 0, isLive: isLive)
        content = state
        activity = try? Activity.request(attributes: RecordingActivityAttributes(shotTitle: projectName),
                                         content: ActivityContent(state: state, staleDate: nil))
    }

    func update(markerCount: Int) {
        guard let activity, var state = content else { return }
        state.markerCount = markerCount
        content = state
        // Activity isn't Sendable; ActivityKit documents update/end as safe from any task.
        nonisolated(unsafe) let live = activity
        Task { await live.update(ActivityContent(state: state, staleDate: nil)) }
    }

    func end() {
        guard let activity else { return }
        let final = content.map { ActivityContent(state: $0, staleDate: nil) }
        self.activity = nil
        content = nil
        nonisolated(unsafe) let live = activity
        Task { await live.end(final, dismissalPolicy: .immediate) }
    }
}
