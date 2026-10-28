// Adapter-only regression tests. No OS semaphore operations or subprocesses.
import 'package:runtime_native_semaphores/runtime_native_semaphores.dart';
import 'package:test/test.dart';

import 'security_regression_test.dart' as fixtures;

abstract interface class ProtectedAccess {
  bool acquire();
  bool release();
  bool recurse();
  bool unwind();
}

// Downstream subclasses can shadow these fields and initialize them only after
// super returns. The base constructor must not invoke their implicit getters.
mixin DeferredFields on NS {
  @override
  // Deliberate field shadowing reproduces downstream constructor ordering.
  // ignore: overridden_fields
  late final String name;
  @override
  // ignore: overridden_fields
  late final CTR counter;
}

class DeferredUnixSemaphore
    extends UnixSemaphore<I, IS, CU, CD, CT, CTS, CTR, CTRS>
    with DeferredFields {
  DeferredUnixSemaphore(String name, CTR counter, fixtures.FakeState state,
      {String? exposedName, CTR? exposedCounter})
      : super(name: name, counter: counter, calls: fixtures.FakeUnix(state)) {
    this.name = exposedName ?? name;
    this.counter = exposedCounter ?? counter;
  }
}

class DeferredWindowsSemaphore
    extends WindowsSemaphore<I, IS, CU, CD, CT, CTS, CTR, CTRS>
    with DeferredFields {
  DeferredWindowsSemaphore(String name, CTR counter, fixtures.FakeState state,
      {String? exposedName, CTR? exposedCounter})
      : super(
            name: name, counter: counter, calls: fixtures.FakeWindows(state)) {
    this.name = exposedName ?? name;
    this.counter = exposedCounter ?? counter;
  }
}

mixin HookVeto on NS {
  bool allowOpen = true;
  bool allowAcquire = true;
  bool allowRelease = true;
  bool allowRecurse = true;
  bool allowUnwind = true;
  bool allowClose = true;
  bool allowUnlink = true;

  @override
  bool willAttemptOpen() => allowOpen;
  @override
  bool willAttemptLockAcrossProcesses() => allowAcquire;
  @override
  bool willAttemptUnlockAcrossProcesses() => allowRelease;
  @override
  bool willAttemptLockReentrantToIsolate() => allowRecurse;
  @override
  bool willAttemptUnlockReentrantToIsolate() => allowUnwind;
  @override
  bool willAttemptClose() => allowClose;
  @override
  bool willAttemptUnlink() => allowUnlink;
}

class UnixSubclass extends UnixSemaphore<I, IS, CU, CD, CT, CTS, CTR, CTRS>
    with HookVeto
    implements ProtectedAccess {
  UnixSubclass(String name, fixtures.FakeState state)
      : super(
            name: name,
            counter: fixtures.makeCounter(name),
            calls: fixtures.FakeUnix(state));
  @override
  bool acquire() => super.lockAcrossProcesses(blocking: false);
  @override
  bool release() => super.unlockAcrossProcesses();
  @override
  bool recurse() => super.lockReentrantToIsolate();
  @override
  bool unwind() => super.unlockReentrantToIsolate();
}

class WindowsSubclass
    extends WindowsSemaphore<I, IS, CU, CD, CT, CTS, CTR, CTRS>
    with HookVeto
    implements ProtectedAccess {
  WindowsSubclass(String name, fixtures.FakeState state)
      : super(
            name: name,
            counter: fixtures.makeCounter(name),
            calls: fixtures.FakeWindows(state));
  @override
  bool acquire() => super.lockAcrossProcesses(blocking: false);
  @override
  bool release() => super.unlockAcrossProcesses();
  @override
  bool recurse() => super.lockReentrantToIsolate();
  @override
  bool unwind() => super.unlockReentrantToIsolate();
}

void main() {
  for (final windows in [false, true]) {
    NS deferred(String name, CTR counter, fixtures.FakeState state,
            {String? exposedName, CTR? exposedCounter}) =>
        windows
            ? DeferredWindowsSemaphore(name, counter, state,
                exposedName: exposedName, exposedCounter: exposedCounter)
            : DeferredUnixSemaphore(name, counter, state,
                exposedName: exposedName, exposedCounter: exposedCounter);

    group(windows ? 'Windows protected adapters' : 'Unix protected adapters',
        () {
      test('constructor validates arguments before deferred subclass fields',
          () {
        final name = fixtures.freshName();
        final counter = fixtures.makeCounter(name);
        final state = fixtures.FakeState()..contend = false;
        final sem = deferred(name, counter, state);
        expect(sem.name, name);
        expect(sem.counter, same(counter));
        expect(sem.identity, same(counter.identity));
        expect(sem.open(), isTrue);
        expect(sem.lock(blocking: false), isTrue);
        expect(counter.counts.process.get(), 1);
        expect(sem.unlock(), isTrue);
        expect(sem.close(), isTrue);

        final rejected = fixtures.FakeState();
        expect(() => deferred('', counter, rejected), throwsArgumentError);
        expect(() => deferred(fixtures.freshName(), counter, rejected),
            throwsArgumentError);
        expect(rejected.opens, 0);
      });

      test('post-construction access still dispatches to subclass fields', () {
        final argumentName = fixtures.freshName();
        final argumentCounter = fixtures.makeCounter(argumentName);
        final exposedName = fixtures.freshName();
        final exposedCounter = fixtures.makeCounter(exposedName);
        final state = fixtures.FakeState()..contend = false;
        final sem = deferred(argumentName, argumentCounter, state,
            exposedName: exposedName, exposedCounter: exposedCounter);
        expect(sem.name, exposedName);
        expect(sem.counter, same(exposedCounter));
        expect(sem.identity, same(exposedCounter.identity));
        expect(sem.open(), isTrue);
        expect(sem.lock(blocking: false), isTrue);
        expect(exposedCounter.counts.process.get(), 1);
        expect(argumentCounter.counts.process.get(), 0);
        expect(sem.unlock(), isTrue);
        expect(sem.close(), isTrue);
      });

      test('open revalidates shadowed name and counter before native calls',
          () {
        final name = fixtures.freshName();
        final counter = fixtures.makeCounter(name);
        for (final exposedName in ['', fixtures.freshName()]) {
          final state = fixtures.FakeState();
          final sem = deferred(name, counter, state, exposedName: exposedName);
          expect(sem.open, throwsArgumentError);
          expect(state.opens, 0);
          expect(sem.opened, isFalse);
          sem.close();
        }
      });

      late fixtures.FakeState state;
      late NS sem;
      late ProtectedAccess direct;
      late HookVeto hooks;
      setUp(() {
        state = fixtures.FakeState();
        final name = fixtures.freshName();
        sem =
            windows ? WindowsSubclass(name, state) : UnixSubclass(name, state);
        direct = sem as ProtectedAccess;
        hooks = sem as HookVeto;
      });

      test('direct protected acquisition and public release update once', () {
        expect(direct.acquire, throwsStateError);
        sem.open();
        expect(direct.acquire(), isFalse);
        expect(sem.locked, isFalse);
        expect(sem.counter.counts.isolate.get(), 0);
        state.failWait = true;
        expect(direct.acquire, throwsStateError);
        expect(sem.locked, isFalse);
        state
          ..failWait = false
          ..contend = false;
        expect(direct.acquire(), isTrue);
        expect(sem.counter.counts.process.get(), 1);
        expect(sem.counter.counts.isolate.get(), 0);
        expect(sem.locked, isTrue);
        final waits = state.waits;
        expect(direct.acquire(), isFalse);
        expect(state.waits, waits);
        expect(sem.unlock(), isTrue);
        expect(sem.counter.counts.process.get(), 0);
        expect(state.posts, 1);
        sem.close();
      });

      test('public acquisition and direct release preserve failure ownership',
          () {
        sem.open();
        state.contend = false;
        expect(sem.lock(blocking: false), isTrue);
        expect(sem.counter.counts.process.get(), 1);
        state.failPost = true;
        expect(direct.release, throwsStateError);
        expect(sem.counter.counts.process.get(), 1);
        expect(state.posts, 0);
        state.failPost = false;
        expect(direct.release(), isTrue);
        expect(sem.locked, isFalse);
        expect(direct.release, throwsStateError);
        expect(state.posts, 1);
        // A new public lock must perform a native wait, not false recursion.
        expect(sem.lock(blocking: false), isTrue);
        expect(state.waits, 2);
        expect(sem.counter.counts.process.get(), 1);
        sem.unlock();
        sem.close();
      });

      test('mixed direct and public recursion posts only at outer release', () {
        sem.open();
        expect(direct.recurse, throwsStateError);
        state.contend = false;
        direct.acquire();
        expect(direct.recurse(), isTrue);
        expect(sem.lock(blocking: false), isTrue);
        expect(sem.counter.counts.process.get(), 1);
        expect(sem.counter.counts.isolate.get(), 2);
        expect(direct.release, throwsStateError);
        expect(state.posts, 0);
        expect(direct.unwind(), isTrue);
        expect(sem.unlock(), isTrue);
        expect(state.posts, 0);
        expect(direct.release(), isTrue);
        expect(state.waits, 1);
        expect(state.posts, 1);
        expect(sem.locked, isFalse);
        sem.close();
      });

      test('predicate overrides are called and can veto safe transitions', () {
        hooks.allowOpen = false;
        expect(sem.open(), isFalse);
        expect(state.opens, 0);
        hooks.allowOpen = true;
        sem.open();
        state.contend = false;
        hooks.allowAcquire = false;
        expect(sem.lock(blocking: false), isFalse);
        expect(state.waits, 0);
        hooks.allowAcquire = true;
        sem.lock(blocking: false);
        hooks.allowRecurse = false;
        expect(sem.lock(blocking: false), isFalse);
        expect(sem.counter.counts.isolate.get(), 0);
        hooks.allowRecurse = true;
        sem.lock(blocking: false);
        hooks.allowUnwind = false;
        expect(sem.unlock(), isFalse);
        expect(sem.counter.counts.isolate.get(), 1);
        hooks.allowUnwind = true;
        sem.unlock();
        hooks.allowRelease = false;
        expect(sem.unlock(), isFalse);
        expect(state.posts, 0);
        expect(sem.counter.counts.process.get(), 1);
        expect(sem.close(), isFalse);
        hooks.allowRelease = true;
        sem.unlock();
        hooks.allowClose = false;
        expect(sem.close(), isFalse);
        expect(state.closes, 0);
        hooks.allowClose = true;
        sem.close();
        hooks.allowUnlink = false;
        expect(sem.unlink(), isFalse);
        expect(sem.unlinked, isFalse);
        hooks.allowUnlink = true;
        expect(sem.unlink(), isTrue);
      });
    });
  }

  test('raw prefix and surrogate aliases fail even with cached registry keys',
      () {
    for (final invalid in [
      'Global\\secAlias',
      'Local\\secAlias',
      'sec\ud800',
      'sec\udc00',
      'sec\ud800x',
      'sec\udc00\ud800',
    ]) {
      // Seed exactly the invalid key to prove validation precedes cache lookup.
      final safe = fixtures.freshName();
      final sem = fixtures.fake(false, fixtures.FakeState(), safe);
      NativeSemaphores().register(name: invalid, semaphore: sem);
      SemaphoreIdentities().register(name: invalid, identity: sem.identity);
      try {
        expect(() => SemaphoreIdentity(name: invalid), throwsArgumentError);
        expect(() => SemaphoreIdentity.instantiate(name: invalid),
            throwsArgumentError);
        expect(() => NativeSemaphore.instantiate(name: invalid),
            throwsArgumentError);
        for (final windows in [false, true]) {
          final state = fixtures.FakeState();
          expect(
              () => windows
                  ? WindowsSemaphore(
                      name: invalid,
                      counter: sem.counter,
                      calls: fixtures.FakeWindows(state))
                  : UnixSemaphore(
                      name: invalid,
                      counter: sem.counter,
                      calls: fixtures.FakeUnix(state)),
              throwsArgumentError);
          expect(state.opens, 0);
        }
      } finally {
        NativeSemaphores().delete(name: invalid);
        SemaphoreIdentities().delete(name: invalid);
      }
    }
  });

  test('valid Unicode pairs and replacement characters retain distinct names',
      () {
    final suffix = fixtures.freshName().substring(3, 10);
    final names = ['sec${suffix}\ud83d\ude00', 'sec${suffix}\ufffd'];
    final first = NativeSemaphore.instantiate(name: names.first);
    final second = NativeSemaphore.instantiate(name: names.last);
    expect(first, isNot(same(second)));
    expect(first.identity.name, names.first);
    expect(second.identity.name, names.last);
    for (final name in names) {
      for (final windows in [false, true]) {
        final state = fixtures.FakeState();
        final sem = fixtures.fake(windows, state, name);
        expect(sem.open(), isTrue);
        expect(state.opens, 1);
        sem.close();
      }
    }
    // The factory-created wrappers were never opened, so close is adapter-free.
    first.close();
    second.close();
  });

  test(
      'custom injection is initial-generation only across retirement and deletion',
      () {
    final name = fixtures.freshName();
    final identity = SemaphoreIdentity.instantiate(name: name);
    final counter = SemaphoreCounter.instantiate(identity: identity);
    final first = NativeSemaphore.instantiate(name: name, counter: counter);
    first.close(); // Never opened: does not call native close.
    final second = NativeSemaphore.instantiate(name: name);
    expect(() => NativeSemaphore.instantiate(name: name, counter: counter),
        throwsArgumentError);
    expect(() => NativeSemaphore.instantiate(name: name, identity: identity),
        throwsArgumentError);
    second.close();
    final third = NativeSemaphore.instantiate(name: name);
    third.close();
    expect(() => NativeSemaphore.instantiate(name: name, counter: counter),
        throwsArgumentError);
    expect(() => NativeSemaphore.instantiate(name: name, identity: identity),
        throwsArgumentError);
    // Even fresh custom state is outside the post-retirement injection contract.
    expect(
        () => NativeSemaphore.instantiate(
            name: name, identity: SemaphoreIdentity(name: name)),
        throwsArgumentError);
    NativeSemaphores().delete(name: name);
    expect(() => NativeSemaphore.instantiate(name: name, counter: counter),
        throwsArgumentError);
    expect(() => NativeSemaphore.instantiate(name: name, identity: identity),
        throwsArgumentError);
    final replacement = NativeSemaphore.instantiate(name: name);
    expect(replacement.counter, isNot(same(third.counter)));
    expect(replacement.identity, isNot(same(third.identity)));
    third.counter.counts.process.increment();
    expect(replacement.counter.counts.process.get(), 0);
    expect(replacement.counter.counts.isolate.get(), 0);
    expect(NativeSemaphore.instantiate(name: name), same(replacement));
    expect(replacement.close(), isTrue);
  });

  test(
      'mismatched injected state is rejected before returning an active wrapper',
      () {
    final name = fixtures.freshName();
    final active = NativeSemaphore.instantiate(name: name);
    final other = SemaphoreIdentity(name: fixtures.freshName());
    final otherCounter = SemaphoreCounter.instantiate(identity: other);
    expect(() => NativeSemaphore.instantiate(name: name, identity: other),
        throwsArgumentError);
    expect(() => NativeSemaphore.instantiate(name: name, counter: otherCounter),
        throwsArgumentError);
    expect(
        () => NativeSemaphore.instantiate(
            name: name,
            identity: SemaphoreIdentity(name: name),
            counter: active.counter),
        throwsArgumentError);
    active.close();
  });
}
