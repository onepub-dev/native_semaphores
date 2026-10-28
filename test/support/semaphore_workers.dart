import 'dart:isolate';

import 'package:runtime_native_semaphores/runtime_native_semaphores.dart';
import 'package:safe_int_id/safe_int_id.dart';
import 'package:test/test.dart';

Future<void> exerciseIsolateWorkers({required int depth}) async {
  final name = '${safeIntId.getId()}_named_sem';
  // Keep the name alive on Windows until all workers have closed their handles.
  final coordinator = NativeSemaphore.instantiate(name: name)..open();
  try {
    // Isolate.run forwards failures and completes after its isolate exits.
    // Future.wait waits for every worker even when one reports an error.
    await Future.wait(List.generate(4, (_) => _spawnWorker(name, depth)));
  } finally {
    expect(coordinator.close(), isTrue);
    // Every worker has exited, so the coordinator can safely remove the name.
    expect(coordinator.unlink(), isTrue);
  }
}

// A separate scope prevents the closure from capturing the coordinator's
// unsendable native wrapper along with the worker arguments.
Future<void> _spawnWorker(String name, int depth) => Isolate.run(() async {
      void require(bool condition, String message) {
        if (!condition) throw StateError(message);
      }

      final sem = NativeSemaphore.instantiate(name: name);
      require(sem.open(), 'Worker failed to open');
      try {
        final deadline = Stopwatch()..start();
        while (!sem.lock(blocking: false)) {
          if (deadline.elapsed > const Duration(seconds: 10)) {
            throw StateError('Timed out acquiring $name');
          }
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        for (var level = 1; level < depth; level++) {
          require(sem.lock(blocking: false), 'Worker failed to recurse');
          require(sem.counter.counts.process.get() == 1,
              'Worker process count must stay at one');
          require(sem.counter.counts.isolate.get() == level,
              'Worker recursion count must match its depth');
        }
        for (var remaining = depth - 1; remaining >= 0; remaining--) {
          require(sem.unlock(), 'Worker failed to unlock');
          require(sem.locked == (remaining > 0),
              'Worker ownership must match remaining depth');
          require(sem.close() == (remaining == 0),
              'Worker must close only after the outermost release');
        }
      } finally {
        for (var releases = 0; releases < depth && sem.locked; releases++) {
          require(sem.unlock(), 'Worker failed to release during cleanup');
        }
        require(!sem.locked, 'Worker retained ownership after cleanup');
        sem.close();
        // Workers never unlink: other workers may still be using this name.
      }
    });
