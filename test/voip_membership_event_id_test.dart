import 'package:test/test.dart';

import 'package:matrix/matrix.dart';
import 'fake_client.dart';
import 'webrtc_stub.dart';

void main() {
  late Client matrix;
  late Room room;
  late VoIP voip;
  late MeshBackend backend;
  late String membershipUrl;
  late int writes;

  /// The membership the PREVIOUS call left standing in room state.
  ///
  /// Same room, same call id, same device, same session id, and not expired
  /// yet -- every field the SDK publishes is identical to what the next call
  /// will publish. This is the state a second call in one process actually
  /// starts from, and the reason room state cannot answer "which membership
  /// did I just write".
  void seedPreviousCallMembership({
    required String callId,
    required String eventId,
  }) {
    room.setState(
      Event(
        room: room,
        eventId: eventId,
        originServerTs: DateTime.now(),
        type: EventTypes.GroupCallMember,
        senderId: matrix.userID!,
        stateKey: matrix.userID!,
        content: {
          'memberships': [
            CallMembership(
              userId: matrix.userID!,
              roomId: room.id,
              callId: callId,
              application: 'm.call',
              scope: 'm.room',
              backend: backend,
              deviceId: matrix.deviceID!,
              expiresTs:
                  DateTime.now().add(Duration(hours: 1)).millisecondsSinceEpoch,
              membershipId: voip.currentSessionId,
              feeds: [],
              voip: voip,
            ).toJson(),
          ],
        },
      ),
    );
  }

  group('Published call membership event id', () {
    Logs().level = Level.info;

    setUp(() async {
      matrix = await getClient();
      await matrix.abortSync();

      voip = VoIP(matrix, MockWebRTCDelegate());
      room = matrix.getRoomById('!calls:example.com')!;
      backend = MeshBackend();

      // The shipped fixture answers every membership write with the SAME
      // event id, which is the one thing a real homeserver never does: each
      // write is a new event and gets a new id. Without this the tests below
      // would be asserting the fixture rather than the server contract they
      // rest on.
      membershipUrl = '/client/v3/rooms/${Uri.encodeComponent(room.id)}'
          '/state/${EventTypes.GroupCallMember}'
          '/${Uri.encodeComponent(matrix.userID!)}';
      writes = 0;
      FakeMatrixApi.currentApi!.api['PUT']![membershipUrl] =
          (dynamic _) => {'event_id': '\$membership-write-${++writes}'};
    });

    tearDown(() async {
      for (final groupCall in voip.groupCalls.values.toList()) {
        try {
          await groupCall.leave();
        } catch (_) {
          // teardown only
        }
      }
    });

    test(
        'enter returns the id of the membership it published, which room state '
        'cannot supply', () async {
      // The client uses the room id as the call id, so a redial in the same
      // room publishes under the same key as the call before it.
      final groupCall = GroupCallSession.withAutoGenId(
        room,
        voip,
        backend,
        'm.call',
        'm.room',
        room.id,
      );
      seedPreviousCallMembership(
        callId: room.id,
        eventId: '\$previous-call-membership',
      );

      final joined = await groupCall.enter();

      // The id the server gave THIS write, rather than nothing at all.
      expect(joined, '\$membership-write-1');

      // And the proxy it replaces: state still holds the previous call's
      // membership, unexpired and identical in every published field, so a
      // caller reading it back would key this call on the last one.
      final fromState = room
          .getCallMembershipsForUser(matrix.userID!, matrix.deviceID!, voip)
          .single;
      expect(fromState.eventId, '\$previous-call-membership');
      expect(joined, isNot(fromState.eventId));
    });

    test(
        'a refresh mints a new id, and returns that one rather than the join'
        "'s", () async {
      final groupCall = GroupCallSession.withAutoGenId(
        room,
        voip,
        backend,
        'm.call',
        'm.room',
        room.id,
      );

      final joined = await groupCall.enter();
      // What the periodic refresh does, minus the wait: it republishes the
      // membership through the same method.
      final refreshed = await groupCall.sendMemberStateEvent();
      final refreshedAgain = await groupCall.sendMemberStateEvent();

      expect(joined, '\$membership-write-1');
      expect(refreshed, '\$membership-write-2');
      expect(refreshedAgain, '\$membership-write-3');
    });

    test('a call that has left writes no membership and returns no id',
        () async {
      final groupCall = GroupCallSession.withAutoGenId(
        room,
        voip,
        backend,
        'm.call',
        'm.room',
        room.id,
      );

      await groupCall.enter();
      await groupCall.leave();

      expect(await groupCall.sendMemberStateEvent(), isNull);
    });
  });
}
