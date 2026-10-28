import 'dart:async';
import 'dart:isolate';

import 'package:runtime_native_semaphores/runtime_native_semaphores.dart';
import 'package:safe_int_id/safe_int_id.dart';
import 'package:test/test.dart';

import 'cleanup.dart';

const _deadline = Duration(seconds: 10);

class _Worker {
  final ReceivePort replies = ReceivePort();
  late final StreamIterator<dynamic> messages = StreamIterator(replies);
  late final Future<void> completion;
  SendPort? commands;
  Object? failure;
  StackTrace? trace;

  _Worker(String name, int depth) {
    completion = _spawnWorker(name, depth, replies.sendPort).then((_) {},
        onError: (Object error, StackTrace stack) {
      failure = error;
      trace = stack;
    });
  }

  Future<dynamic> next() async {
    if (!await messages.moveNext().timeout(_deadline)) {
      throw StateError('Worker closed its reply port');
    }
    return messages.current;
  }

  Future<void> start() async {
    commands = await next() as SendPort;
  }

  Future<String> command(String command) async {
    commands!.send(command);
    return await next() as String;
  }

  Future<void> stop() async {
    commands?.send('close');
    // Worker command waits are bounded too, including failed handshakes.
    await completion;
    await messages.cancel();
    replies.close();
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  }
}

Future<void> exerciseIsolateWorkers({required int depth}) async {
  final name = '${safeIntId.getId()}_named_sem';
  final coordinator = NativeSemaphore.instantiate(name: name);
  expect(coordinator.open(), isTrue);
  final workers = <_Worker>[];
  var joined = false;
  var occupancy = 0;
  await withCleanup(() async {
    expect(coordinator.lock(blocking: false), isTrue);
    occupancy++;
    for (var index = 0; index < 4; index++) {
      final worker = _Worker(name, depth);
      workers.add(worker);
      await worker.start();
      expect(await worker.command('try'), 'contended');
    }
    expect(coordinator.unlock(), isTrue);
    occupancy--;
    for (final owner in workers) {
      expect(await owner.command('try'), 'acquired');
      expect(++occupancy, 1);
      // Owner holds its acquisition pending the parent's release command.
      for (final peer in workers.where((peer) => peer != owner)) {
        final response = await peer.command('try');
        if (response == 'acquired') occupancy++;
        expect(occupancy, 1,
            reason: 'Two isolates entered the critical section');
        expect(response, 'contended');
      }
      expect(coordinator.lock(blocking: false), isFalse);
      expect(await owner.command('release'), 'released');
      expect(--occupancy, 0);
    }
  }, [
    () async {
      await Future.wait(workers.map((worker) => worker.stop()));
      joined = true;
    },
    () async {
      if (coordinator.locked) expect(coordinator.unlock(), isTrue);
      expect(coordinator.locked, isFalse);
      expect(coordinator.close(), isTrue);
    },
    () async {
      if (joined) expect(coordinator.unlink(), isTrue);
    }
  ]);
}

// Capture only sendable arguments, never a parent native wrapper.
Future<void> _spawnWorker(String name, int depth, SendPort replies) =>
    Isolate.run(() async {
      void require(bool condition, String message) {
        if (!condition) throw StateError(message);
      }

      final commands = ReceivePort();
      final sem = NativeSemaphore.instantiate(name: name);
      require(sem.open(), 'Worker failed to open');
      await withCleanup(() async {
        replies.send(commands.sendPort);
        await for (final command in commands.timeout(_deadline)) {
          switch (command) {
            case 'try':
              require(!sem.locked, 'Worker already owns the semaphore');
              if (!sem.lock(blocking: false)) {
                replies.send('contended');
                continue;
              }
              for (var level = 1; level < depth; level++) {
                require(sem.lock(blocking: false), 'Worker failed to recurse');
                require(sem.counter.counts.process.get() == 1,
                    'Worker process count must stay at one');
                require(sem.counter.counts.isolate.get() == level,
                    'Worker recursion count must match its depth');
              }
              replies.send('acquired');
            case 'release':
              for (var remaining = depth - 1; remaining >= 0; remaining--) {
                require(sem.unlock(), 'Worker failed to unlock');
                require(sem.locked == (remaining > 0),
                    'Worker ownership must match remaining depth');
                if (remaining > 0) {
                  require(!sem.close(), 'Worker closed while still owning');
                }
              }
              replies.send('released');
            case 'close':
              return;
            default:
              throw StateError('Unknown worker command: $command');
          }
        }
      }, [
        () async {
          commands.close();
          for (var releases = 0; releases < depth && sem.locked; releases++) {
            require(sem.unlock(), 'Worker failed to release during cleanup');
          }
          require(!sem.locked, 'Worker retained ownership after cleanup');
        },
        () async {
          require(sem.close(), 'Worker failed to close');
          // Only the parent unlinks after all worker futures complete.
        }
      ]);
    });
