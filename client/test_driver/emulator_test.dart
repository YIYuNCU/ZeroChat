import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() async {
  final output = Directory(
    Platform.environment['ZEROCHAT_TEST_RESULTS'] ?? '../.android-test/results',
  );
  await output.create(recursive: true);
  await integrationDriver(
    timeout: const Duration(minutes: 10),
    responseDataCallback: (data) async {
      if (data != null) {
        await writeResponseData(
          data,
          testOutputFilename: 'emulator-results',
          destinationDirectory: output.path,
        );
      }
    },
  );
}
