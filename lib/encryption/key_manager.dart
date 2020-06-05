/*
 *   Famedly Matrix SDK
 *   Copyright (C) 2019, 2020 Famedly GmbH
 *
 *   This program is free software: you can redistribute it and/or modify
 *   it under the terms of the GNU Affero General Public License as
 *   published by the Free Software Foundation, either version 3 of the
 *   License, or (at your option) any later version.
 *
 *   This program is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *   GNU Affero General Public License for more details.
 *
 *   You should have received a copy of the GNU Affero General Public License
 *   along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import 'dart:convert';

import 'package:pedantic/pedantic.dart';
import 'package:famedlysdk/famedlysdk.dart';
import 'package:famedlysdk/matrix_api.dart';
import 'package:olm/olm.dart' as olm;

import './encryption.dart';
import './utils/session_key.dart';
import './utils/outbound_group_session.dart';

const MEGOLM_KEY = 'm.megolm_backup.v1';

class KeyManager {
  final Encryption encryption;
  Client get client => encryption.client;
  final outgoingShareRequests = <String, KeyManagerKeyShareRequest>{};
  final incomingShareRequests = <String, KeyManagerKeyShareRequest>{};
  final _inboundGroupSessions = <String, Map<String, SessionKey>>{};
  final _outboundGroupSessions = <String, OutboundGroupSession>{};
  final Set<String> _loadedOutboundGroupSessions = <String>{};
  final Set<String> _requestedSessionIds = <String>{};

  KeyManager(this.encryption) {
    encryption.ssss.setValidator(MEGOLM_KEY, (String secret) async {
      final keyObj = olm.PkDecryption();
      try {
        final info = await getRoomKeysInfo();
        return keyObj.init_with_private_key(base64.decode(secret)) ==
            info['auth_data']['public_key'];
      } catch (_) {
        return false;
      } finally {
        keyObj.free();
      }
    });
  }

  bool get enabled => client.accountData[MEGOLM_KEY] != null;

  /// clear all cached inbound group sessions. useful for testing
  void clearInboundGroupSessions() {
    _inboundGroupSessions.clear();
  }

  void setInboundGroupSession(String roomId, String sessionId, String senderKey,
      Map<String, dynamic> content,
      {bool forwarded = false}) {
    final oldSession =
        getInboundGroupSession(roomId, sessionId, senderKey, otherRooms: false);
    if (oldSession != null) {
      return;
    }
    if (content['algorithm'] != 'm.megolm.v1.aes-sha2') {
      return;
    }
    olm.InboundGroupSession inboundGroupSession;
    try {
      inboundGroupSession = olm.InboundGroupSession();
      if (forwarded) {
        inboundGroupSession.import_session(content['session_key']);
      } else {
        inboundGroupSession.create(content['session_key']);
      }
    } catch (e) {
      inboundGroupSession.free();
      print(
          '[LibOlm] Could not create new InboundGroupSession: ' + e.toString());
      return;
    }
    if (!_inboundGroupSessions.containsKey(roomId)) {
      _inboundGroupSessions[roomId] = <String, SessionKey>{};
    }
    _inboundGroupSessions[roomId][sessionId] = SessionKey(
      content: content,
      inboundGroupSession: inboundGroupSession,
      indexes: {},
      key: client.userID,
    );
    client.database?.storeInboundGroupSession(
      client.id,
      roomId,
      sessionId,
      inboundGroupSession.pickle(client.userID),
      json.encode(content),
      json.encode({}),
    );
    // TODO: somehow try to decrypt last message again
    final room = client.getRoomById(roomId);
    if (room != null) {
      room.onSessionKeyReceived.add(sessionId);
    }
  }

  SessionKey getInboundGroupSession(
      String roomId, String sessionId, String senderKey,
      {bool otherRooms = true}) {
    if (_inboundGroupSessions.containsKey(roomId) &&
        _inboundGroupSessions[roomId].containsKey(sessionId)) {
      return _inboundGroupSessions[roomId][sessionId];
    }
    if (!otherRooms) {
      return null;
    }
    // search if this session id is *somehow* found in another room
    for (final val in _inboundGroupSessions.values) {
      if (val.containsKey(sessionId)) {
        return val[sessionId];
      }
    }
    return null;
  }

  /// Loads an inbound group session
  Future<SessionKey> loadInboundGroupSession(
      String roomId, String sessionId, String senderKey) async {
    if (roomId == null || sessionId == null || senderKey == null) {
      return null;
    }
    if (_inboundGroupSessions.containsKey(roomId) &&
        _inboundGroupSessions[roomId].containsKey(sessionId)) {
      return _inboundGroupSessions[roomId][sessionId]; // nothing to do
    }
    final session = await client.database
        ?.getDbInboundGroupSession(client.id, roomId, sessionId);
    if (session == null) {
      final room = client.getRoomById(roomId);
      final requestIdent = '$roomId|$sessionId|$senderKey';
      if (client.enableE2eeRecovery &&
          room != null &&
          !_requestedSessionIds.contains(requestIdent)) {
        // do e2ee recovery
        _requestedSessionIds.add(requestIdent);
        unawaited(request(room, sessionId, senderKey));
      }
      return null;
    }
    if (!_inboundGroupSessions.containsKey(roomId)) {
      _inboundGroupSessions[roomId] = <String, SessionKey>{};
    }
    final sess = SessionKey.fromDb(session, client.userID);
    if (!sess.isValid) {
      return null;
    }
    _inboundGroupSessions[roomId][sessionId] = sess;
    return sess;
  }

  /// clear all cached inbound group sessions. useful for testing
  void clearOutboundGroupSessions() {
    _outboundGroupSessions.clear();
  }

  /// Clears the existing outboundGroupSession but first checks if the participating
  /// devices have been changed. Returns false if the session has not been cleared because
  /// it wasn't necessary.
  Future<bool> clearOutboundGroupSession(String roomId,
      {bool wipe = false}) async {
    final room = client.getRoomById(roomId);
    final sess = getOutboundGroupSession(roomId);
    if (room == null || sess == null) {
      return true;
    }
    if (!wipe) {
      // first check if the devices in the room changed
      final deviceKeys = await room.getUserDeviceKeys();
      deviceKeys.removeWhere((k) => k.blocked);
      final deviceKeyIds = deviceKeys.map((k) => k.deviceId).toList();
      deviceKeyIds.sort();
      if (deviceKeyIds.toString() != sess.devices.toString()) {
        wipe = true;
      }
      // next check if it needs to be rotated
      final encryptionContent = room.getState(EventTypes.Encryption)?.content;
      final maxMessages = encryptionContent != null &&
              encryptionContent['rotation_period_msgs'] is int
          ? encryptionContent['rotation_period_msgs']
          : 100;
      final maxAge = encryptionContent != null &&
              encryptionContent['rotation_period_ms'] is int
          ? encryptionContent['rotation_period_ms']
          : 604800000; // default of one week
      if (sess.sentMessages >= maxMessages ||
          sess.creationTime
              .add(Duration(milliseconds: maxAge))
              .isBefore(DateTime.now())) {
        wipe = true;
      }
      if (!wipe) {
        return false;
      }
    }
    sess.dispose();
    _outboundGroupSessions.remove(roomId);
    await client.database?.removeOutboundGroupSession(client.id, roomId);
    return true;
  }

  Future<void> storeOutboundGroupSession(
      String roomId, OutboundGroupSession sess) async {
    if (sess == null) {
      return;
    }
    await client.database?.storeOutboundGroupSession(
        client.id,
        roomId,
        sess.outboundGroupSession.pickle(client.userID),
        json.encode(sess.devices),
        sess.creationTime,
        sess.sentMessages);
  }

  Future<OutboundGroupSession> createOutboundGroupSession(String roomId) async {
    await clearOutboundGroupSession(roomId, wipe: true);
    final room = client.getRoomById(roomId);
    if (room == null) {
      return null;
    }
    final deviceKeys = await room.getUserDeviceKeys();
    deviceKeys.removeWhere((k) => k.blocked);
    final deviceKeyIds = deviceKeys.map((k) => k.deviceId).toList();
    deviceKeyIds.sort();
    final outboundGroupSession = olm.OutboundGroupSession();
    try {
      outboundGroupSession.create();
    } catch (e) {
      outboundGroupSession.free();
      print('[LibOlm] Unable to create new outboundGroupSession: ' +
          e.toString());
      return null;
    }
    final rawSession = <String, dynamic>{
      'algorithm': 'm.megolm.v1.aes-sha2',
      'room_id': room.id,
      'session_id': outboundGroupSession.session_id(),
      'session_key': outboundGroupSession.session_key(),
    };
    setInboundGroupSession(
        roomId, rawSession['session_id'], encryption.identityKey, rawSession);
    final sess = OutboundGroupSession(
      devices: deviceKeyIds,
      creationTime: DateTime.now(),
      outboundGroupSession: outboundGroupSession,
      sentMessages: 0,
      key: client.userID,
    );
    try {
      await client.sendToDevice(deviceKeys, 'm.room_key', rawSession);
      await storeOutboundGroupSession(roomId, sess);
      _outboundGroupSessions[roomId] = sess;
    } catch (e, s) {
      print(
          '[LibOlm] Unable to send the session key to the participating devices: ' +
              e.toString());
      print(s);
      sess.dispose();
      return null;
    }
    return sess;
  }

  OutboundGroupSession getOutboundGroupSession(String roomId) {
    return _outboundGroupSessions[roomId];
  }

  Future<void> loadOutboundGroupSession(String roomId) async {
    if (_loadedOutboundGroupSessions.contains(roomId) ||
        _outboundGroupSessions.containsKey(roomId) ||
        client.database == null) {
      return; // nothing to do
    }
    _loadedOutboundGroupSessions.add(roomId);
    final session =
        await client.database.getDbOutboundGroupSession(client.id, roomId);
    if (session == null) {
      return;
    }
    final sess = OutboundGroupSession.fromDb(session, client.userID);
    if (!sess.isValid) {
      return;
    }
    _outboundGroupSessions[roomId] = sess;
  }

  Future<Map<String, dynamic>> getRoomKeysInfo() async {
    return await client.jsonRequest(
      type: RequestType.GET,
      action: '/client/r0/room_keys/version',
    );
  }

  Future<bool> isCached() async {
    if (!enabled) {
      return false;
    }
    return (await encryption.ssss.getCached(MEGOLM_KEY)) != null;
  }

  Future<void> loadFromResponse(Map<String, dynamic> payload) async {
    if (!(await isCached())) {
      return;
    }
    if (!(payload['rooms'] is Map)) {
      return;
    }
    final privateKey = base64.decode(await encryption.ssss.getCached(MEGOLM_KEY));
    final decryption = olm.PkDecryption();
    final info = await getRoomKeysInfo();
    String backupPubKey;
    try {
      backupPubKey = decryption.init_with_private_key(privateKey);

      if (backupPubKey == null ||
          !info.containsKey('auth_data') ||
          !(info['auth_data'] is Map) ||
          info['auth_data']['public_key'] != backupPubKey) {
        return;
      }
      for (final roomEntries in payload['rooms'].entries) {
        final roomId = roomEntries.key;
        if (!(roomEntries.value is Map) ||
            !(roomEntries.value['sessions'] is Map)) {
          continue;
        }
        for (final sessionEntries in roomEntries.value['sessions'].entries) {
          final sessionId = sessionEntries.key;
          final rawEncryptedSession = sessionEntries.value;
          if (!(rawEncryptedSession is Map)) {
            continue;
          }
          final firstMessageIndex =
              rawEncryptedSession['first_message_index'] is int
                  ? rawEncryptedSession['first_message_index']
                  : null;
          final forwardedCount = rawEncryptedSession['forwarded_count'] is int
              ? rawEncryptedSession['forwarded_count']
              : null;
          final isVerified = rawEncryptedSession['is_verified'] is bool
              ? rawEncryptedSession['is_verified']
              : null;
          final sessionData = rawEncryptedSession['session_data'];
          if (firstMessageIndex == null ||
              forwardedCount == null ||
              isVerified == null ||
              !(sessionData is Map)) {
            continue;
          }
          Map<String, dynamic> decrypted;
          try {
            decrypted = json.decode(decryption.decrypt(sessionData['ephemeral'],
                sessionData['mac'], sessionData['ciphertext']));
          } catch (err) {
            print('[LibOlm] Error decrypting room key: ' + err.toString());
          }
          if (decrypted != null) {
            decrypted['session_id'] = sessionId;
            decrypted['room_id'] = roomId;
            setInboundGroupSession(roomId, sessionId, decrypted['sender_key'], decrypted, forwarded: true);
          }
        }
      }
    } finally {
      decryption.free();
    }
  }

  Future<void> loadSingleKey(String roomId, String sessionId) async {
    final info = await getRoomKeysInfo();
    final ret = await client.jsonRequest(
      type: RequestType.GET,
      action:
          '/client/r0/room_keys/keys/${Uri.encodeComponent(roomId)}/${Uri.encodeComponent(sessionId)}?version=${info['version']}',
    );
    await loadFromResponse({
      'rooms': {
        roomId: {
          'sessions': {
            sessionId: ret,
          },
        },
      },
    });
  }

  /// Request a certain key from another device
  Future<void> request(Room room, String sessionId, String senderKey) async {
    // let's first check our online key backup store thingy...
    var hadPreviously = getInboundGroupSession(room.id, sessionId, senderKey) != null;
    try {
      await loadSingleKey(room.id, sessionId);
    } catch (err, stacktrace) {
      print('++++++++++++++++++');
      print(err.toString());
      print(stacktrace);
    }
    if (!hadPreviously && getInboundGroupSession(room.id, sessionId, senderKey) != null) {
      return; // we managed to load the session from online backup, no need to care about it now
    }
    // while we just send the to-device event to '*', we still need to save the
    // devices themself to know where to send the cancel to after receiving a reply
    final devices = await room.getUserDeviceKeys();
    final requestId = client.generateUniqueTransactionId();
    final request = KeyManagerKeyShareRequest(
      requestId: requestId,
      devices: devices,
      room: room,
      sessionId: sessionId,
      senderKey: senderKey,
    );
    await client.sendToDevice(
        [],
        'm.room_key_request',
        {
          'action': 'request',
          'body': {
            'algorithm': 'm.megolm.v1.aes-sha2',
            'room_id': room.id,
            'sender_key': senderKey,
            'session_id': sessionId,
          },
          'request_id': requestId,
          'requesting_device_id': client.deviceID,
        },
        encrypted: false,
        toUsers: await room.requestParticipants());
    outgoingShareRequests[request.requestId] = request;
  }

  /// Handle an incoming to_device event that is related to key sharing
  Future<void> handleToDeviceEvent(ToDeviceEvent event) async {
    if (event.type == 'm.room_key_request') {
      if (!event.content.containsKey('request_id')) {
        return; // invalid event
      }
      if (event.content['action'] == 'request') {
        // we are *receiving* a request
        if (!event.content.containsKey('body')) {
          return; // no body
        }
        if (!client.userDeviceKeys.containsKey(event.sender) ||
            !client.userDeviceKeys[event.sender].deviceKeys
                .containsKey(event.content['requesting_device_id'])) {
          return; // device not found
        }
        final device = client.userDeviceKeys[event.sender]
            .deviceKeys[event.content['requesting_device_id']];
        if (device.userId == client.userID &&
            device.deviceId == client.deviceID) {
          return; // ignore requests by ourself
        }
        final room = client.getRoomById(event.content['body']['room_id']);
        if (room == null) {
          return; // unknown room
        }
        final sessionId = event.content['body']['session_id'];
        final senderKey = event.content['body']['sender_key'];
        // okay, let's see if we have this session at all
        if ((await loadInboundGroupSession(room.id, sessionId, senderKey)) ==
            null) {
          return; // we don't have this session anyways
        }
        final request = KeyManagerKeyShareRequest(
          requestId: event.content['request_id'],
          devices: [device],
          room: room,
          sessionId: sessionId,
          senderKey: senderKey,
        );
        if (incomingShareRequests.containsKey(request.requestId)) {
          return; // we don't want to process one and the same request multiple times
        }
        incomingShareRequests[request.requestId] = request;
        final roomKeyRequest =
            RoomKeyRequest.fromToDeviceEvent(event, this, request);
        if (device.userId == client.userID &&
            device.verified &&
            !device.blocked) {
          // alright, we can forward the key
          await roomKeyRequest.forwardKey();
        } else {
          client.onRoomKeyRequest
              .add(roomKeyRequest); // let the client handle this
        }
      } else if (event.content['action'] == 'request_cancellation') {
        // we got told to cancel an incoming request
        if (!incomingShareRequests.containsKey(event.content['request_id'])) {
          return; // we don't know this request anyways
        }
        // alright, let's just cancel this request
        final request = incomingShareRequests[event.content['request_id']];
        request.canceled = true;
        incomingShareRequests.remove(request.requestId);
      }
    } else if (event.type == 'm.forwarded_room_key') {
      // we *received* an incoming key request
      if (event.encryptedContent == null) {
        return; // event wasn't encrypted, this is a security risk
      }
      final request = outgoingShareRequests.values.firstWhere(
          (r) =>
              r.room.id == event.content['room_id'] &&
              r.sessionId == event.content['session_id'] &&
              r.senderKey == event.content['sender_key'],
          orElse: () => null);
      if (request == null || request.canceled) {
        return; // no associated request found or it got canceled
      }
      final device = request.devices.firstWhere(
          (d) =>
              d.userId == event.sender &&
              d.curve25519Key == event.encryptedContent['sender_key'],
          orElse: () => null);
      if (device == null) {
        return; // someone we didn't send our request to replied....better ignore this
      }
      // TODO: verify that the keys work to decrypt a message
      // alright, all checks out, let's go ahead and store this session
      setInboundGroupSession(
          request.room.id, request.sessionId, request.senderKey, event.content,
          forwarded: true);
      request.devices.removeWhere(
          (k) => k.userId == device.userId && k.deviceId == device.deviceId);
      outgoingShareRequests.remove(request.requestId);
      // send cancel to all other devices
      if (request.devices.isEmpty) {
        return; // no need to send any cancellation
      }
      await client.sendToDevice(
          request.devices,
          'm.room_key_request',
          {
            'action': 'request_cancellation',
            'request_id': request.requestId,
            'requesting_device_id': client.deviceID,
          },
          encrypted: false);
    } else if (event.type == 'm.room_key') {
      if (event.encryptedContent == null) {
        return; // the event wasn't encrypted, this is a security risk;
      }
      final String roomId = event.content['room_id'];
      final String sessionId = event.content['session_id'];
      if (client.userDeviceKeys.containsKey(event.sender) &&
          client.userDeviceKeys[event.sender].deviceKeys
              .containsKey(event.content['requesting_device_id'])) {
        event.content['sender_claimed_ed25519_key'] = client
            .userDeviceKeys[event.sender]
            .deviceKeys[event.content['requesting_device_id']]
            .ed25519Key;
      }
      setInboundGroupSession(roomId, sessionId,
          event.encryptedContent['sender_key'], event.content,
          forwarded: false);
    }
  }

  void dispose() {
    for (final sess in _outboundGroupSessions.values) {
      sess.dispose();
    }
    for (final entries in _inboundGroupSessions.values) {
      for (final sess in entries.values) {
        sess.dispose();
      }
    }
  }
}

class KeyManagerKeyShareRequest {
  final String requestId;
  final List<DeviceKeys> devices;
  final Room room;
  final String sessionId;
  final String senderKey;
  bool canceled;

  KeyManagerKeyShareRequest(
      {this.requestId,
      this.devices,
      this.room,
      this.sessionId,
      this.senderKey,
      this.canceled = false});
}

class RoomKeyRequest extends ToDeviceEvent {
  KeyManager keyManager;
  KeyManagerKeyShareRequest request;
  RoomKeyRequest.fromToDeviceEvent(ToDeviceEvent toDeviceEvent,
      KeyManager keyManager, KeyManagerKeyShareRequest request) {
    this.keyManager = keyManager;
    this.request = request;
    sender = toDeviceEvent.sender;
    content = toDeviceEvent.content;
    type = toDeviceEvent.type;
  }

  Room get room => request.room;

  DeviceKeys get requestingDevice => request.devices.first;

  Future<void> forwardKey() async {
    if (request.canceled) {
      keyManager.incomingShareRequests.remove(request.requestId);
      return; // request is canceled, don't send anything
    }
    var room = this.room;
    final session = await keyManager.loadInboundGroupSession(
        room.id, request.sessionId, request.senderKey);
    var forwardedKeys = <dynamic>[keyManager.encryption.identityKey];
    for (final key in session.forwardingCurve25519KeyChain) {
      forwardedKeys.add(key);
    }
    var message = session.content;
    message['forwarding_curve25519_key_chain'] = forwardedKeys;

    message['session_key'] = session.inboundGroupSession
        .export_session(session.inboundGroupSession.first_known_index());
    // send the actual reply of the key back to the requester
    await keyManager.client.sendToDevice(
      [requestingDevice],
      'm.forwarded_room_key',
      message,
    );
    keyManager.incomingShareRequests.remove(request.requestId);
  }
}
