import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zerochat/models/summary_config.dart';
import 'package:zerochat/widgets/prompt_editor.dart';

ConfigurablePrompt _prompt({int version = 1, String builtin = 'builtin'}) =>
    ConfigurablePrompt(
      id: 'test',
      title: 'Test prompt',
      group: 'chat',
      origin: 'chat',
      appliesTo: const ['chat'],
      builtin: builtin,
      version: version,
    );

class _Harness {
  Map<String, String>? result;
  bool closed = false;
}

Future<_Harness> _open(
  WidgetTester tester, {
  ConfigurablePrompt? prompt,
  Map<String, String> current = const {},
}) async {
  final harness = _Harness();
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              harness.result = await showPromptEditor(
                context,
                prompt: prompt ?? _prompt(),
                current: current,
                scopeLabel: 'Global',
              );
              harness.closed = true;
            },
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  return harness;
}

Future<void> _tapAndSettle(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

String _fieldText(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;

void main() {
  testWidgets('edited text writes __builtin__ and base version', (tester) async {
    final harness = await _open(tester, prompt: _prompt(version: 3));
    await tester.enterText(find.byType(TextField), 'edited');
    await _tapAndSettle(tester, '保存');
    expect(harness.result, {'__builtin__': 'edited', '__base_version__': '3'});
  });

  testWidgets('starts with the builtin text and unchanged text yields {}', (
    tester,
  ) async {
    final harness = await _open(tester);
    expect(_fieldText(tester), 'builtin');
    expect(find.text('追加'), findsNothing);
    expect(find.text('替换'), findsNothing);
    await _tapAndSettle(tester, '保存');
    expect(harness.closed, isTrue);
    expect(harness.result, isEmpty);
  });

  testWidgets('text equal to builtin after trim yields {}', (tester) async {
    final harness = await _open(tester);
    await tester.enterText(find.byType(TextField), '  builtin \n');
    await _tapAndSettle(tester, '保存');
    expect(harness.result, isEmpty);
  });

  testWidgets('blank text yields {}', (tester) async {
    final harness = await _open(tester);
    await tester.enterText(find.byType(TextField), '   ');
    await _tapAndSettle(tester, '保存');
    expect(harness.result, isEmpty);
  });

  testWidgets('starts with current __builtin__ override', (tester) async {
    final harness = await _open(
      tester,
      current: const {'__builtin__': 'mine', '__base_version__': '1'},
    );
    expect(_fieldText(tester), 'mine');
    await _tapAndSettle(tester, '保存');
    expect(harness.result, {'__builtin__': 'mine', '__base_version__': '1'});
  });

  testWidgets('legacy __append__ only override starts from builtin', (
    tester,
  ) async {
    final harness = await _open(
      tester,
      current: const {'__append__': 'old extra', '__base_version__': '1'},
    );
    expect(_fieldText(tester), 'builtin');
    await _tapAndSettle(tester, '保存');
    expect(harness.result, isEmpty);
  });

  testWidgets('placeholder helper text is shown', (tester) async {
    await _open(tester);
    expect(find.textContaining('{NO_REPLY_DIRECTIVE}'), findsOneWidget);
  });

  testWidgets('restore default returns empty map', (tester) async {
    final harness = await _open(
      tester,
      current: const {'__builtin__': 'mine', '__base_version__': '1'},
    );
    await _tapAndSettle(tester, '恢复默认');
    expect(harness.closed, isTrue);
    expect(harness.result, isNotNull);
    expect(harness.result, isEmpty);
  });

  testWidgets('cancel returns null', (tester) async {
    final harness = await _open(tester);
    await _tapAndSettle(tester, '取消');
    expect(harness.closed, isTrue);
    expect(harness.result, isNull);
  });

  testWidgets('shows stale banner only for older base version', (tester) async {
    await _open(
      tester,
      prompt: _prompt(version: 3),
      current: const {'__builtin__': 'mine', '__base_version__': '2'},
    );
    expect(find.text('内置提示词已更新，当前覆盖基于旧版'), findsOneWidget);
    expect(find.text('载入最新内置'), findsOneWidget);
  });

  testWidgets('no stale banner when base version is current', (tester) async {
    await _open(
      tester,
      prompt: _prompt(version: 3),
      current: const {'__builtin__': 'mine', '__base_version__': '3'},
    );
    expect(find.text('内置提示词已更新，当前覆盖基于旧版'), findsNothing);
    expect(find.text('载入最新内置'), findsNothing);
  });

  testWidgets('load latest builtin replaces text without saving', (
    tester,
  ) async {
    final harness = await _open(
      tester,
      prompt: _prompt(version: 3, builtin: 'new builtin'),
      current: const {'__builtin__': 'mine', '__base_version__': '2'},
    );
    expect(_fieldText(tester), 'mine');
    await _tapAndSettle(tester, '载入最新内置');
    expect(_fieldText(tester), 'new builtin');
    // Dialog is still open: nothing has been saved yet.
    expect(harness.closed, isFalse);
    await _tapAndSettle(tester, '保存');
    expect(harness.result, isEmpty);
  });

  test('buildPromptOverride rules', () {
    final prompt = _prompt(version: 4, builtin: 'abc');
    expect(buildPromptOverride(prompt, ''), isEmpty);
    expect(buildPromptOverride(prompt, ' abc '), isEmpty);
    expect(buildPromptOverride(prompt, 'abcd'), {
      '__builtin__': 'abcd',
      '__base_version__': '4',
    });
  });
}
