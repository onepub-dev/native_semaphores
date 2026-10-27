import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'native_semaphore.dart';
import 'semaphore_counter.dart';
import 'semaphore_identity.dart';
import 'ffi/windows.dart';

/// Uses native return values without GetLastError, which Dart FFI transitions
/// may clobber. Accurate error diagnostics require a native wrapper.
/// Wait classification uses the returned WAIT_* status.
class WindowsSemaphoreCalls {
  const WindowsSemaphoreCalls();
  int open(LPCWSTR name) {
    final handle = CreateSemaphoreW(0, 1, 1, name);
    if (handle != 0) return handle;
    throw StateError('CreateSemaphoreW failed');
  }

  bool wait(int handle, {required bool blocking}) {
    final result = WaitForSingleObject(handle,
        blocking ? WindowsWaitForSingleObjectMacros.TIMEOUT_RECOMMENDED : 0);
    if (result == WindowsWaitForSingleObjectMacros.WAIT_OBJECT_0) return true;
    if (result == WindowsWaitForSingleObjectMacros.WAIT_TIMEOUT) return false;
    throw StateError('WaitForSingleObject failed: status $result');
  }

  void post(int handle) {
    if (ReleaseSemaphore(handle, 1, WindowsReleaseSemaphoreMacros.NULL) != 0)
      return;
    throw StateError('ReleaseSemaphore failed');
  }

  void close(int handle) {
    if (CloseHandle(handle) != 0) return;
    throw StateError('CloseHandle failed');
  }
}

class WindowsSemaphore<
        I extends SemaphoreIdentity,
        IS extends SemaphoreIdentities<I>,
        CU extends SemaphoreCountUpdate,
        CD extends SemaphoreCountDeletion,
        CT extends SemaphoreCount<CU, CD>,
        CTS extends SemaphoreCounts<CU, CD, CT>,
        CTR extends SemaphoreCounter<I, CU, CD, CT, CTS>,
        CTRS extends SemaphoreCounters<I, CU, CD, CT, CTS, CTR>>
    extends NativeSemaphore<I, IS, CU, CD, CT, CTS, CTR, CTRS> {
  final WindowsSemaphoreCalls calls;
  LPCWSTR? _identifier;
  Pointer<NativeType>? _semaphore;
  ({bool isSet, LPCWSTR? get}) get identifier =>
      (isSet: _identifier != null, get: _identifier);
  ({bool isSet, Pointer<NativeType>? get}) get semaphore =>
      (isSet: _semaphore != null, get: _semaphore);
  WindowsSemaphore(
      {required super.name,
      required super.counter,
      super.verbose = false,
      this.calls = const WindowsSemaphoreCalls()});
  @override
  bool open() {
    if (closed)
      throw StateError(
          'Closed semaphores cannot be reopened; instantiate again.');
    if (opened) return true;
    if (!willAttemptOpen()) return false;
    SemaphoreIdentity(name: name);
    if (identity.name != name ||
        name.length > WindowsCreateSemaphoreWMacros.MAX_PATH) {
      throw ArgumentError('Semaphore identity mismatch or name too long.');
    }
    final pointer = 'Global\\$name'.toNativeUtf16();
    _identifier = pointer;
    try {
      _semaphore = Pointer.fromAddress(calls.open(pointer));
      identity.address = _semaphore!.address;
      hasOpened = true;
      return true;
    } finally {
      _identifier = null;
      malloc.free(pointer);
    }
  }

  @override
  bool lockAcrossProcesses({bool blocking = true, Duration? timeout}) {
    if (!opened) throw StateError('Semaphore is not open.');
    if (counter.counts.process.get() != 0 || !willAttemptLockAcrossProcesses())
      return false;
    if (!calls.wait(_semaphore!.address, blocking: blocking)) return false;
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
    calls.post(_semaphore!.address);
    counter.counts.process.decrement();
    return true;
  }

  @override
  bool close() {
    if (closed) return true;
    if (locked || !willAttemptClose()) return false;
    if (opened) calls.close(_semaphore!.address);
    _semaphore = null;
    markClosed();
    return true;
  }

  /// Windows deletes the kernel object after all handles close.
  @override
  bool unlink() {
    if (unlinked) return true;
    if (!closed || locked || !willAttemptUnlink()) return false;
    hasUnlinked = true;
    return true;
  }

  @override
  String toString() => 'WindowsSemaphore(name: $name)';
}
