import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zerochat/models/summary_config.dart';
import 'package:zerochat/widgets/prompt_editor.dart';

ConfigurablePrompt _prompt({int version = 1}) => ConfigurablePrompt(
  id: 'test',
  title: 'Test prompt',
  group: 'chat',
  origin: 'chat',
  appliesTo: const ['chat'],
  builtin: 'builtin',
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

void main() {
  testWidgets('replace mode: edited text writes __builtin__ and base version', (
    tester,
  ) async {
    final harness = await _open(tester, prompt: _prompt(version: 3));
    await tester.enterText(find.byType(TextField), 'edited');
    await _tapAndSettle(tester, '保存');
    expect(harness.result, {'__builtin__': 'edited', '__base_version__': '3'});
  });

  testWidgets('replace mode: unchanged text yields empty map', (tester) async {
    final harness = await _open(tester);
    await _tapAndSettle(tester, '保存');
    expect(harness.closed, isTrue);
    expect(harness.result, isEmpty);
  });

  testWidgets('append mode writes __append__ and base version', (tester) async {
    final harness = await _open(tester, prompt: _prompt(version: 2));
    expect(find.text('追加在内置提示词之后，可继续获得内置更新'), findsNothing);
    await _tapAndSettle(tester, '追加');
    expect(find.text('追加在内置提示词之后，可继续获得内置更新'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'extra rules');
    await _tapAndSettle(tester, '保存');
    expect(harness.result, {
      '__append__': 'extra rules',
      '__base_version__': '2',
    });
  });

  testWidgets('append mode with blank text writes nothing', (tester) async {
    final harness = await _open(tester);
    await _tapAndSettle(tester, '追加');
    await tester.enterText(find.byType(TextField), '   ');
    await _tapAndSettle(tester, '保存');
    expect(harness.result, isEmpty);
  });

  testWidgets('starts in append mode when current has __append__', (
    tester,
  ) async {
    final harness = await _open(
      tester,
      current: const {'__append__': 'old extra', '__base_version__': '1'},
    );
    expect(find.text('追加内容'), findsOneWidget);
    expect(find.text('old extra'), findsOneWidget);
    await _tapAndSettle(tester, '保存');
    expect(harness.result, {'__append__': 'old extra', '__base_version__': '1'});
  });

  testWidgets('restore default returns empty map', (tester) async {
    final harness = await _open(
      tester,
      current: const {'__append__': 'x', '__base_version__': '1'},
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
  });

  testWidgets('no stale banner when base version is current', (tester) async {
    await _open(
      tester,
      prompt: _prompt(version: 3),
      current: const {'__builtin__': 'mine', '__base_version__': '3'},
    );
    expect(find.text('内置提示词已更新，当前覆盖基于旧版'), findsNothing);
  });
}
