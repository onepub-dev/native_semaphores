import 'dart:convert';
import 'dart:io';

import 'package:runtime_native_semaphores/runtime_native_semaphores.dart';

// A line protocol lets the parent prove contention without timing assumptions.
Future<void> main(List<String> args) async {
  final sem = NativeSemaphore.instantiate(name: args.single);
  if (!sem.open()) throw StateError('Child failed to open');
  stdout.writeln('ready');
  var failed = false;
  try {
    await for (final command in stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .timeout(const Duration(seconds: 10))) {
      switch (command) {
        case 'try':
          stdout.writeln(sem.lock(blocking: false) ? 'acquired' : 'contended');
        case 'release':
          if (!sem.unlock()) throw StateError('Child failed to release');
          stdout.writeln('released');
        case 'close':
          return;
        default:
          throw ArgumentError('Unknown command: $command');
      }
    }
  } catch (_) {
    failed = true;
    rethrow;
  } finally {
    try {
      if (sem.locked && !sem.unlock()) {
        throw StateError('Child failed to release its acquisition');
      }
      if (sem.locked)
        throw StateError('Child retained ownership after release');
      if (!sem.close()) throw StateError('Child failed to close');
    } catch (_) {
      // Keep a protocol failure's original stack if cleanup also fails.
      if (!failed) rethrow;
    }
    // Only the parent unlinks, after every child has exited.
  }
}
