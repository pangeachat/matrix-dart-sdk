// Drives the delayed-leave lifecycle against a REAL local Synapse.
//
// Not part of CI: it needs a homeserver at PROBE_HS with MSC4140 enabled.
// Run with:
//   PROBE_HS=http://localhost:8008 PROBE_USER=learner PROBE_PASS=learnerpass \
//     dart test test/delayed_leave_live_probe.dart
//
// It exists because the defects being fixed only appear against a server that
// cancels a user's own delayed state event on their own state write, which is
// every Synapse before 1.127.0 -- including the one Pangea runs.
import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import 'package:matrix/matrix.dart';
import 'fake_database.dart';
import 'webrtc_stub.dart';

final _hs = Platform.environment['PROBE_HS'] ?? '';
final _user = Platform.environment['PROBE_USER'] ?? '';
final _pass = Platform.environment['PROBE_PASS'] ?? '';

void main() {
  test('a call joins, the heartbeat gives up once, and leaving still finishes',
      () async {
    Logs().level = Level.warning;

    final client = Client(
      'delayed-leave-probe',
      database: await getDatabase(),
    );
    await client.checkHomeserver(Uri.parse(_hs));
    await client.login(
      LoginType.mLoginPassword,
      identifier: AuthenticationUserIdentifier(user: _user),
      password: _pass,
    );
    await client.roomsLoading;
    await client.oneShotSync();

    final advertised = (await client.versionsResponse)
            .unstableFeatures?['org.matrix.msc4140'] ??
        false;
    expect(advertised, isTrue, reason: 'the probe needs MSC4140 advertised');

    final roomId = await client.createRoom(preset: CreateRoomPreset.privateChat);
    await client.oneShotSync();
    final room = client.getRoomById(roomId)!;

    final voip = VoIP(client, MockWebRTCDelegate());
    const callId = 'probe-call';
    final key = '$roomId|$callId|m.call|m.room';

    // JOIN: schedules a delayed leave and starts the heartbeat.
    await room.setFamedlyCallMemberEvent(
      {
        'memberships': [
          {
            'call_id': callId,
            'application': 'm.call',
            'scope': 'm.room',
            'device_id': client.deviceID,
            'expires_ts':
                DateTime.now().add(Duration(hours: 1)).millisecondsSinceEpoch,
            'membershipID': voip.currentSessionId,
            'foci_active': [
              {'type': 'livekit', 'livekit_service_url': 'http://sfu:7980'},
            ],
          },
        ],
      },
      voip,
      callId,
    );

    expect(
      voip.delayedEventCancellers[key],
      isNotNull,
      reason: 'the join scheduled a delayed leave and recorded its canceller',
    );

    // The heartbeat runs every CallTimeouts.delayedEventRestart (4s). On this
    // server the join's own state write has already cancelled the delayed
    // event, so the first tick gets M_NOT_FOUND. It must give up, not spin.
    await Future.delayed(const Duration(seconds: 10));

    expect(
      voip.delayedEventCancellers[key],
      isNull,
      reason: 'the heartbeat saw the event was gone and stood down',
    );

    // LEAVE: must complete even though there is nothing left to cancel.
    await expectLater(
      room.removeFamedlyCallMemberEvent(callId, voip),
      completes,
      reason: 'a leave is not allowed to fail on its own bookkeeping',
    );

    await client.logout();
  },
      timeout: const Timeout(Duration(minutes: 2)),
      // Skipped unless pointed at a homeserver. `dart test` with no path runs
      // this whole directory, so without the guard this would fail every CI
      // run on a box that has no Synapse.
      skip: _hs.isEmpty
          ? 'set PROBE_HS, PROBE_USER and PROBE_PASS to run this against a homeserver'
          : null,
  );
}
