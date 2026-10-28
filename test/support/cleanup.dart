// Attempt every cleanup step and preserve the original failure and stack.
// If the body succeeded, cleanup failures still fail the test/process.
Future<T> withCleanup<T>(
    Future<T> Function() body, List<Future<void> Function()> cleanup) async {
  Object? failure;
  StackTrace? trace;
  late T result;
  try {
    result = await body();
  } catch (error, stack) {
    failure = error;
    trace = stack;
  }
  for (final action in cleanup) {
    try {
      await action();
    } catch (error, stack) {
      failure ??= error;
      trace ??= stack;
    }
  }
  if (failure != null) Error.throwWithStackTrace(failure, trace!);
  return result;
}
