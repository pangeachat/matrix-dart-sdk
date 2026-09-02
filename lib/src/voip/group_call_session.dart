/*
 *   Famedly Matrix SDK
 *   Copyright (C) 2021 Famedly GmbH
 *
 *   This program is free software: you can redistribute it and/or modify
 *   it under the terms of the GNU Affero General License as
 *   published by the Free Software Foundation, either version 3 of the
 *   License, or (at your option) any later version.
 *
 *   This program is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *   GNU Affero General License for more details.
 *
 *   You should have received a copy of the GNU Affero General License
 *   along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import 'dart:async';
import 'dart:core';

import 'package:collection/collection.dart';

import 'package:matrix/matrix.dart';
import 'package:matrix/src/utils/cached_stream_controller.dart';
import 'package:matrix/src/voip/models/call_reaction_payload.dart';
import 'package:matrix/src/voip/models/voip_id.dart';
import 'package:matrix/src/voip/utils/stream_helper.dart';

/// Holds methods for managing a group call. This class is also responsible for
/// holding and managing the individual `CallSession`s in a group call.
class GroupCallSession {
  // Config
  final Client client;
  final VoIP voip;
  final Room room;

  /// is a list of backend to allow passing multiple backend in the future
  /// we use the first backend everywhere as of now
  final CallBackend backend;

  /// something like normal calls or thirdroom
  final String? application;

  /// either room scoped or user scoped calls
  final String? scope;

  GroupCallState state = GroupCallState.localCallFeedUninitialized;

  CallParticipant? get localParticipant => voip.localParticipant;

  List<CallParticipant> get participants => List.unmodifiable(_participants);
  final Set<CallParticipant> _participants = {};

  String groupCallId;

  @Deprecated('Use matrixRTCEventStream instead')
  final CachedStreamController<GroupCallState> onGroupCallState =
      CachedStreamController();

  @Deprecated('Use matrixRTCEventStream instead')
  final CachedStreamController<GroupCallStateChange> onGroupCallEvent =
      CachedStreamController();

  final CachedStreamController<MatrixRTCCallEvent> matrixRTCEventStream =
      CachedStreamController();

  Timer? _resendMemberStateEventTimer;

  factory GroupCallSession.withAutoGenId(
    Room room,
    VoIP voip,
    CallBackend backend,
    String? application,
    String? scope,
    String? groupCallId,
  ) {
    return GroupCallSession(
      client: room.client,
      room: room,
      voip: voip,
      backend: backend,
      application: application ?? 'm.call',
      scope: scope ?? 'm.room',
      groupCallId: groupCallId ?? genCallID(),
    );
  }

  GroupCallSession({
    required this.client,
    required this.room,
    required this.voip,
    required this.backend,
    required this.groupCallId,
    required this.application,
    required this.scope,
  });

  String get avatarName =>
      _getUser().calcDisplayname(mxidLocalPartFallback: false);

  String? get displayName => _getUser().displayName;

  User _getUser() {
    return room.unsafeGetUserFromMemoryOrFallback(client.userID!);
  }

  void setState(GroupCallState newState) {
    state = newState;
    // ignore: deprecated_member_use_from_same_package
    onGroupCallState.add(newState);
    // ignore: deprecated_member_use_from_same_package
    onGroupCallEvent.add(GroupCallStateChange.groupCallStateChanged);
    matrixRTCEventStream.add(GroupCallStateChanged(newState));
  }

  bool hasLocalParticipant() {
    return _participants.contains(localParticipant);
  }

  Timer? _reactionsTimer;
  int _reactionsTicker = 0;

  /// Enter the group call. Returns the event id of the membership this join
  /// published.
  ///
  /// That id is the only thing about the write that is unique to it. Nothing
  /// the membership carries distinguishes two calls placed by one process:
  /// `call_id` is the room, `membershipId` is [VoIP.currentSessionId] and is
  /// fixed for the life of the [VoIP] object, the device id and the rest never
  /// move, and `expires_ts` is only the clock. Nor can the membership be
  /// recognised by reading room state back -- the previous call's membership
  /// stands there until it expires, and a write that syncs late, or a device
  /// clock that steps backwards, defeats every attempt to tell the two apart.
  /// So a caller that has to name the call it just started has this and
  /// nothing else.
  ///
  /// It names the JOIN, and it does not follow the call. The periodic refresh
  /// republishes the membership and the server mints a new event for it, so a
  /// couple of minutes in, the id in room state is no longer this one. Keep
  /// what `enter` handed back rather than re-deriving it from state, and do
  /// not relate events to it -- [sendMemberStateEvent] returns the id of the
  /// write it just made, which is the one state actually holds.
  ///
  /// Null only when no membership was written at all. `enter` rejects the
  /// states a finished call is in, so an ordinary join has an id -- but a
  /// `leave` still in flight on this session suppresses the write without
  /// changing the state `enter` checks, and a caller that enters into that
  /// window gets null and has published nothing.
  Future<String?> enter({WrappedMediaStream? stream}) async {
    if (!(state == GroupCallState.localCallFeedUninitialized ||
        state == GroupCallState.localCallFeedInitialized)) {
      throw MatrixSDKVoipException('Cannot enter call in the $state state');
    }

    final previousState = state;
    final openedTheStream = state == GroupCallState.localCallFeedUninitialized;
    if (openedTheStream) {
      await backend.initLocalStream(this, stream: stream);
    }

    final String? membershipEventId;
    try {
      membershipEventId = await sendMemberStateEvent();
    } catch (_) {
      // Entering is all-or-nothing. If THIS call opened the local stream, the
      // camera light is on and the microphone is live for a call that never
      // started, owned by nobody -- so it is released. If the caller had
      // already initialised media and handed it in, releasing it would take
      // away something that was never ours; the session goes back to the
      // state it was in and keeps it.
      _resendMemberStateEventTimer?.cancel();
      _resendMemberStateEventTimer = null;
      if (openedTheStream) {
        try {
          await backend.dispose(this);
        } catch (e, s) {
          Logs().w('[VOIP] could not release media after a failed join', e, s);
        }
      }
      setState(previousState);
      rethrow;
    }

    setState(GroupCallState.entered);

    Logs().v('Entered group call $groupCallId');

    // Set up _participants for the members currently in the call.
    // Other members will be picked up by the RoomState.members event.
    await onMemberStateChanged();

    await backend.setupP2PCallsWithExistingMembers(this);

    voip.currentGroupCID = VoipId(roomId: room.id, callId: groupCallId);

    await voip.delegate.handleNewGroupCall(this);

    _reactionsTimer = Timer.periodic(Duration(seconds: 1), (_) {
      if (_reactionsTicker > 0) _reactionsTicker--;
    });

    return membershipEventId;
  }

  /// Leaves the call, LOCALLY whatever the server says.
  ///
  /// Telling the room we have gone can fail -- a 5xx, a dropped connection,
  /// a token that expired mid-call -- and it used to take the rest of this
  /// with it: the media backend stayed up, the call stayed in the registry,
  /// the timers kept running. The user had pressed hang up and was still in
  /// the call, microphone live, with no way out but killing the app.
  ///
  /// The remote half is best effort and its failure is still reported; the
  /// local half is not optional. The membership left standing is what the
  /// delayed leave exists for -- the server retracts it for us.
  Future<void> leave() async {
    Object? remoteFailure;
    StackTrace? remoteStack;
    // A refresh already on its way to the server writes the same state key as
    // the retraction below. Letting them race put the membership back after
    // the leave removed it, and the room went on saying the user was in a
    // call their device had ended. So: no new refresh starts from here on,
    // the timer that would start one is stopped, and every write already out
    // there is waited for. Waiting is bounded by the requests themselves, and
    // their failures are the refresh's business, not ours.
    _leaving = true;
    _resendMemberStateEventTimer?.cancel();
    _resendMemberStateEventTimer = null;
    if (_membershipWrites.isNotEmpty) {
      await Future.wait(
        _membershipWrites.map((write) => write.catchError((_) {})),
      );
    }
    try {
      await removeMemberStateEvent();
    } catch (e, s) {
      remoteFailure = e;
      remoteStack = s;
      Logs().w(
        '[VOIP] leaving $groupCallId could not be written to the room; '
        'tearing down locally anyway',
        e,
        s,
      );
    }
    await backend.dispose(this);
    setState(GroupCallState.localCallFeedUninitialized);
    voip.currentGroupCID = null;
    _participants.clear();
    voip.groupCalls.remove(VoipId(roomId: room.id, callId: groupCallId));
    await voip.delegate.handleGroupCallEnded(this);
    _resendMemberStateEventTimer?.cancel();
    _reactionsTimer?.cancel();
    setState(GroupCallState.ended);
    if (remoteFailure != null) {
      Error.throwWithStackTrace(remoteFailure, remoteStack!);
    }
  }

  /// Every membership write still in flight.
  ///
  /// A hang-up has to wait for all of them. The refresh and the retraction
  /// write the same state key, and a refresh that started first but landed
  /// second put the membership back after the leave had removed it -- the
  /// room then said the user was in a call their device had ended. A single
  /// slot was not enough: the refresh is periodic, so a write slower than the
  /// period leaves two outstanding and the older one was the one nobody
  /// waited for.
  final Set<Future<void>> _membershipWrites = {};

  /// Set the moment a leave begins, so no further refresh starts behind it.
  bool _leaving = false;

  /// Writes this device's call membership, and REGISTERS the write.
  ///
  /// The barrier belongs here rather than at the timer, because the timer is
  /// not the only caller: anything that changes what the membership says --
  /// screen sharing, for one -- writes it directly, and a write a hang-up
  /// never knew about lands after the retraction and puts the membership
  /// back.
  ///
  /// Returns the event id the server gave the membership it wrote, or null
  /// when it declined to write -- a call on its way out, or one already over.
  /// The periodic refresh writes through here too and is handed the id of its
  /// own write, so the value always describes the write the caller just asked
  /// for. Nothing here keeps a copy, so there is no stale one to read: a
  /// caller that wants an id holds the one it was given.
  Future<String?> sendMemberStateEvent() {
    if (_leaving || state == GroupCallState.ended) {
      Logs().d('[VOIP] not refreshing the membership of a call in $state');
      return Future.value(null);
    }
    final write = _writeMemberStateEvent();
    _membershipWrites.add(write);
    return write.whenComplete(() => _membershipWrites.remove(write));
  }

  Future<String?> _writeMemberStateEvent() async {
    // Never for a call that is over, or one on its way out. `_leaving` is the
    // one that matters: it is set before the retraction, so a refresh that
    // arrives during a hang-up declines to write rather than putting the
    // membership back after it.
    //
    // NOT `localCallFeedUninitialized`. That is also the state a call is in
    // while it is being placed -- only the mesh backend moves out of it
    // before the membership is written, so guarding on it here stopped the
    // LiveKit path writing any membership at all: no ring, no answer, no
    // call. It is the END states this cares about.
    if (_leaving || state == GroupCallState.ended) {
      Logs().d('[VOIP] not refreshing the membership of a call in $state');
      return null;
    }

    // Get current member event ID to preserve permanent reactions
    final currentMemberships = room.getCallMembershipsForUser(
      client.userID!,
      client.deviceID!,
      voip,
    );

    final currentMembership = currentMemberships.firstWhereOrNull(
      (m) =>
          m.callId == groupCallId &&
          m.deviceId == client.deviceID! &&
          m.application == application &&
          m.scope == scope &&
          m.roomId == room.id,
    );

    // Store permanent reactions from the current member event if it exists
    List<MatrixEvent> permanentReactions = [];
    final membershipExpired = currentMembership?.isExpired ?? false;

    if (currentMembership?.eventId != null && !membershipExpired) {
      permanentReactions = await _getPermanentReactionsForEvent(
        currentMembership!.eventId!,
      );
    }

    final newEventId = await room.updateFamedlyCallMemberStateEvent(
      CallMembership(
        userId: client.userID!,
        roomId: room.id,
        callId: groupCallId,
        application: application,
        scope: scope,
        backend: backend,
        deviceId: client.deviceID!,
        expiresTs: DateTime.now()
            .add(voip.timeouts!.expireTsBumpDuration)
            .millisecondsSinceEpoch,
        membershipId: voip.currentSessionId,
        feeds: backend.getCurrentFeeds(),
        voip: voip,
      ),
    );

    // Copy permanent reactions to the new member event
    if (permanentReactions.isNotEmpty && newEventId != null) {
      await _copyPermanentReactionsToNewEvent(
        permanentReactions,
        newEventId,
      );
    }

    if (_resendMemberStateEventTimer != null) {
      _resendMemberStateEventTimer!.cancel();
    }
    // Not for a call that has already ended. A refresh can be in flight when
    // the user hangs up: leave() cancels this timer and retracts the
    // membership, then the stalled callback resumes, writes the membership
    // back and -- through this very line -- arms a NEW timer. The room then
    // said somebody was in a call their device had already torn down, and
    // kept saying it. The state is checked again inside the callback for the
    // same reason: the check that matters is the one at the moment of writing.
    //
    // The same two states as the write guard, and for the same reason NOT
    // `localCallFeedUninitialized`: that is the state a LiveKit call is in
    // while it is being placed, and refusing to arm the timer there left
    // every such call publishing its membership once and never refreshing
    // `expires_ts` -- so a long call aged out of room state while it was
    // still going.
    //
    // The id is still returned here: the membership above WAS written, and
    // saying otherwise would deny a caller the one thing that identifies the
    // write it just made.
    if (_leaving || state == GroupCallState.ended) {
      return newEventId;
    }
    _resendMemberStateEventTimer = Timer.periodic(
      voip.timeouts!.updateExpireTsTimerDuration,
      ((timer) async {
        Logs().d('sendMemberStateEvent updating member event with timer');
        // Nothing in here may throw. This is a Timer callback: an escaping
        // error reaches no caller, and the timer goes on raising the same one
        // every tick for the rest of the call. A 429 or a 5xx on one refresh
        // is not a reason to stop refreshing.
        try {
          // AND, not OR. Written as `!=  ... || != ...` this was true for
          // every state there is, so the branch below -- the one that cleans
          // up after a call that has ended -- could never run.
          if (state != GroupCallState.ended &&
              state != GroupCallState.localCallFeedUninitialized) {
            // Registered by sendMemberStateEvent itself, so every caller
            // is inside the barrier and not just this one.
            await sendMemberStateEvent();
          } else {
            Logs().d(
              '[VOIP] deteceted groupCall in state $state, removing state event',
            );
            await removeMemberStateEvent();
          }
        } catch (e, s) {
          Logs()
              .w('[VOIP] a membership refresh failed; it will try again', e, s);
        }
      }),
    );

    return newEventId;
  }

  Future<void> removeMemberStateEvent() {
    if (_resendMemberStateEventTimer != null) {
      Logs().d('resend member event timer cancelled');
      _resendMemberStateEventTimer!.cancel();
      _resendMemberStateEventTimer = null;
    }
    return room.removeFamedlyCallMemberEvent(
      groupCallId,
      voip,
      application: application,
      scope: scope,
    );
  }

  /// compltetely rebuilds the local _participants list
  Future<void> onMemberStateChanged() async {
    // The member events may be received for another room, which we will ignore.
    final mems = room
        .getCallMembershipsFromRoom(voip)
        .values
        .expand((element) => element);
    final memsForCurrentGroupCall = mems.where((element) {
      return element.callId == groupCallId &&
          !element.isExpired &&
          element.application == application &&
          element.scope == scope &&
          element.roomId == room.id; // sanity checks
    }).toList();

    final Set<CallParticipant> newP = {};

    for (final mem in memsForCurrentGroupCall) {
      final rp = CallParticipant(
        voip,
        userId: mem.userId,
        deviceId: mem.deviceId,
      );

      newP.add(rp);

      if (rp.isLocal) continue;

      if (state != GroupCallState.entered) continue;

      await backend.setupP2PCallWithNewMember(this, rp, mem);
    }
    final newPcopy = Set<CallParticipant>.from(newP);
    final oldPcopy = Set<CallParticipant>.from(_participants);
    final anyJoined = newPcopy.difference(oldPcopy);
    final anyLeft = oldPcopy.difference(newPcopy);

    if (anyJoined.isNotEmpty || anyLeft.isNotEmpty) {
      if (anyJoined.isNotEmpty) {
        final nonLocalAnyJoined = Set<CallParticipant>.from(anyJoined)
          ..remove(localParticipant);
        if (nonLocalAnyJoined.isNotEmpty && state == GroupCallState.entered) {
          Logs().v(
            'nonLocalAnyJoined: ${nonLocalAnyJoined.map((e) => e.id).toString()} roomId: ${room.id} groupCallId: $groupCallId',
          );
          await backend.onNewParticipant(this, nonLocalAnyJoined.toList());
        }
        _participants.addAll(anyJoined);
        matrixRTCEventStream
            .add(ParticipantsJoinEvent(participants: anyJoined.toList()));
      }
      if (anyLeft.isNotEmpty) {
        final nonLocalAnyLeft = Set<CallParticipant>.from(anyLeft)
          ..remove(localParticipant);
        if (nonLocalAnyLeft.isNotEmpty && state == GroupCallState.entered) {
          Logs().v(
            'nonLocalAnyLeft: ${nonLocalAnyLeft.map((e) => e.id).toString()} roomId: ${room.id} groupCallId: $groupCallId',
          );
          await backend.onLeftParticipant(this, nonLocalAnyLeft.toList());
        }
        _participants.removeAll(anyLeft);
        matrixRTCEventStream
            .add(ParticipantsLeftEvent(participants: anyLeft.toList()));
      }

      // ignore: deprecated_member_use_from_same_package
      onGroupCallEvent.add(GroupCallStateChange.participantsChanged);
    }
  }

  /// Send a reaction event to the group call
  ///
  /// [emoji] - The reaction emoji (e.g., '🖐️' for hand raise)
  /// [name] - The reaction name (e.g., 'hand raise')
  /// [isEphemeral] - Whether the reaction is ephemeral (default: true)
  ///
  /// Returns the event ID of the sent reaction event
  Future<String> sendReactionEvent({
    required String emoji,
    bool isEphemeral = true,
  }) async {
    if (isEphemeral && _reactionsTicker > 10) {
      throw Exception(
        '[sendReactionEvent] manual throttling, too many ephemral reactions sent',
      );
    }

    Logs().d('Group call reaction selected: $emoji');

    final memberships =
        room.getCallMembershipsForUser(client.userID!, client.deviceID!, voip);
    final membership = memberships.firstWhereOrNull(
      (m) =>
          m.callId == groupCallId &&
          m.deviceId == client.deviceID! &&
          m.roomId == room.id &&
          m.application == application &&
          m.scope == scope,
    );

    if (membership == null) {
      throw Exception(
        '[sendReactionEvent] No matching membership found to send group call emoji reaction from ${client.userID!}',
      );
    }

    final payload = ReactionPayload(
      key: emoji,
      isEphemeral: isEphemeral,
      callId: groupCallId,
      deviceId: client.deviceID!,
      relType: RelationshipTypes.reference,
      eventId: membership.eventId!,
    );

    // Send reaction as unencrypted event to avoid decryption issues
    final txid = client.generateUniqueTransactionId();
    _reactionsTicker++;
    return await client.sendMessage(
      room.id,
      EventTypes.GroupCallMemberReaction,
      txid,
      payload.toJson(),
    );
  }

  /// Remove a reaction event from the group call
  ///
  /// [eventId] - The event ID of the reaction to remove
  ///
  /// Returns the event ID of the removed reaction event
  Future<String?> removeReactionEvent({required String eventId}) async {
    return await client.redactEventWithMetadata(
      room.id,
      eventId,
      client.generateUniqueTransactionId(),
      metadata: {
        'device_id': client.deviceID,
        'call_id': groupCallId,
        'redacts_type': EventTypes.GroupCallMemberReaction,
      },
    );
  }

  /// Get all reactions of a specific type for all participants in the call
  ///
  /// [emoji] - The reaction emoji to filter by (e.g., '🖐️')
  ///
  /// Returns a list of [MatrixEvent] objects representing the reactions
  Future<List<MatrixEvent>> getAllReactions({required String emoji}) async {
    final reactions = <MatrixEvent>[];

    final memberships = room
        .getCallMembershipsFromRoom(
          voip,
        )
        .values
        .expand((e) => e);

    final membershipsForCurrentGroupCall = memberships
        .where(
          (m) =>
              m.callId == groupCallId &&
              m.application == application &&
              m.scope == scope &&
              m.roomId == room.id,
        )
        .toList();

    for (final membership in membershipsForCurrentGroupCall) {
      if (membership.eventId == null) continue;

      // this could cause a problem in large calls because it would make
      // n number of /relations requests where n is the number of participants
      // but turns our synapse does not rate limit these so should be fine?
      final eventsToProcess =
          (await client.getRelatingEventsWithRelTypeAndEventType(
        room.id,
        membership.eventId!,
        RelationshipTypes.reference,
        EventTypes.GroupCallMemberReaction,
        recurse: false,
        limit: 100,
      ))
              .chunk;

      reactions.addAll(
        eventsToProcess.where((event) => event.content['key'] == emoji),
      );
    }

    return reactions;
  }

  /// Get all permanent reactions for a specific member event ID
  ///
  /// [eventId] - The member event ID to get reactions for
  ///
  /// Returns a list of [MatrixEvent] objects representing permanent reactions
  Future<List<MatrixEvent>> _getPermanentReactionsForEvent(
    String eventId,
  ) async {
    final permanentReactions = <MatrixEvent>[];

    try {
      final events = await client.getRelatingEventsWithRelTypeAndEventType(
        room.id,
        eventId,
        RelationshipTypes.reference,
        EventTypes.GroupCallMemberReaction,
        recurse: false,
        // makes sure that if you make too many reactions, permanent reactions don't miss out
        // hopefully 100 is a good value
        limit: 100,
      );

      for (final event in events.chunk) {
        final content = event.content;
        final isEphemeral = content['is_ephemeral'] as bool? ?? false;
        final isRedacted = event.redacts != null;

        if (!isEphemeral && !isRedacted) {
          permanentReactions.add(event);
          Logs().d(
            '[VOIP] Found permanent reaction to preserve: ${content['key']} from ${event.senderId}',
          );
        }
      }
    } catch (e, s) {
      Logs().e(
        '[VOIP] Failed to get permanent reactions for event $eventId',
        e,
        s,
      );
    }

    return permanentReactions;
  }

  /// Copy permanent reactions to the new member event
  ///
  /// [permanentReactions] - List of permanent reaction events to copy
  /// [newEventId] - The event ID of the new membership event
  Future<void> _copyPermanentReactionsToNewEvent(
    List<MatrixEvent> permanentReactions,
    String newEventId,
  ) async {
    // Re-send each permanent reaction with the new event ID
    for (final reactionEvent in permanentReactions) {
      try {
        final content = reactionEvent.content;
        final reactionKey = content['key'] as String?;

        if (reactionKey == null) {
          Logs().w(
            '[VOIP] Skipping permanent reaction copy: missing reaction key',
          );
          continue;
        }

        // Build new reaction event with updated event ID
        final payload = ReactionPayload(
          key: reactionKey,
          isEphemeral: false,
          callId: groupCallId,
          deviceId: client.deviceID!,
          relType: RelationshipTypes.reference,
          eventId: newEventId,
        );

        // Send the permanent reaction with new event ID
        final txid = client.generateUniqueTransactionId();
        await client.sendMessage(
          room.id,
          EventTypes.GroupCallMemberReaction,
          txid,
          payload.toJson(),
        );

        Logs().d(
          '[VOIP] Copied permanent reaction $reactionKey to new member event $newEventId',
        );
      } catch (e, s) {
        Logs().e(
          '[VOIP] Failed to copy permanent reaction',
          e,
          s,
        );
      }
    }
  }
}
