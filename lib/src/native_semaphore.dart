import 'dart:ffi' show Finalizable;
import 'dart:io' show Platform;

import 'package:meta/meta.dart' show protected;
import '../runtime_native_semaphores.dart'
    show
        LatePropertyAssigned,
        SemaphoreCount,
        SemaphoreCountDeletion,
        SemaphoreCountUpdate,
        SemaphoreCounter,
        SemaphoreCounters,
        SemaphoreCounts,
        SemaphoreIdentities,
        SemaphoreIdentity,
        UnixSemaphore,
        WindowsSemaphore;

// A wrapper to track the instances of the native semaphore
class NativeSemaphores<
    /*  Identity */
    I extends SemaphoreIdentity,
    /* Semaphore Identities */
    IS extends SemaphoreIdentities<I>,
    /* Count Update */
    CU extends SemaphoreCountUpdate,
    /* Count Deletion */
    CD extends SemaphoreCountDeletion,
    /* Semaphore Count */
    CT extends SemaphoreCount<CU, CD>,
    /* Semaphore Counts */
    CTS extends SemaphoreCounts<CU, CD, CT>,
    /* Semaphore Counter */
    CTR extends SemaphoreCounter<I, CU, CD, CT, CTS>,
    /* Semaphore Counter */
    CTRS extends SemaphoreCounters<I, CU, CD, CT, CTS, CTR>,
    /* Native Semaphore */
    NS extends NativeSemaphore<I, IS, CU, CD, CT, CTS, CTR, CTRS>
    /* formatting guard comment */
    > {
  static final Map<String, dynamic> __instantiations = {};

  final Map<String, dynamic> _instantiations =
      NativeSemaphores.__instantiations;

  Map<String, dynamic> get all => Map.unmodifiable(_instantiations);

  bool has<T>({required String name}) =>
      _instantiations.containsKey(name) && _instantiations[name] is T;

  // Returns the semaphore identity for the given identifier as a singleton
  NS get({required String name}) =>
      _instantiations[name] as NS? ??
      (throw Exception(
          'Failed to get semaphore counter for $name. It doesn\'t exist.'));

  NS register({required String name, required NS semaphore}) {
    (_instantiations.containsKey(name) || semaphore != _instantiations[name]) ||
        (throw Exception(
            'Failed to register semaphore counter for $name. It already exists or is not the same as the inbound identity being passed.'));

    return _instantiations.putIfAbsent(name, () => semaphore) as NS;
  }

  void delete({required String name}) {
    _instantiations.containsKey(name) ||
        (throw Exception(
            'Failed to delete semaphore counter for $name. It doesn\'t exist.'));
    _instantiations.remove(name);
  }

  @override
  String toString() => 'NativeSemaphores(all: ${all})';
}

class NativeSemaphore<
    /*  Identity */
    I extends SemaphoreIdentity,
    /* Semaphore Identities */
    IS extends SemaphoreIdentities<I>,
    /* Count Update */
    CU extends SemaphoreCountUpdate,
    /* Count Deletion */
    CD extends SemaphoreCountDeletion,
    /* Semaphore Count */
    CT extends SemaphoreCount<CU, CD>,
    /* Semaphore Counts */
    CTS extends SemaphoreCounts<CU, CD, CT>,
    /* Semaphore Counter */
    CTR extends SemaphoreCounter<I, CU, CD, CT, CTS>,
    /* Semaphore Counter */
    CTRS extends SemaphoreCounters<I, CU, CD, CT, CTS, CTR>
    /* formatting guard comment */
    > implements Finalizable {
  static late final dynamic __instances;

  // Injection is an initial-generation extension point only. Keeping names
  // rather than retired objects prevents stale state reuse without retaining
  // every identity/counter ever allocated for a name.
  static final Set<String> _retiredNames = {};

  // ignore: unused_element
  dynamic get _instances => NativeSemaphore.__instances;

  bool verbose;

  late final String name;

  late final CTR counter;

  I get identity => counter.identity;

  @protected
  bool hasOpened = false;

  @protected
  bool hasClosed = false;

  // If closed is assigned then opened is the opposite
  bool get opened => hasOpened && !hasClosed;

  bool get closed => hasClosed;

  /// Platform close implementations must retire even never-opened wrappers.
  @protected
  void markClosed() {
    _retiredNames.add(name);
    hasClosed = true;
  }

  bool hasUnlinked = false;

  bool get unlinked => hasUnlinked;

  // identities are always bound to a unique counter and thus the identity for the counter is the identity for the semaphore
  // late final I identity = counter.identity;

  // get locked i.e. the count of the semaphore
  bool get locked {
    int isolates = counter.counts.isolate.get();
    int processes = counter.counts.process.get();
    return isolates > 0 || processes > 0;
  }

  // if we are reentrant internally
  bool get reentrant => counter.counts.isolate.get() > 0;

  NativeSemaphore(
      {required String this.name,
      required CTR this.counter,
      this.verbose = false}) {
    SemaphoreIdentity.validateName(name);
    if (counter.identity.name != name) {
      throw ArgumentError('Counter identity must match the semaphore name.');
    }
  }

  // TODO maybe a rehydrate method? or instantiate takes in a "from process" flag i.e. to attempt to find and rehydrate the semaphore from another process/all processes
  static NativeSemaphore<I, IS, CU, CD, CT, CTS, CTR, CTRS> instantiate<
          /*  Identity */
          I extends SemaphoreIdentity,
          /* Semaphore Identities */
          IS extends SemaphoreIdentities<I>,
          /* Count Update */
          CU extends SemaphoreCountUpdate,
          /* Count Deletion */
          CD extends SemaphoreCountDeletion,
          /* Semaphore Count */
          CT extends SemaphoreCount<CU, CD>,
          /* Semaphore Counts */
          CTS extends SemaphoreCounts<CU, CD, CT>,
          /* Semaphore Counter i.e. this class */
          CTR extends SemaphoreCounter<I, CU, CD, CT, CTS>,
          /* Semaphore Counters */
          CTRS extends SemaphoreCounters<I, CU, CD, CT, CTS, CTR>,
          /* Native Semaphore */
          NS extends NativeSemaphore<I, IS, CU, CD, CT, CTS, CTR, CTRS>,
          /*Native Semaphores*/
          NSS extends NativeSemaphores<I, IS, CU, CD, CT, CTS, CTR, CTRS, NS>
          /* formatting guard comment */
          >(
      {required String name, I? identity, CTR? counter, bool verbose = false}) {
    SemaphoreIdentity.validateName(name);
    if ((identity != null && identity.name != name) ||
        (counter != null && counter.identity.name != name) ||
        (identity != null &&
            counter != null &&
            !identical(identity, counter.identity))) {
      throw ArgumentError('Injected state must match the semaphore identity.');
    }
    if (_retiredNames.contains(name) && (identity != null || counter != null)) {
      throw ArgumentError('Custom state cannot be injected after retirement.');
    }
    if (!LatePropertyAssigned<NSS>(() => __instances)) {
      __instances = NativeSemaphores<I, IS, CU, CD, CT, CTS, CTR, CTRS, NS>();
      if (verbose) print('Setting NativeSemaphore._instances: ${__instances}');
    }

    final instances = __instances as NSS;
    if (instances.has<NS>(name: name)) {
      final previous = instances.get(name: name);
      if (!previous.closed) return previous;
      _retiredNames.add(name);
      if (identity != null || counter != null) {
        throw ArgumentError(
            'Custom state cannot be injected after retirement.');
      }
      final counters = SemaphoreCounters<I, CU, CD, CT, CTS, CTR>();
      if (counters.has<CTR>(identifier: name) &&
          identical(counters.get(identifier: name), previous.counter)) {
        counters.delete(identifier: name);
      }
      final identities = SemaphoreIdentities<I>();
      if (identities.has<I>(name: name) &&
          identical(identities.get(name: name), previous.identity)) {
        identities.delete(name: name);
      }
      instances.delete(name: name);
      // Only isolate-local registries change: the shared OS name remains.
    }

    return (__instances as NSS).has<NS>(name: name)
        ? (__instances as NSS).get(name: name)
        : (__instances as NSS).register(
            name: name,
            semaphore: Platform.isWindows
                ? WindowsSemaphore(
                    name: name,
                    counter: counter ??
                        SemaphoreCounter.instantiate<I, CU, CD, CT, CTS, CTR,
                            CTRS>(
                          identity: identity ??
                              SemaphoreIdentity.instantiate<I, IS>(
                                name: name,
                              ) as I,
                        ),
                    verbose: verbose,
                  ) as NS
                : UnixSemaphore(
                    name: name,
                    counter: counter ??
                        SemaphoreCounter.instantiate<I, CU, CD, CT, CTS, CTR,
                            CTRS>(
                          identity: identity ??
                              SemaphoreIdentity.instantiate<I, IS>(
                                name: name,
                              ) as I,
                        ) as CTR,
                    verbose: verbose,
                  ) as NS,
          );
  }

  @protected
  bool willAttemptOpen() => true;

  /// Opens this instance, or succeeds without another native open if open.
  /// Close is terminal for this object. Call instantiate with the same name
  /// to obtain a fresh instance. A failed open can be retried before close.
  bool open() => throw UnimplementedError();

  // Returns a boolean condition
  @protected
  bool willAttemptLockReentrantToIsolate() => true;
  @protected
  bool lockReentrantToIsolate() {
    if (!opened || counter.counts.process.get() != 1) {
      throw StateError('Recursion requires an open outer acquisition.');
    }
    if (!willAttemptLockReentrantToIsolate()) return false;
    counter.counts.isolate.increment();
    return true;
  }

  @protected
  bool willAttemptLockAcrossProcesses() => counter.counts.process.get() == 0;
  @protected
  bool lockAcrossProcesses({bool blocking = true, Duration? timeout}) =>
      throw UnimplementedError();

  @protected
  bool willAttemptUnlockAcrossProcesses() => counter.counts.isolate.get() == 0;
  @protected
  bool unlockAcrossProcesses() => throw UnimplementedError();

  /// Recursion is isolate-wide; this does not identify independent async tasks.
  /// A false nonblocking result means no acquisition. On POSIX it can represent
  /// either contention or a native failure; errno cannot be read reliably after
  /// the FFI call. Callers implementing retries must enforce their own deadline.
  /// Blocking native failures throw without changing ownership counters.
  bool lock({bool blocking = true}) {
    if (!opened) throw StateError('Cannot lock a semaphore that is not open.');
    if (counter.counts.process.get() > 0) {
      return lockReentrantToIsolate();
    }
    // Contention is not recursion and must not mutate either counter.
    return lockAcrossProcesses(blocking: blocking);
  }

  @protected
  bool willAttemptUnlockReentrantToIsolate() =>
      counter.counts.isolate.get() > 0;
  @protected
  bool unlockReentrantToIsolate() {
    if (!opened || counter.counts.process.get() != 1) {
      throw StateError('Recursion requires an open outer acquisition.');
    }
    if (counter.counts.isolate.get() <= 0 ||
        !willAttemptUnlockReentrantToIsolate()) return false;
    counter.counts.isolate.decrement();
    return true;
  }

  bool unlock() {
    if (!opened || counter.counts.process.get() <= 0) {
      throw StateError(
          'Cannot unlock a semaphore without an open acquisition.');
    }
    if (counter.counts.isolate.get() > 0) {
      return unlockReentrantToIsolate();
    }
    return unlockAcrossProcesses();
  }

  @protected
  bool willAttemptClose() => !locked;

  bool close() => throw UnimplementedError();

  @protected
  bool willAttemptUnlink() => closed && !locked;

  bool unlink() => throw UnimplementedError();

  @override
  String toString() => throw UnimplementedError();
}
