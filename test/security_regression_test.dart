import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:runtime_native_semaphores/runtime_native_semaphores.dart';
import 'package:test/test.dart';

int serial = 0;
String freshName() =>
    'sec${pid}_${DateTime.now().microsecondsSinceEpoch % 1000000000}_${serial++}';

class FakeState {
  int opens = 0;
  int waits = 0;
  int posts = 0;
  int closes = 0;
  int unlinks = 0;
  bool contend = true;
  bool failOpen = false;
  bool failWait = false;
  bool failNonblockingUnixWait = false;
  bool failPost = false;
  bool failClose = false;
  bool failUnlink = false;
  void open() {
    opens++;
    if (failOpen) throw StateError('open failure');
  }

  bool wait({bool nonblockingUnix = false}) {
    waits++;
    // Model the POSIX adapter's return-value-only contract: any nonzero
    // sem_trywait result is false, even if the native cause was not contention.
    if (nonblockingUnix && failNonblockingUnixWait) return false;
    if (failWait) throw StateError('wait failure');
    return !contend;
  }

  void post() {
    if (failPost) throw StateError('post failure');
    posts++;
  }

  void close() {
    if (failClose) throw StateError('close failure');
    closes++;
  }
}

class FakeUnix extends UnixSemaphoreCalls {
  final FakeState state;
  FakeUnix(this.state);
  @override
  Pointer<sem_t> open(Pointer<Char> name) {
    expect(name.cast<Utf8>().toDartString(), startsWith('/sec'));
    state.open();
    return Pointer.fromAddress(123);
  }

  @override
  bool wait(Pointer<sem_t> handle, {required bool blocking}) =>
      state.wait(nonblockingUnix: !blocking);
  @override
  void post(Pointer<sem_t> handle) => state.post();
  @override
  void close(Pointer<sem_t> handle) => state.close();
  @override
  void unlink(Pointer<Char> name) {
    state.unlinks++;
    if (state.failUnlink) throw StateError('unlink failure');
  }
}

class FakeWindows extends WindowsSemaphoreCalls {
  final FakeState state;
  FakeWindows(this.state);
  @override
  int open(LPCWSTR name) {
    expect(name.toDartString(), startsWith('Global\\sec'));
    state.open();
    return 123;
  }

  @override
  bool wait(int handle, {required bool blocking}) => state.wait();
  @override
  void post(int handle) => state.post();
  @override
  void close(int handle) => state.close();
}

CTR makeCounter(String name) =>
    SemaphoreCounter.instantiate(identity: SemaphoreIdentity(name: name));

bool hasName(NS sem) => sem is UnixSemaphore
    ? sem.identifier.isSet
    : (sem as WindowsSemaphore).identifier.isSet;
bool hasHandle(NS sem) => sem is UnixSemaphore
    ? sem.semaphore.isSet
    : (sem as WindowsSemaphore).semaphore.isSet;
NS fake(bool windows, FakeState state, [String? requestedName]) {
  final name = requestedName ?? freshName();
  final counter = makeCounter(name);
  return windows
      ? WindowsSemaphore(
          name: name, counter: counter, calls: FakeWindows(state))
      : UnixSemaphore(name: name, counter: counter, calls: FakeUnix(state));
}

void main() {
  final workerName = Platform.environment['SEMAPHORE_SECURITY_WORKER'];
  if (workerName != null) {
    test('native worker', () {
      final sem = NativeSemaphore.instantiate(name: workerName);
      try {
        expect(sem.open(), isTrue);
        final acquired = sem.lock(blocking: false);
        expect(acquired,
            Platform.environment['SEMAPHORE_EXPECT_ACQUIRED'] == 'true');
        if (acquired) expect(sem.unlock(), isTrue);
      } finally {
        sem.close();
      }
    });
    return;
  }
  for (final windows in [false, true]) {
    group(windows ? 'Windows adapter' : 'Unix adapter', () {
      test('factory preserves active ownership and replaces retired state', () {
        final name = freshName();
        final state = FakeState()..contend = false;
        final identity = SemaphoreIdentity.instantiate(name: name);
        final counter = SemaphoreCounter.instantiate(identity: identity);
        final NS sem = windows
            ? WindowsSemaphore(
                name: name, counter: counter, calls: FakeWindows(state))
            : UnixSemaphore(
                name: name, counter: counter, calls: FakeUnix(state));
        NativeSemaphores().register(name: name, semaphore: sem);
        expect(NativeSemaphore.instantiate(name: name), same(sem));
        sem.open();
        sem.lock(blocking: false);
        sem.lock(blocking: false);
        expect(sem.close(), isFalse);
        expect(NativeSemaphore.instantiate(name: name), same(sem));
        expect(sem.counter.counts.isolate.get(), 1);
        sem.unlock();
        sem.unlock();
        state.failClose = true;
        expect(sem.close, throwsStateError);
        expect(NativeSemaphore.instantiate(name: name), same(sem));
        state.failClose = false;
        sem.close();
        expect(() => NativeSemaphore.instantiate(name: name, counter: counter),
            throwsArgumentError);
        expect(
            () => NativeSemaphore.instantiate(name: name, identity: identity),
            throwsArgumentError);
        final fresh = NativeSemaphore.instantiate(name: name);
        expect(fresh, isNot(same(sem)));
        expect(fresh.counter, isNot(same(counter)));
        expect(fresh.identity, isNot(same(identity)));
        expect(SemaphoreIdentity.instantiate(name: name), same(fresh.identity));
        expect(SemaphoreCounter.instantiate(identity: fresh.identity),
            same(fresh.counter));
        expect(fresh.opened, isFalse);
        expect(fresh.closed, isFalse);
        expect(fresh.unlinked, isFalse);
        // Prove the new write-once address is not the retired native handle.
        fresh.identity.address = 456;
        expect(fresh.identity.address, 456);
        expect(identity.address, 123);
        counter.counts.process.increment();
        counter.counts.isolate.increment();
        expect(fresh.counter.counts.process.get(), 0);
        expect(fresh.counter.counts.isolate.get(), 0);
        counter.counts.process.decrement();
        counter.counts.isolate.decrement();
        fresh.close();
        expect(NativeSemaphore.instantiate(name: name), isNot(same(fresh)));
        expect(state.unlinks, 0);
      });
      test('contention, adapter exception, recursion and guarded release', () {
        final state = FakeState();
        final sem = fake(windows, state);
        expect(sem.unlock, throwsStateError);
        expect(sem.open(), isTrue);
        expect(sem.open(), isTrue);
        expect(state.opens, 1);
        expect(sem.unlock, throwsStateError);
        expect(sem.lock(blocking: false), isFalse);
        expect(sem.counter.counts.process.get(), 0);
        expect(sem.counter.counts.isolate.get(), 0);
        state.failWait = true;
        expect(() => sem.lock(blocking: false), throwsStateError);
        expect(sem.locked, isFalse);
        state.failWait = false;
        state.contend = false;
        expect(sem.lock(blocking: false), isTrue);
        expect(sem.lock(blocking: false), isTrue);
        expect(sem.reentrant, isTrue);
        expect(sem.close(), isFalse);
        expect(sem.unlock(), isTrue);
        expect(state.posts, 0);
        state.failPost = true;
        expect(sem.unlock, throwsStateError);
        expect(sem.counter.counts.process.get(), 1);
        state.failPost = false;
        expect(sem.unlock(), isTrue);
        expect(state.posts, 1);
        expect(sem.unlock, throwsStateError);
        state.failClose = true;
        expect(sem.close, throwsStateError);
        expect(sem.opened, isTrue);
        state.failClose = false;
        expect(sem.close(), isTrue);
        expect(sem.close(), isTrue);
        expect(state.closes, 1);
        expect(sem.unlock, throwsStateError);
        expect(() => sem.lock(blocking: false), throwsStateError);
        expect(sem.open, throwsStateError);
        expect(sem.unlink(), isTrue);
        expect(sem.unlink(), isTrue);
        expect(state.unlinks, windows ? 0 : 1);
        expect(state.posts, 1);
        expect(hasName(sem), isFalse);
        expect(hasHandle(sem), isFalse);
      });
      test('failed open frees name and permits retry', () {
        final state = FakeState()..failOpen = true;
        final sem = fake(windows, state);
        expect(sem.open, throwsStateError);
        expect(sem.opened, isFalse);
        expect(hasName(sem), isFalse);
        expect(hasHandle(sem), isFalse);
        state.failOpen = false;
        expect(sem.open(), isTrue);
        expect(sem.close(), isTrue);
        expect(state.unlinks, 0);
      });
      test('close before open is safe and terminal', () {
        final state = FakeState();
        final sem = fake(windows, state);
        expect(sem.unlink(), isFalse);
        expect(sem.close(), isTrue);
        expect(sem.close(), isTrue);
        expect(state.closes, 0);
        expect(sem.open, throwsStateError);
      });
    });
  }
  test('mode storage and promoted sem_open argument match the host ABI', () {
    if (Platform.isWindows) {
      // The public package exports these Unix types on Windows too. Verify
      // their inert mappings load without invoking any Unix native functions.
      expect(sizeOf<mode_t>(), 4);
      expect(sizeOf<SemOpenMode>(), 4);
      return;
    }
    if (!Platform.isLinux && !Platform.isMacOS) return;
    expect(sizeOf<mode_t>(), Platform.isMacOS ? 2 : 4);
    expect(sizeOf<SemOpenMode>(), 4);
    final mode = calloc<SemOpenMode>();
    try {
      mode.value = -1;
      expect(mode.value, Platform.isMacOS ? -1 : 0xffffffff);
    } finally {
      calloc.free(mode);
    }
    if (Platform.isLinux) expect(UnixSemOpenMacros.SEM_FAILED.address, 0);
  });
  test('native same name can be opened after close without unlinking', () {
    final name = freshName();
    NS? current;
    NS? previous;
    try {
      for (var generation = 0; generation < 3; generation++) {
        final sem = NativeSemaphore.instantiate(name: name);
        current = sem;
        if (previous != null) {
          expect(sem, isNot(same(previous)));
          expect(sem.identity, isNot(same(previous.identity)));
          expect(sem.counter, isNot(same(previous.counter)));
          expect(previous.open, throwsStateError);
        }
        expect(sem.counter.counts.process.get(), 0);
        expect(sem.counter.counts.isolate.get(), 0);
        expect(sem.open(), isTrue);
        expect(NativeSemaphore.instantiate(name: name), same(sem));
        final address = sem is UnixSemaphore
            ? sem.semaphore.get!.address
            : (sem as WindowsSemaphore).semaphore.get!.address;
        expect(sem.identity.address, address);
        expect(sem.lock(blocking: false), isTrue);
        expect(sem.lock(blocking: false), isTrue);
        expect(sem.unlock(), isTrue);
        expect(sem.unlock(), isTrue);
        expect(sem.close(), isTrue);
        expect(sem.unlinked, isFalse);
        previous = sem;
      }
    } finally {
      final sem = current;
      if (sem != null) {
        while (sem.locked) sem.unlock();
        sem.close();
        // This fresh test name has no other users; all handles are closed.
        sem.unlink();
      }
    }
  });
  test('name validation and binary maximum', () {
    for (final name in ['', 'a\u0000b']) {
      expect(() => SemaphoreIdentity(name: name), throwsArgumentError);
    }
    final state = FakeState();
    final sem = fake(false, state, 'é' * 16);
    expect(sem.open, throwsArgumentError);
    expect(state.opens, 0);
    final boundary = 'sec${'é' * 13}'; // 29 bytes plus the leading slash.
    final accepted = fake(false, state, boundary);
    expect(accepted.open(), isTrue);
    expect(accepted.close(), isTrue);
    final rejected = fake(false, state, '${boundary}x');
    expect(rejected.open, throwsArgumentError);
    expect(state.opens, 1);
    expect(WindowsCreateSemaphoreWMacros.MAXIMUM_VALUE_RECOMMENDED, 1);
    if (Platform.isLinux) expect(UnixSemOpenMacros.SEM_FAILED.address, 0);
  });
  test('Unix adapter nonblocking failure never acquires or releases', () {
    final state = FakeState()
      ..contend = false
      ..failNonblockingUnixWait = true;
    final sem = fake(false, state)..open();
    for (var attempt = 0; attempt < 3; attempt++) {
      expect(sem.lock(blocking: false), isFalse);
      expect(sem.counter.counts.process.get(), 0);
      expect(sem.counter.counts.isolate.get(), 0);
      expect(sem.locked, isFalse);
      expect(sem.unlock, throwsStateError);
    }
    expect(state.waits, 3);
    expect(state.posts, 0);
    // A blocking failure still throws and must not publish ownership.
    state.failWait = true;
    expect(sem.lock, throwsStateError);
    expect(sem.locked, isFalse);
    expect(sem.counter.counts.process.get(), 0);
    state
      ..failWait = false
      ..failNonblockingUnixWait = false;
    expect(sem.lock(blocking: false), isTrue);
    expect(sem.counter.counts.process.get(), 1);
    expect(sem.unlock(), isTrue);
    expect(state.posts, 1);
    expect(sem.close(), isTrue);
    expect(sem.close(), isTrue);
    expect(state.closes, 1);
    expect(hasName(sem), isFalse);
    expect(hasHandle(sem), isFalse);
  });
  test('Unix adapter unlink error is retryable without retaining allocation', () {
    final state = FakeState()..failUnlink = true;
    final sem = fake(false, state)
      ..open()
      ..close();
    expect(sem.unlink, throwsStateError);
    expect(sem.unlinked, isFalse);
    expect(hasName(sem), isFalse);
    expect(state.unlinks, 1);
    // Repeated failures cannot be mistaken for a successful absent-name unlink.
    expect(sem.unlink, throwsStateError);
    expect(sem.unlinked, isFalse);
    expect(hasName(sem), isFalse);
    expect(state.unlinks, 2);
    state.failUnlink = false;
    expect(sem.unlink(), isTrue);
    expect(sem.unlink(), isTrue);
    expect(state.unlinks, 3);
    expect(hasName(sem), isFalse);
    expect(hasHandle(sem), isFalse);
    expect(sem.close(), isTrue);
    expect(state.closes, 1);
  });
  test('native contention in bounded disposable subprocesses', () async {
    final name = freshName();
    final sem = NativeSemaphore.instantiate(name: name);
    Future<void> child(bool acquired) async {
      final process = await Process.start(Platform.resolvedExecutable, [
        'test',
        'test/security_regression_test.dart',
        '--reporter=expanded'
      ], environment: {
        'SEMAPHORE_SECURITY_WORKER': name,
        'SEMAPHORE_EXPECT_ACQUIRED': '$acquired'
      });
      final output =
          process.stdout.transform(const SystemEncoding().decoder).join();
      final errors =
          process.stderr.transform(const SystemEncoding().decoder).join();
      try {
        final code =
            await process.exitCode.timeout(const Duration(seconds: 20));
        expect(code, 0, reason: '${await output}\n${await errors}');
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
        rethrow;
      }
    }

    try {
      expect(sem.open(), isTrue);
      expect(sem.lock(blocking: false), isTrue);
      await child(false);
      expect(sem.unlock(), isTrue);
      await child(true);
    } finally {
      if (sem.locked) sem.unlock();
      sem.close();
      // All subprocesses have exited before the global name is deleted.
      sem.unlink();
    }
  }, timeout: const Timeout(Duration(seconds: 55)));
}
