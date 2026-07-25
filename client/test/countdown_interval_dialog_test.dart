import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zerochat/widgets/countdown_interval_dialog.dart';

void main() {
  Widget buildDialog() {
    return const MaterialApp(
      home: Scaffold(
        body: CountdownIntervalDialog(
          initialMinMinutes: 60,
          initialMaxMinutes: 240,
        ),
      ),
    );
  }

  testWidgets('hour arrows step by 0.1 hour and unit switch preserves minutes', (
    tester,
  ) async {
    await tester.pumpWidget(buildDialog());

    await tester.tap(find.byKey(const ValueKey('min-increment')));
    await tester.pump();

    var fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields.first.controller!.text, '1.1');

    await tester.tap(find.text('分钟'));
    await tester.pump();

    fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields.first.controller!.text, '66');
    expect(fields.last.controller!.text, '240');
  });

  testWidgets('minute arrows step by one and invalid ranges disable save', (
    tester,
  ) async {
    await tester.pumpWidget(buildDialog());
    await tester.tap(find.text('分钟'));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('max-decrement')));
    await tester.pump();
    var fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields.last.controller!.text, '239');

    await tester.enterText(find.byType(TextField).first, '300');
    await tester.enterText(find.byType(TextField).last, '200');
    await tester.pump();

    final saveButton = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '保存'),
    );
    expect(saveButton.onPressed, isNull);
    expect(find.text('不能大于最大值'), findsOneWidget);
  });
}
