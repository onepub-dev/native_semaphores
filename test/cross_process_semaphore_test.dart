import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:runtime_native_semaphores/runtime_native_semaphores.dart';
import 'package:safe_int_id/safe_int_id.dart';
import 'package:test/test.dart';

import 'support/cleanup.dart';

class _Worker {
  final Process process;
  final StreamIterator<String> lines;
  final Future<String> errors;

  _Worker(this.process)
      : lines = StreamIterator(process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())),
        errors = process.stderr.transform(utf8.decoder).join();

  Future<void> expectLine(String expected) async {
    expect(await lines.moveNext().timeout(const Duration(seconds: 10)), isTrue);
    expect(lines.current, expected);
  }

  Future<void> command(String command, String expected) async {
    process.stdin.writeln(command);
    await process.stdin.flush();
    await expectLine(expected);
  }

  Future<void> close() async {
    process.stdin.writeln('close');
    await process.stdin.close();
    expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0,
        reason: await errors);
  }

  Future<void> stop() async {
    process.kill();
    await process.exitCode.timeout(const Duration(seconds: 10));
    await lines.cancel();
  }
}

void main() {
  late Directory temporary;
  late String executable;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('semaphore_test_');
    addTearDown(() => temporary.delete(recursive: true));
    executable = '${temporary.path}/primary${Platform.isWindows ? '.exe' : ''}';
    // Compile the current source every run; never reuse an old checked-out binary.
    final compiler = await Process.start(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'bin/test/primary_semaphore.dart',
      '-o',
      executable
    ]);
    final output = compiler.stdout.transform(utf8.decoder).join();
    final errors = compiler.stderr.transform(utf8.decoder).join();
    try {
      final exitCode =
          await compiler.exitCode.timeout(const Duration(seconds: 20));
      expect(exitCode, 0, reason: '${await output}\n${await errors}');
    } finally {
      compiler.kill();
      await compiler.exitCode.timeout(const Duration(seconds: 5));
    }
  });

  test('Processes contend on the same name until all handles close', () async {
    final name = '${safeIntId.getId()}_named_sem';
    final sem = NativeSemaphore.instantiate(name: name);
    expect(sem.open(), isTrue);
    final workers = <_Worker>[];
    var joined = false;
    await withCleanup(() async {
      expect(sem.lock(blocking: false), isTrue);
      for (var i = 0; i < 2; i++) {
        final worker = _Worker(await Process.start(executable, [name]));
        workers.add(worker);
        await worker.expectLine('ready');
        await worker.command('try', 'contended');
      }
      expect(sem.unlock(), isTrue);
      await workers.first.command('try', 'acquired');
      await workers.last.command('try', 'contended');
      await workers.first.command('release', 'released');
      await workers.first.close();
      await workers.last.command('try', 'acquired');
      expect(sem.lock(blocking: false), isFalse);
      await workers.last.command('release', 'released');
      await workers.last.close();
      expect(sem.lock(blocking: false), isTrue);
      expect(sem.unlock(), isTrue);
    }, [
      () async {
        // On failures, terminate and join workers before removing the shared name.
        await Future.wait(workers.map((worker) => worker.stop()));
        joined = true;
      },
      () async {
        if (sem.locked) {
          expect(sem.unlock(), isTrue);
        }
        expect(sem.locked, isFalse);
      },
      () async {
        expect(sem.close(), isTrue);
      },
      () async {
        if (joined) expect(sem.unlink(), isTrue);
      }
    ]);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('Retained retired state cannot bypass a replacement native wait',
      () async {
    final name = '${safeIntId.getId()}_named_sem';
    final old = NativeSemaphore.instantiate(name: name);
    expect(old.open(), isTrue);
    final workers = <_Worker>[];
    var joined = false;
    NativeSemaphore current = old;
    await withCleanup(() async {
      final worker = _Worker(await Process.start(executable, [name]));
      workers.add(worker);
      await worker.expectLine('ready');
      await worker.command('try', 'acquired');
      expect(old.close(), isTrue);
      NativeSemaphores().delete(name: name);
      final replacement = NativeSemaphore.instantiate(name: name);
      current = replacement;
      expect(replacement.identity, isNot(same(old.identity)));
      expect(replacement.counter, isNot(same(old.counter)));
      old.counter.counts.process.increment();
      old.counter.counts.isolate.increment();
      expect(replacement.counter.counts.process.get(), 0);
      expect(replacement.counter.counts.isolate.get(), 0);
      expect(replacement.open(), isTrue);
      expect(replacement.lock(blocking: false), isFalse);
      expect(replacement.locked, isFalse);
      await worker.command('release', 'released');
      expect(replacement.lock(blocking: false), isTrue);
      expect(replacement.unlock(), isTrue);
      await worker.close();
    }, [
      () async {
        await Future.wait(workers.map((worker) => worker.stop()));
        joined = true;
      },
      () async {
        if (current.locked) expect(current.unlock(), isTrue);
        expect(current.locked, isFalse);
      },
      () async {
        expect(current.close(), isTrue);
      },
      () async {
        if (joined) expect(current.unlink(), isTrue);
      }
    ]);
  }, timeout: const Timeout(Duration(seconds: 90)));
}
