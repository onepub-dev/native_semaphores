# Planned beta8 extension API migration

This hardening patch intentionally breaks part of the beta7 subclass API. It
is not a release or a claim that downstream `runtime_named_locks` is fixed.

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
names before adopting beta8. Move native behavior to `UnixSemaphoreCalls` or
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

The existing patch also changes `SemaphoreCount.all` to object-local storage,
reported native failures to exceptions (with the POSIX nonblocking limitation
below), and name-pointer getters to expose a pointer only during the native
call. Do not retain a pointer obtained from those getters.
Close is terminal; unlink requires separately established global quiescence.

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
