import 'dart:async';

import 'package:collection/collection.dart';

import 'package:matrix/matrix.dart';

extension FamedlyCallMemberEventsExtension on Room {
  /// a map of every users famedly call event, holds the memberships list
  /// returns sorted according to originTs (oldest to newest)
  Map<String, FamedlyCallMemberEvent> getFamedlyCallEvents(VoIP voip) {
    final Map<String, FamedlyCallMemberEvent> mappedEvents = {};
    final famedlyCallMemberStates =
        states.tryGetMap<String, Event>(EventTypes.GroupCallMember);

    if (famedlyCallMemberStates == null) return {};
    final sortedEvents = famedlyCallMemberStates.values
        .sorted((a, b) => a.originServerTs.compareTo(b.originServerTs));

    for (final element in sortedEvents) {
      mappedEvents.addAll(
        {element.stateKey!: FamedlyCallMemberEvent.fromJson(element, voip)},
      );
    }
    return mappedEvents;
  }

  /// extracts memberships list form a famedly call event and maps it to a userid
  /// returns sorted (oldest to newest)
  Map<String, List<CallMembership>> getCallMembershipsFromRoom(VoIP voip) {
    final parsedMemberEvents = getFamedlyCallEvents(voip);
    final Map<String, List<CallMembership>> memberships = {};
    for (final element in parsedMemberEvents.entries) {
      memberships.addAll({element.key: element.value.memberships});
    }
    return memberships;
  }

  /// returns a list of memberships in the room for `user`
  /// if room version is org.matrix.msc3757.11 it also uses the deviceId
  List<CallMembership> getCallMembershipsForUser(
    String userId,
    String deviceId,
    VoIP voip,
  ) {
    final useMSC3757 = (roomVersion?.contains('msc3757') ?? false);
    final stateKey = voip.useUnprotectedPerDeviceStateKeys
        ? '${deviceId}_$userId'
        : useMSC3757
            ? '${userId}_$deviceId'
            : userId;
    final parsedMemberEvents = getCallMembershipsFromRoom(voip);
    final mem = parsedMemberEvents.tryGet<List<CallMembership>>(stateKey);
    return mem ?? [];
  }

  /// returns the user count (not sessions, yet) for the group call with id: `groupCallId`.
  /// returns 0 if group call not found
  int groupCallParticipantCount(
    String groupCallId,
    VoIP voip,
  ) {
    int participantCount = 0;
    // userid:membership
    final memberships = getCallMembershipsFromRoom(voip);

    memberships.forEach((key, value) {
      for (final membership in value) {
        if (membership.callId == groupCallId && !membership.isExpired) {
          participantCount++;
        }
      }
    });

    return participantCount;
  }

  bool hasActiveGroupCall(VoIP voip) {
    if (activeGroupCallIds(voip).isNotEmpty) {
      return true;
    }
    return false;
  }

  /// list of active group call ids
  List<String> activeGroupCallIds(VoIP voip) {
    final Set<String> ids = {};
    final memberships = getCallMembershipsFromRoom(voip);

    memberships.forEach((key, value) {
      for (final mem in value) {
        if (!mem.isExpired) ids.add(mem.callId);
      }
    });
    return ids.toList();
  }

  /// passing no `CallMembership` removes it from the state event.
  /// Returns the event ID of the new membership state event.
  Future<String?> updateFamedlyCallMemberStateEvent(
    CallMembership callMembership,
  ) async {
    final ownMemberships = getCallMembershipsForUser(
      client.userID!,
      client.deviceID!,
      callMembership.voip,
    );

    // do not bother removing other deviceId expired events because we have no
    // ownership over them
    ownMemberships
        .removeWhere((element) => client.deviceID! == element.deviceId);

    ownMemberships.removeWhere((e) => e == callMembership);

    ownMemberships.add(callMembership);

    final newContent = {
      'memberships': List.from(ownMemberships.map((e) => e.toJson())),
    };

    return await setFamedlyCallMemberEvent(
      newContent,
      callMembership.voip,
      callMembership.callId,
      application: callMembership.application,
      scope: callMembership.scope,
    );
  }

  Future<void> removeFamedlyCallMemberEvent(
    String groupCallId,
    VoIP voip, {
    String? application = 'm.call',
    String? scope = 'm.room',
  }) async {
    final ownMemberships = getCallMembershipsForUser(
      client.userID!,
      client.deviceID!,
      voip,
    );

    ownMemberships.removeWhere(
      (mem) =>
          mem.callId == groupCallId &&
          mem.deviceId == client.deviceID! &&
          mem.application == application &&
          mem.scope == scope,
    );

    final newContent = {
      'memberships': List.from(ownMemberships.map((e) => e.toJson())),
    };

    // Taken down BEFORE the write, never after. Two things depended on it:
    // while this was still in the map an await later, a redial for the same
    // call would find it, skip scheduling its own delayed leave, and then have
    // this leave delete the key underneath it. And the write below goes through
    // setFamedlyCallMemberEvent -- the JOIN writer -- which schedules a delayed
    // leave whenever it finds no canceller. On a homeserver where the heartbeat
    // has already given up (see the M_NOT_FOUND path below), hanging up would
    // otherwise schedule a brand new delayed leave, with a fresh heartbeat, for
    // the call being left.
    final cancellerKey = '$id|$groupCallId|$application|$scope';
    final canceller = voip.delayedEventCancellers.remove(cancellerKey);
    canceller?.restartTimer.cancel();

    try {
      await setFamedlyCallMemberEvent(
        newContent,
        voip,
        groupCallId,
        application: application,
        scope: scope,
        // Belt and braces with the removal above: leaving never schedules.
        scheduleDelayedLeave: false,
      );
    } catch (_) {
      // The leave did not land, so we may still be in the call -- but its
      // heartbeat was stopped above, and an unattended delayed leave fires on
      // its own and retracts a membership we are still holding. Take it off the
      // server before letting the failure through.
      if (canceller != null) {
        try {
          await client.manageDelayedEvent(
            canceller.delayedEventId,
            DelayedEventAction.cancel,
          );
        } catch (e, s) {
          try {
            Logs().w(
              '[removeFamedlyCallMemberEvent] could not cancel the delayed leave of a failed leave',
              e,
              s,
            );
          } catch (_) {
            // Never allowed to mask the original leave failure below.
          }
        }
      }
      rethrow;
    }

    // Nothing held locally means nothing this process scheduled. A delayed
    // leave left on the server by a PREVIOUS process is not chased here on
    // purpose: doing so costs an enumerate round trip on every hangup, and
    // hanging up has to feel instant. The join path already enumerates and
    // cancels leftovers for this room and state key, which is the path any
    // leftover has to pass through before it could matter.
    if (canceller == null) return;

    // Wrapped whole, logging included: nothing here may escape. The membership
    // has ALREADY been written away above, so the peer has seen us go, and an
    // error thrown from this point aborts the caller's own teardown half way --
    // the media backend, the session registry -- and a session left in that
    // registry is what makes the next call in the room look busy. A delayed
    // leave that survives and later fires only rewrites the empty memberships
    // we just wrote, which is harmless.
    try {
      try {
        await client.manageDelayedEvent(
          canceller.delayedEventId,
          DelayedEventAction.cancel,
        );
      } on MatrixException catch (e) {
        // Already sent or already gone: the delayed leave is not scheduled any
        // more, which is precisely what cancelling it was for.
        if (e.error != MatrixError.M_NOT_FOUND) {
          Logs().w(
            '[removeFamedlyCallMemberEvent] could not cancel the delayed leave',
            e,
          );
        }
      } catch (e, s) {
        Logs().w(
          '[removeFamedlyCallMemberEvent] could not cancel the delayed leave',
          e,
          s,
        );
      }
    } catch (_) {
      // Absolutely last resort, including a logger that throws.
    }
  }

  Future<String?> setFamedlyCallMemberEvent(
    Map<String, List> newContent,
    VoIP voip,
    String groupCallId, {
    String? application = 'm.call',
    String? scope = 'm.room',

    /// Whether this write may schedule a delayed leave for the call.
    ///
    /// False when the write IS the leave. This method is shared by joining and
    /// leaving and cannot otherwise tell them apart, so a leave would schedule
    /// a delayed leave for the call it is ending.
    bool scheduleDelayedLeave = true,
  }) async {
    final useMSC3757 = (roomVersion?.contains('msc3757') ?? false);

    if (canJoinGroupCall) {
      final stateKey = voip.useUnprotectedPerDeviceStateKeys
          ? '${client.deviceID!}_${client.userID!}'
          : useMSC3757
              ? '${client.userID!}_${client.deviceID!}'
              : client.userID!;

      final useDelayedEvents = (await client.versionsResponse)
              .unstableFeatures?['org.matrix.msc4140'] ??
          false;

      final cancellerKey = '$id|$groupCallId|$application|$scope';

      /// The delayed leave THIS invocation scheduled, if any. Used to make the
      /// failure cleanup below reclaim only its own, never a redial's.
      String? scheduledByThisCall;

      /// can use delayed events, haven't used it yet, and nobody else is in the
      /// middle of setting one up. The reservation is taken synchronously, so
      /// two joins racing through the awaits below cannot both schedule.
      if (scheduleDelayedLeave &&
          useDelayedEvents &&
          voip.delayedEventCancellers[cancellerKey] == null &&
          voip.delayedEventScheduling.add(cancellerKey)) {
        try {
          // get existing ones and cancel them
          final List<ScheduledDelayedEvent> alreadyScheduledEvents = [];
          String? nextBatch;
          final sEvents = await client.getScheduledDelayedEvents();
          alreadyScheduledEvents.addAll(sEvents.scheduledEvents);
          nextBatch = sEvents.nextBatch;
          // The cursor is PASSED, and a non-empty one is the only reason to go
          // round again. Without both, a server that returns any next_batch
          // sends this asking for page one over and over, for ever.
          while (nextBatch != null && nextBatch.isNotEmpty) {
            final res = await client.getScheduledDelayedEvents(from: nextBatch);
            alreadyScheduledEvents.addAll(res.scheduledEvents);
            if (res.nextBatch == nextBatch) break;
            nextBatch = res.nextBatch;
          }

          // Scoped to THIS room and THIS event type, not the state key alone.
          // The state key is just the user id (or user_device), which is
          // identical in every room -- so filtering on it by itself made
          // joining a call in one room cancel the live delayed leave of a call
          // still running in another.
          final toCancelEvents = alreadyScheduledEvents.where(
            (element) =>
                element.stateKey == stateKey &&
                element.roomId == id &&
                element.type == EventTypes.GroupCallMember,
          );

          for (final toCancelEvent in toCancelEvents) {
            try {
              await client.manageDelayedEvent(
                toCancelEvent.delayId,
                DelayedEventAction.cancel,
              );
            } on MatrixException catch (e) {
              // Already sent, or already cancelled: there is nothing left to
              // cancel, which is exactly the state this loop wants. Anything else
              // is a real failure and must NOT be swallowed -- a join that left
              // somebody's delayed leave scheduled would have it fire underneath
              // the call we are about to start.
              if (e.error != MatrixError.M_NOT_FOUND) rethrow;
            }

            // Only AFTER the server agrees it is gone. The state key is shared
            // across applications and scopes, so this event may be one THIS
            // process still holds a canceller for; dropping that canceller before
            // knowing the cancel worked would stop a heartbeat for a delayed
            // event that is still scheduled, with nothing left able to cancel it.
            final held = voip.delayedEventCancellers.entries.firstWhereOrNull(
              (entry) => entry.value.delayedEventId == toCancelEvent.delayId,
            );
            if (held != null) {
              held.value.restartTimer.cancel();
              voip.delayedEventCancellers.remove(held.key);
            }
          }

          Map<String, List> newContent;
          if (useMSC3757 || voip.useUnprotectedPerDeviceStateKeys) {
            // scoped to deviceIds so clear the whole mems list
            newContent = {
              'memberships': [],
            };
          } else {
            // only clear our own deviceId
            final ownMemberships = getCallMembershipsForUser(
              client.userID!,
              client.deviceID!,
              voip,
            );

            ownMemberships.removeWhere(
              (mem) =>
                  mem.callId == groupCallId &&
                  mem.deviceId == client.deviceID! &&
                  mem.application == application &&
                  mem.scope == scope,
            );

            newContent = {
              'memberships': List.from(ownMemberships.map((e) => e.toJson())),
            };
          }

          final delayedLeaveEventId = await client.setRoomStateWithKeyWithDelay(
            id,
            EventTypes.GroupCallMember,
            stateKey,
            voip.timeouts!.delayedEventApplyLeave.inMilliseconds,
            newContent,
          );

          final restartDelayedLeaveEventTimer = Timer.periodic(
            voip.timeouts!.delayedEventRestart,
            ((timer) async {
              // Nothing in here may throw. This runs inside a Timer callback,
              // where an escaping error reaches no caller at all, and the timer
              // would go on raising the same one every tick for the whole call.
              try {
                try {
                  await client.manageDelayedEvent(
                    delayedLeaveEventId,
                    DelayedEventAction.restart,
                  );
                  Logs().v(
                    '[_restartDelayedLeaveEventTimer] heartbeat delayed event',
                  );
                } on MatrixException catch (e, s) {
                  if (e.error == MatrixError.M_NOT_FOUND) {
                    // The server has no such delayed event any more: it fired,
                    // or something cancelled it. Beating on it cannot bring it
                    // back, so stop rather than ask forever. Stopping comes
                    // BEFORE the log: were logging to throw, the timer would
                    // survive and keep asking for the rest of the call.
                    timer.cancel();
                    final held = voip.delayedEventCancellers[cancellerKey];
                    if (held?.delayedEventId == delayedLeaveEventId) {
                      voip.delayedEventCancellers.remove(cancellerKey);
                    }
                    Logs().w(
                      '[_restartDelayedLeaveEventTimer] delayed leave gone, stopping heartbeat',
                      e,
                    );
                  } else {
                    Logs().w(
                      '[_restartDelayedLeaveEventTimer] could not restart the delayed leave',
                      e,
                      s,
                    );
                  }
                } catch (e, s) {
                  // Kept beating. A network blip is not the event going away,
                  // and giving up on the first would drop the crash-cleanup net
                  // for the rest of the call.
                  Logs().w(
                    '[_restartDelayedLeaveEventTimer] could not restart the delayed leave',
                    e,
                    s,
                  );
                }
              } catch (_) {
                // Absolutely last resort, including a logger that throws.
              }
            }),
          );

          voip.delayedEventCancellers[cancellerKey] = DelayedEventCanceller(
            delayedEventId: delayedLeaveEventId,
            restartTimer: restartDelayedLeaveEventTimer,
          );
          scheduledByThisCall = delayedLeaveEventId;
        } finally {
          voip.delayedEventScheduling.remove(cancellerKey);
        }
      }

      try {
        return await client.setRoomStateWithKey(
          id,
          EventTypes.GroupCallMember,
          stateKey,
          newContent,
        );
      } catch (_) {
        // The join itself failed, so there is no call for the delayed leave
        // scheduled above to belong to. Left alone, its heartbeat would beat for
        // the life of the process with nothing able to stop it.
        // Matched by id, not just by key: a redial may already have put its own
        // canceller under this key, and reclaiming that would leave the live
        // call with no delayed leave and no way to cancel one.
        final orphan = voip.delayedEventCancellers[cancellerKey];
        if (orphan != null && orphan.delayedEventId == scheduledByThisCall) {
          voip.delayedEventCancellers.remove(cancellerKey);
          orphan.restartTimer.cancel();
          try {
            await client.manageDelayedEvent(
              orphan.delayedEventId,
              DelayedEventAction.cancel,
            );
          } catch (e, s) {
            try {
              Logs().w(
                '[setFamedlyCallMemberEvent] could not cancel the delayed leave of a failed join',
                e,
                s,
              );
            } catch (_) {
              // Never allowed to mask the original join failure below.
            }
          }
        }
        rethrow;
      }
    } else {
      throw MatrixSDKVoipException(
        '''
        User ${client.userID}:${client.deviceID} is not allowed to join famedly calls in room $id,
        canJoinGroupCall: $canJoinGroupCall,
        groupCallsEnabledForEveryone: $groupCallsEnabledForEveryone,
        needed: ${powerForChangingStateEvent(EventTypes.GroupCallMember)},
        own: $ownPowerLevel}
        plMap: ${getState(EventTypes.RoomPowerLevels)?.content}
        ''',
      );
    }
  }

  /// returns a list of memberships from a famedly call matrix event
  List<CallMembership> getCallMembershipsFromEvent(
    MatrixEvent event,
    VoIP voip,
  ) {
    if (event.roomId != id) return [];
    return getCallMembershipsFromEventContent(
      event.content,
      event.senderId,
      event.roomId!,
      event.eventId,
      voip,
    );
  }

  /// returns a list of memberships from a famedly call matrix event
  List<CallMembership> getCallMembershipsFromEventContent(
    Map<String, Object?> content,
    String senderId,
    String roomId,
    String? eventId,
    VoIP voip,
  ) {
    final mems = content.tryGetList<Map>('memberships');
    final callMems = <CallMembership>[];
    for (final m in mems ?? []) {
      final mem = CallMembership.fromJson(m, senderId, roomId, eventId, voip);
      if (mem != null) callMems.add(mem);
    }
    return callMems;
  }
}

bool isValidMemEvent(Map<String, Object?> event) {
  if (event['call_id'] is String &&
      event['device_id'] is String &&
      event['expires_ts'] is num &&
      event['foci_active'] is List) {
    return true;
  } else {
    Logs()
        .v('[VOIP] FamedlyCallMemberEvent ignoring unclean membership $event');
    return false;
  }
}

class MatrixSDKVoipException implements Exception {
  final String cause;
  final StackTrace? stackTrace;

  MatrixSDKVoipException(this.cause, {this.stackTrace});

  @override
  String toString() => '[VOIP] $cause, ${super.toString()}, $stackTrace';
}
