import 'dart:convert';
import 'dart:io';

import 'package:runtime_native_semaphores/runtime_native_semaphores.dart';

// A line protocol lets the parent prove contention without timing assumptions.
Future<void> main(List<String> args) async {
  final sem = NativeSemaphore.instantiate(name: args.single)..open();
  stdout.writeln('ready');
  try {
    await for (final command in stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .timeout(const Duration(seconds: 10))) {
      switch (command) {
        case 'try':
          stdout.writeln(sem.lock(blocking: false) ? 'acquired' : 'contended');
        case 'release':
          sem.unlock();
          stdout.writeln('released');
        case 'close':
          return;
        default:
          throw ArgumentError('Unknown command: $command');
      }
    }
  } finally {
    if (sem.locked && !sem.unlock()) {
      throw StateError('Child failed to release its acquisition');
    }
    if (sem.locked) throw StateError('Child retained ownership after release');
    sem.close();
    // Only the parent unlinks, after every child has exited.
  }
}
