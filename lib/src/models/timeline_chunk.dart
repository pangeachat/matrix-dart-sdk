import 'package:matrix/matrix.dart';

class TimelineChunk {
  String prevBatch; // pos of the first event of the database timeline chunk
  String nextBatch;

  List<Event> events;

  /// The chunk's events by id.
  ///
  /// Derived, not cached. It used to be built once in the constructor, so
  /// every event added to [events] afterwards was invisible to it -- and
  /// `Timeline.getEventById` went to the SERVER for an event already sitting
  /// in memory. For an event still being sent, which the server has never
  /// heard of, that is not a slow answer but a wrong one.
  Map<String, Event> get eventsMap => {
        for (final event in events) event.eventId: event,
      };

  TimelineChunk({
    required this.events,
    this.prevBatch = '',
    this.nextBatch = '',
  });
}
