# runtime_native_semaphores 2.0.0 migration

`runtime_native_semaphores` 2.0.0 on OnePub intentionally breaks part of the
1.0.0-beta.7 subclass API and changes unlink semantics. It is distinct from
the public pub.dev package `native_semaphores`. The major version keeps this
release outside the `^1.0.0-beta.7` dependency range used by the separate
`runtime_named_locks` 1.0.0-beta.7 package, which requires its own migration
and fix before adopting 2.0.0.

`lockAcrossProcesses` and `unlockAcrossProcesses` remain **stateful** protected
operations on both platforms. A successful acquisition increments the process
count once; successful release decrements it once. Public `lock`/`unlock` do
not repeat those updates. An unsuccessful nonblocking POSIX wait returns false
without changing counters, whether caused by contention or a native failure.
Blocking POSIX failures and Windows wait failures throw before ownership
changes. An existing outer acquisition
makes a direct cross-process acquisition return false without another wait.
Public recursion and protected `lockReentrantToIsolate` /
`unlockReentrantToIsolate` update only the recursion count. A direct outer
release while recursive acquisitions remain throws without posting.

The `willAttemptOpen`, `willAttemptLockAcrossProcesses`,
`willAttemptUnlockAcrossProcesses`, `willAttemptLockReentrantToIsolate`,
`willAttemptUnlockReentrantToIsolate`, `willAttemptClose`, and `willAttemptUnlink`
predicates remain supported and can veto transitions. Hard lifecycle and
ownership checks run independently of those predicates. Idempotent operations
return without repeating predicates or native operations. Overrides of the
stateful operations must delegate to `super` or maintain their full ownership
contract; predicate overrides must not mutate ownership or perform native I/O.

The following old result-processing hooks are **removed**, rather than retained
as methods that are silently bypassed or inherit `UnimplementedError`:

- `openAttemptSucceeded`
- `lockAttemptAcrossProcessesSucceeded`
- `unlockAttemptAcrossProcessesSucceeded`
- `lockAttemptReentrantToIsolateSucceeded`
- `unlockAttemptReentrantToIsolateSucceeded`
- `closeAttemptSucceeded`
- `unlinkAttemptSucceeded`

Direct `super` calls to removed hooks no longer compile. The analyzer diagnoses
stale `@override` annotations; it cannot detect a same-named method declared
without `@override`. All downstream subclasses must therefore audit these exact
names before adopting 2.0.0. Move native behavior to `UnixSemaphoreCalls` or
`WindowsSemaphoreCalls`, passed through the constructor. Their wait methods
return false for no acquisition: on POSIX this includes every nonzero
`sem_trywait` result, while Windows distinguishes timeout from failure using
the returned wait status. Blocking wait failures throw. Post/close/unlink
return normally only on success. State transitions belong to the semaphore,
not the adapter. Lifecycle overrides must delegate to the platform `super`
implementation so retirement is recorded. Custom counters must provide
generation-local storage; shared static count maps are unsupported.

Names are unprefixed identifiers. `Global\\` and `Local\\` input prefixes are
rejected, not stripped. Empty names, NUL, reserved punctuation and unpaired
UTF-16 surrogates are rejected before factory lookup or native open. Valid
surrogate pairs are accepted; no Unicode normalization is performed. Platform
length limits are still checked before native open. Injected identities and
counters must match the name, and if both are supplied they must refer to the
same identity.

Custom identity/counter injection through `NativeSemaphore.instantiate` is
supported only before the name's first retirement. After any successful close
(including close before open), all such injection is rejected, even while a
replacement is active or after the wrapper registry entry has been deleted.
Default factory replacement remains available. This deliberately narrower
contract rejects both fresh custom state and retained state from any older
generation. Manually populating registries, overriding lifecycle storage, or
constructing wrappers around reused state is not a supported way to bypass
this factory contract. Downstream factories must implement equivalent lifecycle
and generation isolation themselves.

Version 2.0.0 also changes `SemaphoreCount.all` to object-local storage,
reported native failures to exceptions (with the POSIX nonblocking limitation
below), and name-pointer getters to expose a pointer only during the native
call. Do not retain a pointer obtained from those getters.
Close is terminal; unlink requires close and separately established global
quiescence. Coordinate all processes and isolates so that none still uses,
waits on, or opens the name during removal. Do not unlink during active use.
The `runtime_named_locks` 1.0.0-beta.7 multi-isolate test unlinks during use
and is incompatible with this lifecycle contract; upgrading its dependency
alone does not fix it.

## Recover existing native semaphore state before upgrading

Before trusting mutual exclusion with 2.0.0, migrate any names previously used
by beta.7. An unmatched beta.7 `unlock()` could leave more than one native
permit, allowing concurrent owners after an upgrade. An abandoned zero count
can instead leave future callers unable to acquire. Closing handles or opening
the same name with 2.0.0 does not repair either condition: POSIX opens of an
existing name ignore the requested initial count, and named semaphores can
persist after all handles close. See [sem_open](https://man7.org/linux/man-pages/man3/sem_open.3.html)
and [named semaphore persistence](https://man7.org/linux/man-pages/man7/sem_overview.7.html).

Use a coordinated migration across **all processes and isolates**:

1. Stop old participants and establish global quiescence: no participant may
   hold, wait on, or open an affected name during migration. Close their handles.
2. Unlink the affected POSIX names and recreate them with the intended initial
   count, or move every participant to fresh names. Never unlink while old
   users are active: old handles and a recreated name can refer to different
   native objects and defeat exclusion.
3. Restart all participants using the migrated names and compatible code only
   after this coordinated reset or name change is complete.

On Windows, existing handles can keep the old semaphore object and its
parameters alive; opening that name ignores the new initial and maximum
counts. Ensure all old handles are closed before recreation, or coordinate a
move to fresh names. See [CreateSemaphoreW](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-createsemaphorew).

Version 2.0.0 does not automatically detect or repair inherited native counts.
Fresh Dart wrappers, identities, and counters isolate local generations; they
do not reset shared native state. This guidance applies to the private OnePub
`runtime_native_semaphores` migration and does not claim a fix or release for
the public `native_semaphores` package or the separate `runtime_named_locks`
layer.

## Open native error-capture issue

The adapters no longer read errno/GetLastError after native calls. An FFI
transition may clobber that state before Dart reads it; see
[Dart SDK issue #38832](https://github.com/dart-lang/sdk/issues/38832).
Only native return values determine success. POSIX `sem_wait` failure throws a
generic error, including interruption, without retrying. Every nonzero
`sem_trywait` result returns false and leaves ownership counters unchanged.
Callers may retry nonblocking acquisition until their own bounded, monotonic
deadline. Persistent native errors are therefore indistinguishable from
contention and can appear as a caller's timeout. No retry loop or deadline is
provided by this package.

POSIX `sem_open`, `sem_post`, `sem_close`, and `sem_unlink` failures throw generic
errors. In particular, an absent name is not accepted as successful unlink:
every nonzero `sem_unlink` result throws and leaves the operation retryable.
After this instance successfully unlinks, further local unlink calls still
return true without another native call. Windows waits retain their returned
`WAIT_*` status classification, but failure messages omit GetLastError.

Precise native error classification and diagnostics require a C shim that
captures the operation result and error together before returning to Dart.
Adapter tests cover ownership and lifecycle behavior, not reliable real-native
error capture or cross-platform release readiness.
