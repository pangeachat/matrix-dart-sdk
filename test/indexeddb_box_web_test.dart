@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:test/test.dart';
import 'package:web/web.dart';

import 'package:matrix/src/database/indexeddb_box.dart';

/// When a transaction aborts, every pending request fires an error event that
/// bubbles to the transaction and then to the database. A handler there that
/// completes a completer must tolerate being called once per request.
void main() {
  group('IndexedDB error events', () {
    const boxNames = {'cats', 'dogs'};
    late String dbName;
    late BoxCollection collection;
    late List<String> handlerErrors;
    late List<Object> zoneErrors;

    setUp(() async {
      // A fresh name, so the open runs onupgradeneeded and installs its
      // database-level error handler.
      dbName =
          'indexeddb_box_web_test_${DateTime.now().microsecondsSinceEpoch}';
      late IDBOpenDBRequest openRequest;
      final factory = <String, Object>{}.jsify()! as JSObject;
      factory.setProperty(
        'open'.toJS,
        ((String name, int version) {
          return openRequest = window.indexedDB.open(name, version);
        }).toJS,
      );
      collection = await BoxCollection.open(
        dbName,
        boxNames,
        idbFactory: factory as IDBFactory,
      );

      // Abort every transaction on this database right after the box has
      // issued its requests.
      final db = openRequest.result! as IDBDatabase;
      final transaction = db.getProperty<JSFunction>('transaction'.toJS);
      db.setProperty(
        'transaction'.toJS,
        ((JSAny? stores, JSAny? mode) {
          final txn =
              transaction.callAsFunction(db, stores, mode)! as IDBTransaction;
          scheduleMicrotask(() => txn.abort());
          return txn;
        }).toJS,
      );
      addTearDown(() => collection.deleteDatabase(dbName));

      // An exception thrown inside an IDB event handler surfaces only as a
      // window error event.
      handlerErrors = [];
      final onError = ((ErrorEvent event) {
        handlerErrors.add('${event.message} ${event.error}');
      }).toJS;
      window.addEventListener('error', onError);
      addTearDown(() => window.removeEventListener('error', onError));

      zoneErrors = [];
    });

    Future<void> expectRejectedOnce(Future<void> Function() run) async {
      Object? rejection;
      await runZonedGuarded(
        () async {
          try {
            await run();
          } catch (e) {
            rejection = e;
          }
          // Let the remaining error events of the aborted transaction fire.
          await Future<void>.delayed(const Duration(milliseconds: 50));
        },
        (error, _) => zoneErrors.add(error),
      );
      expect(rejection, isNotNull);
      expect(handlerErrors, isEmpty);
      expect(zoneErrors.whereType<StateError>(), isEmpty);
    }

    test('aborted transaction with several writes', () async {
      final box = collection.openBox<Map>('cats');
      await expectRejectedOnce(
        () => collection.transaction(() async {
          await box.put('fluffy', {'name': 'Fluffy'});
          await box.put('loki', {'name': 'Loki'});
        }),
      );
    });

    test('aborted clear of several boxes', () async {
      await expectRejectedOnce(collection.clear);
    });
  });
}
