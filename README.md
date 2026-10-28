# runtime_native_semaphores

`runtime_native_semaphores` provides native named semaphores through Dart FFI
for cooperating processes and isolates on Linux, macOS, and Windows. Originally
developed by [Pieces for Developers](https://pieces.app), this package
is maintained at [onepub-dev/native_semaphores](https://github.com/onepub-dev/native_semaphores).

This release is **`runtime_native_semaphores` 1.0.0-beta.8**, hosted on OnePub.
It is distinct from the public pub.dev package named `native_semaphores`.
These release notes do not claim that the public package has been updated.

## Installation

With access to the private OnePub repository, use:

```yaml
dependencies:
  runtime_native_semaphores:
    hosted: https://onepub.dev/api/jbbxpsdavu/
    version: 1.0.0-beta.8
```

## Usage and ownership

```dart
import 'package:runtime_native_semaphores/runtime_native_semaphores.dart';

void main() {
  final semaphore = NativeSemaphore.instantiate(name: 'my-shared-resource');
  if (!semaphore.open()) throw StateError('Open was vetoed');
  try {
    if (!semaphore.lock()) throw StateError('No acquisition');
    try {
      // Access the resource shared by cooperating processes or isolates.
    } finally {
      if (!semaphore.unlock()) throw StateError('Unlock was vetoed');
    }
  } finally {
    if (!semaphore.close()) throw StateError('Semaphore still owned or vetoed');
  }
  // Do not unlink here: other processes or isolates may still use this name.
}
```

Blocking `lock()` synchronously blocks the calling thread. Reentrancy tracks
ownership within an isolate; it does not distinguish independent asynchronous
tasks in that isolate. Use separate task-level synchronization where needed.
The `locked` and `reentrant` properties report local counters, not global
ownership or quiescence.

## Lifecycle and beta.8 migration

- `open()` on an already open object succeeds without another native open.
  A failed open can be retried before close. Locking requires an open object;
  unlocking requires an acquisition, otherwise a `StateError` is thrown.
- `close()` refuses while locally owned. Successful close is terminal for
  that object, including close before open. Repeated close succeeds locally;
  `open()` on that closed object throws.
- Call `NativeSemaphore.instantiate(name: name)` after close to obtain a fresh
  wrapper, identity, and counter generation. This replaces isolate-local
  state; it does not unlink or recreate the shared operating-system name.
  Retained counters from an older generation cannot change the replacement's
  counts. Custom identity/counter injection is rejected after the name's first
  retirement, even if the supplied custom state is fresh.
- `unlink()` requires close and **caller-established global quiescence**:
  coordinate all processes and isolates so that no participant still uses,
  waits on, or opens that name during removal. Local counters cannot establish
  this. On POSIX, unlinking a name while old handles remain can let new callers
  create a separate semaphore and break mutual exclusion.
- Close never unlinks, and no finalizer unlinks the shared name. On POSIX,
  native unlink failure, including an already absent name, throws. Only a
  previous successful unlink on the same wrapper makes repeated unlink calls
  idempotent; this is not a global existence check. On Windows, `unlink()`
  records local completion after close; the kernel object disappears when
  all handles close.

Names must be nonempty, unprefixed identifiers. NUL, reserved punctuation,
`Global\`/`Local\` input prefixes, and unpaired UTF-16 surrogates are rejected.
Valid surrogate pairs are accepted without Unicode normalization. Platform
length limits are checked before native open. Injected state must match the
name; an injected counter and identity must reference the same identity.

## Native failures and nonblocking waits

`lock(blocking: false)` returning `false` means **no acquisition**. On POSIX,
every nonzero `sem_trywait` result returns false: contention and native failure
are indistinguishable through this API. If retrying, impose a bounded monotonic
deadline; persistent native errors may appear as a caller's timeout. The
package supplies neither a retry loop nor a deadline. Blocking POSIX wait
failures, including interruptions, throw without retrying.

Windows uses the returned wait status: `WAIT_OBJECT_0` acquires,
`WAIT_TIMEOUT` returns false, and other statuses throw. Native open, post, and
close failures throw; POSIX unlink failures also throw. Ownership counters
change only after successful native acquisition or release.

The adapters do not read `errno` or `GetLastError` after a Dart FFI transition.
Reliable native error capture and precise POSIX nonblocking classification
require a C shim that captures the result and error together. Generic failures
therefore omit those diagnostics. Adapter-level checks are not evidence of
successful native validation on every supported platform.

## Subclass compatibility

Beta.8 deliberately breaks part of the beta.7 extension API. The seven
result-processing hooks listed in the
[extension migration guide](EXTENSION_API_BETA8.md) are removed. Audit subclass
methods even if they lack `@override`, because those stale methods may compile
without being called. Move native operations into `UnixSemaphoreCalls` or
`WindowsSemaphoreCalls` constructor adapters.

The `willAttempt*` predicates remain supported veto hooks; they must not mutate
ownership or perform native I/O. Hard lifecycle and ownership checks cannot
be bypassed through them. Idempotent operations do not repeat hooks or native
calls. Protected cross-process lock/unlock operations remain stateful and
update the outer ownership count exactly once; reentrant operations update
only recursion counts. Overrides must delegate to `super` or preserve the full
ownership contract, and lifecycle overrides must delegate to the platform
implementation so retirement is recorded.

`SemaphoreCount.all` now exposes per-object storage. Custom counters must use
generation-local storage rather than shared static maps. Native name-pointer
getters expose a pointer only during the native call; do not retain it. See the
[full migration guide](EXTENSION_API_BETA8.md) before updating subclasses.

## Security scope

This release hardens native return-value handling, handle and name-buffer
lifetime, ownership accounting, input validation, and retired-generation
isolation. It does not establish a remote exploit or claim cross-platform
native release validation. The separate `named_locks` / `runtime_named_locks`
downstream layer remains vulnerable until its own fix is implemented and
validated; updating this dependency alone does not fix that layer.

## License

[Apache License 2.0](LICENSE).
