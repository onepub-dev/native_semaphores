import 'package:runtime_native_semaphores/runtime_native_semaphores.dart';
import 'package:safe_int_id/safe_int_id.dart';
import 'package:test/test.dart';

import 'support/semaphore_workers.dart';

void main() {
  group('Reentrant semaphore lifecycle', () {
    for (final depth in [1, 4]) {
      test('Depth $depth closes terminally and yields a fresh wrapper', () {
        final name = '${safeIntId.getId()}_named_sem';
        final sem = NativeSemaphore.instantiate(name: name);
        expect(sem.opened, isFalse);
        expect(sem.open(), isTrue);
        try {
          for (var level = 0; level < depth; level++) {
            expect(NativeSemaphore.instantiate(name: name), same(sem));
            expect(sem.open(), isTrue);
            expect(sem.lock(blocking: false), isTrue);
            expect(sem.counter.counts.process.get(), 1);
            expect(sem.counter.counts.isolate.get(), level);
          }
          for (var remaining = depth - 1; remaining >= 0; remaining--) {
            expect(sem.unlock(), isTrue);
            expect(sem.locked, remaining > 0);
            expect(sem.close(), remaining == 0);
            // No peer exists in this single-isolate test.
            expect(sem.unlink(), remaining == 0);
          }
          expect(sem.closed, isTrue);
          expect(sem.unlinked, isTrue);

          final replacement = NativeSemaphore.instantiate(name: name);
          expect(replacement, isNot(same(sem)));
          expect(replacement.counter, isNot(same(sem.counter)));
          expect(replacement.counter.counts.process.get(), 0);
          expect(replacement.counter.counts.isolate.get(), 0);
          expect(replacement.locked, isFalse);
          expect(replacement.opened, isFalse);
          expect(replacement.closed, isFalse);
          expect(replacement.unlinked, isFalse);
          expect(replacement.open(), isTrue);
          try {
            expect(replacement.lock(blocking: false), isTrue);
            expect(replacement.unlock(), isTrue);
          } finally {
            if (replacement.locked) {
              expect(replacement.unlock(), isTrue);
            }
            expect(replacement.locked, isFalse);
            replacement.close();
            replacement.unlink();
          }
        } finally {
          for (var releases = 0; releases < depth && sem.locked; releases++) {
            expect(sem.unlock(), isTrue);
          }
          expect(sem.locked, isFalse);
          sem.close();
          sem.unlink();
        }
      });
    }

    test('Reentrant behavior across several isolates', () async {
      await exerciseIsolateWorkers(depth: 4);
    });
  });
}
