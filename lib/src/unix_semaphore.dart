import 'dart:convert' show utf8;
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'native_semaphore.dart';
import 'semaphore_counter.dart';
import 'semaphore_identity.dart';
import 'ffi/unix.dart';

/// Native operations are separate so failure paths can be tested safely.
/// TODO: Capture result and errno together in a native wrapper. Reading errno
/// after a Dart FFI transition is not guaranteed to preserve the native error;
/// this affects open diagnostics, wait contention classification, and unlink.
/// The current Dart-side reads are not a robust error-capture solution.
class UnixSemaphoreCalls {
  const UnixSemaphoreCalls();
  Pointer<sem_t> open(Pointer<Char> name) {
    final result = sem_open(name, UnixSemOpenMacros.O_CREAT,
        MODE_T_PERMISSIONS.RECOMMENDED, UnixSemOpenMacros.VALUE_RECOMMENDED);
    if (result.address == UnixSemOpenMacros.SEM_FAILED.address) {
      final error = errno.value;
      throw StateError('sem_open failed: errno $error');
    }
    return result;
  }

  bool wait(Pointer<sem_t> handle, {required bool blocking}) {
    final result = blocking ? sem_wait(handle) : sem_trywait(handle);
    if (result == 0) return true;
    final error = errno.value;
    if (!blocking && error == UnixSemWaitOrTryWaitMacros.EAGAIN) return false;
    // EINTR is reported distinctly from ordinary contention.
    throw StateError('Semaphore wait failed: errno $error');
  }

  void post(Pointer<sem_t> handle) {
    if (sem_post(handle) == 0) return;
    final error = errno.value;
    throw StateError('sem_post failed: errno $error');
  }

  void close(Pointer<sem_t> handle) {
    if (sem_close(handle) == 0) return;
    final error = errno.value;
    throw StateError('sem_close failed: errno $error');
  }

  void unlink(Pointer<Char> name) {
    if (sem_unlink(name) == 0) return;
    final error = errno.value;
    if (error == UnixSemUnlinkMacros.ENOENT) return;
    throw StateError('sem_unlink failed: errno $error');
  }
}

class UnixSemaphore<
        I extends SemaphoreIdentity,
        IS extends SemaphoreIdentities<I>,
        CU extends SemaphoreCountUpdate,
        CD extends SemaphoreCountDeletion,
        CT extends SemaphoreCount<CU, CD>,
        CTS extends SemaphoreCounts<CU, CD, CT>,
        CTR extends SemaphoreCounter<I, CU, CD, CT, CTS>,
        CTRS extends SemaphoreCounters<I, CU, CD, CT, CTS, CTR>>
    extends NativeSemaphore<I, IS, CU, CD, CT, CTS, CTR, CTRS> {
  final UnixSemaphoreCalls calls;
  Pointer<Char>? _identifier;
  Pointer<sem_t>? _semaphore;
  ({bool isSet, Pointer<Char>? get}) get identifier =>
      (isSet: _identifier != null, get: _identifier);
  ({bool isSet, Pointer<sem_t>? get}) get semaphore =>
      (isSet: _semaphore != null, get: _semaphore);
  UnixSemaphore(
      {required super.name,
      required super.counter,
      super.verbose = false,
      this.calls = const UnixSemaphoreCalls()});

  T _withName<T>(T Function(Pointer<Char>) action) {
    SemaphoreIdentity(name: name);
    if (identity.name != name ||
        utf8.encode('/$name').length > UnixSemLimits.NAME_MAX_CHARACTERS) {
      throw ArgumentError(
          'Semaphore identity mismatch or encoded name too long.');
    }
    final pointer = '/$name'.toNativeUtf8().cast<Char>();
    _identifier = pointer;
    try {
      return action(pointer);
    } finally {
      _identifier = null;
      malloc.free(pointer);
    }
  }

  @override
  bool open() {
    if (closed)
      throw StateError(
          'Closed semaphores cannot be reopened; instantiate again.');
    if (opened) return true;
    if (!willAttemptOpen()) return false;
    _semaphore = _withName(calls.open);
    identity.address = _semaphore!.address;
    hasOpened = true;
    return true;
  }

  @override
  bool lockAcrossProcesses({bool blocking = true, Duration? timeout}) {
    if (!opened) throw StateError('Semaphore is not open.');
    if (counter.counts.process.get() != 0 || !willAttemptLockAcrossProcesses())
      return false;
    if (!calls.wait(_semaphore!, blocking: blocking)) return false;
    counter.counts.process.increment();
    return true;
  }

  @override
  bool unlockAcrossProcesses() {
    if (!opened ||
        counter.counts.process.get() <= 0 ||
        counter.counts.isolate.get() != 0) {
      throw StateError('Semaphore has no releasable outer acquisition.');
    }
    if (!willAttemptUnlockAcrossProcesses()) return false;
    calls.post(_semaphore!);
    counter.counts.process.decrement();
    return true;
  }

  @override
  bool close() {
    if (closed) return true;
    if (locked || !willAttemptClose()) return false;
    if (opened) calls.close(_semaphore!);
    _semaphore = null;
    markClosed();
    return true;
  }

  /// Deletes the global name. Caller must first establish global quiescence.
  /// Close alone never unlinks, and no finalizer unlinks the shared name.
  @override
  bool unlink() {
    if (unlinked) return true;
    if (!closed || locked || !willAttemptUnlink()) return false;
    _withName(calls.unlink);
    hasUnlinked = true;
    return true;
  }

  @override
  String toString() => 'UnixSemaphore(name: $name)';
}
