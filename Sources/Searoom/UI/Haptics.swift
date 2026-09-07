import AppKit

/// One gate for every haptic in the app.
///
/// Routing the calls through here means a new detent cannot ship ignoring the
/// user's preference, and it keeps `NSHapticFeedbackManager` out of the call
/// sites. There is no state and no cost when the setting is off: the guard
/// returns before the performer is even looked up.
///
/// `.drawCompleted` defers the tap until after the frame it belongs to, so a
/// gesture never waits on feedback.
enum Haptics {
    static func tap(
        _ pattern: NSHapticFeedbackManager.FeedbackPattern,
        enabled: Bool
    ) {
        guard enabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .drawCompleted)
    }
}
