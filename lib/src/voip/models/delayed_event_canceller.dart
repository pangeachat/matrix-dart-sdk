import 'dart:async';

/// A scheduled delayed leave event, and the heartbeat keeping it alive.
///
/// Held per call rather than per process. A single global pair of these was
/// shared by every call in the app: the first call to schedule one owned it,
/// every later call skipped scheduling because the global was already set, and
/// a failure to cancel left the global populated for the rest of the process —
/// so no call after that ever got a delayed leave at all.
class DelayedEventCanceller {
  final String delayedEventId;
  final Timer restartTimer;

  DelayedEventCanceller({
    required this.delayedEventId,
    required this.restartTimer,
  });
}
