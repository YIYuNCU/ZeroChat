import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zerochat/widgets/input_bar.dart';

void main() {
  testWidgets('disabled send button preserves the draft', (tester) async {
    var sentText = '';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(
            sendEnabled: false,
            onSend: (text) => sentText = text,
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'wait for reply');
    await tester.tap(find.byKey(const ValueKey('send_button')));
    await tester.pump();

    expect(sentText, isEmpty);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      'wait for reply',
    );
  });

  testWidgets('format toolbar inserts paired tags around selection', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: InputBar())),
    );

    final textFieldFinder = find.byType(TextField);
    await tester.tap(textFieldFinder);
    await tester.enterText(textFieldFinder, '已经发生');
    await tester.pump();

    final editable = tester.widget<EditableText>(find.byType(EditableText));
    editable.controller.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 4,
    );
    await tester.tap(find.byKey(const ValueKey('format_事实')));
    await tester.pump();

    expect(editable.controller.text, '<事实>已经发生</事实>');
    expect(editable.controller.selection.start, 4);
    expect(editable.controller.selection.end, 8);
  });

  testWidgets('empty selection leaves caret inside new tag', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: InputBar())),
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('format_动作')));
    await tester.pump();

    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.controller.text, '<动作></动作>');
    expect(editable.controller.selection.baseOffset, 4);
    expect(editable.controller.selection.extentOffset, 4);
  });
}
