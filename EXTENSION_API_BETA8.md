# Planned beta8 extension API migration

This hardening patch intentionally breaks part of the beta7 subclass API. It
is not a release or a claim that downstream `runtime_named_locks` is fixed.

`lockAcrossProcesses` and `unlockAcrossProcesses` remain **stateful** protected
operations on both platforms. A successful acquisition increments the process
count once; successful release decrements it once. Public `lock`/`unlock` do
not repeat those updates. Contention returns false without changing counters;
native failures throw before ownership changes. An existing outer acquisition
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
return false only for contention and throw for other failures; post/close/unlink
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
native failures to exceptions, and name-pointer getters to expose a pointer
only during the native call. Do not retain a pointer obtained from those getters.
Close is terminal; unlink requires separately established global quiescence.

## Open native error-capture issue

The Dart-side errno/GetLastError reads remain an unresolved portability issue:
an FFI transition may clobber the error before Dart reads it. A future native
wrapper must return operation result and captured error together. This affects
Unix wait contention classification and unlink's ENOENT handling as well as
open and other diagnostics; Windows wait classification uses returned WAIT_*
statuses, but diagnostics still have this issue. No retry, errno preservation,
or other Dart-side workaround is introduced here. Adapter tests do not establish
reliable real-native error capture or cross-platform release readiness.
