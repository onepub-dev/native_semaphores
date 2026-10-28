## 2.0.0

- Release `runtime_native_semaphores` on OnePub with repository metadata
  pointing to `onepub-dev/native_semaphores`. This package is distinct from
  pub.dev's `native_semaphores` package.
- Use a major version for the breaking extension API and unlink semantics,
  keeping this release outside the `^1.0.0-beta.7` dependency range used by
  `runtime_named_locks` 1.0.0-beta.7.
- Harden native handle and name-buffer lifetimes, validate names and injected
  state before native use, and update ownership counters only after successful
  native acquisition or release. Invalid lifecycle/ownership use throws or
  refuses the transition; failed operations do not fabricate ownership.
- Count the added leading slash against the Unix 30-byte UTF-8 name limit:
  raw names are limited to 29 UTF-8 bytes, not 30 characters.
- Validate constructor arguments without invoking subclass `name` or `counter`
  getters before subclass initialization, preserving late-initialized overrides.
- Make successful close terminal for the same object, including close before
  open. `NativeSemaphore.instantiate` after close creates a fresh local wrapper,
  identity, and counter generation without unlinking the shared OS name.
  Retired counters cannot mutate replacement counts; custom state injection is
  rejected after a name's first retirement.
- Require caller-established global quiescence before unlink. Close and
  finalization do not unlink. Repeated close and a previously successful unlink
  are locally idempotent. A POSIX unlink failure, including an absent name,
  throws; Windows object deletion follows closure of all native handles.
- Use native return values without post-FFI `errno`/`GetLastError` reads.
  Nonblocking POSIX `false` means unacquired, whether due to contention or a
  native failure; distinguishing them requires a C shim. Callers must bound
  retries. Blocking POSIX failures, including interruptions, throw without
  retrying. Windows distinguishes timeout from failure using returned wait
  status. This does not claim reliable native error diagnostics or validation
  on every platform.
- **Breaking extension API:** remove the result-processing hooks listed in
  [migration guide](MIGRATION_2.0.0.md), retain predicate veto hooks
  and stateful protected acquisition/release operations, introduce native-call
  adapters, and make count storage per object. Audit subclasses, lifecycle
  overrides, custom counters, and retained native pointers before upgrading.
- The separate `named_locks` / `runtime_named_locks` layer requires its own
  update; upgrading this package alone does not resolve issues in that layer.

## 0.0.1
- Initial release
- See test/semaphore_test.dart for unified usage examples
- See test/unix_named_semaphore_ffi_bindings_test.dart and test/windows_named_semaphore_ffi_bindings_test.dart for platform-specific usage examples

## 0.0.2
- Reflect Platform Support in the README.md

## 0.0.3
- Update README.md with more detailed usage examples, use cases, and background information/references
- Refine directory structure for more standardized dart code organization

## 0.0.4
- Leverage the @Native decorator to re-implement `sem_open` 
- Extend `AbiSpecificInteger` with the `@AbiSpecificIntegerMapping` annotation to enable`mode_t` architecture specific type mappings i.e. UnsignedShort on x86_64 and UnsignedLong on arm64
- Guidance provided on this [dart-sdk issue](https://github.com/dart-lang/native/issues/1086) shout out to [@dcharkes](https://github.com/dcharkes) for the help!

## 0.0.5
- Small changes to Pubspec.yaml to reflect platform support

## 1.0.0-beta.1
- Initial release of the alpha version of the 1.0.0 release
- Made UnixNamedSemaphore and WindowsNamedSemaphore classes extendable to allow for custom implementations
- Refactored all classes to be extensible and now support reentrant behavior + counts of locks/unlocks within the same isolate/thread in addition to the initial cross process locking support.
- Updated unit tests to reflect recursive locking scenarios, and ensure proper implementation of SemaphoreIdentities and SemaphoreCounters
- TODO: @tsavo-at-pieces Re-Implement WindowsNamedSemaphore to support reentrant locking and intra-isolate counts
- TODO: @tsavo-at-pieces Implement a clean-up mechanism for stray locks across the OS
- TODO: @tsavo-at-pieces Implement a way to track lock requests/blocked executions across processes due to current process having yet to unlock itself

## 1.0.0-beta.2
- Small fix to pass `verbose` onto the `NativeSemaphore` constructor
- TODO: @tsavo-at-pieces Re-Implement WindowsNamedSemaphore to support reentrant locking and intra-isolate counts
- TODO: @tsavo-at-pieces Implement a clean-up mechanism for stray locks across the OS
- TODO: @tsavo-at-pieces Implement a way to track lock requests/blocked executions across processes due to current process having yet to unlock itself

## 1.0.0-beta.3
- Small fix on stray print statements here and there 
- TODO: @tsavo-at-pieces Re-Implement WindowsNamedSemaphore to support reentrant locking and intra-isolate counts
- TODO: @tsavo-at-pieces Implement a clean-up mechanism for stray locks across the OS
- TODO: @tsavo-at-pieces Implement a way to track lock requests/blocked executions across processes due to current process having yet to unlock itself

## 1.0.0-beta.4
- Small adjustments to README.md
- Small fix in CI/CD workflow to ensure proper testing across all platforms

## 1.0.0-beta.5
- All tests are now passing on all platforms ?? (Windows, Linux, MacOS)
- ~~TODO~~DONE: @tsavo-at-pieces Re-Implement WindowsNamedSemaphore to support reentrant locking and intra-isolate counts
- TODO: @tsavo-at-pieces Implement a clean-up mechanism for stray locks across the OS
- TODO: @tsavo-at-pieces Implement a way to track lock requests/blocked executions across processes due to current process having yet to unlock itself
- TODO: Prepare for the 1.0.0 release

## 1.0.0-beta.6
- Update GH Actions Steps i.e. @actions/checkout from v4.1.1 to use v4.1.4 and @dart-lang/setup-dart from v1.5.0 to use v1.6.4
- TODO: In code dartdoc comments for pub.dev API documentation
- TODO: GH Actions for Publishing to pub.dev

## 1.0.0-beta.7
- Added cross process unit tests with dart AOT compiled binaries that all try to leverage the same named lock
- FIX: Fixed a bug where the SemaphoreIdentity wasn't getting the Semaphore's address assigned to it
