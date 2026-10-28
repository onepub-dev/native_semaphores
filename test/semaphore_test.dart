import 'package:test/test.dart';

import 'support/semaphore_workers.dart';

void main() {
  test('Several isolates acquire and close one named semaphore', () async {
    await exerciseIsolateWorkers(depth: 1);
  });
}
