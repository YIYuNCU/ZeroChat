import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zerochat/models/role_prompt_overrides.dart';
import 'package:zerochat/models/summary_config.dart';
import 'package:zerochat/widgets/role_prompt_overrides_section.dart';

ConfigurablePrompt _prompt(
  String id, {
  List<String> appliesTo = const ['chat'],
  int version = 1,
  String builtin = 'builtin text',
}) => ConfigurablePrompt(
  id: id,
  title: 'Title $id',
  group: 'chat',
  origin: 'chat',
  appliesTo: appliesTo,
  builtin: builtin,
  version: version,
);

void main() {
  group('role prompt override metadata helpers', () {
    const override = {'__builtin__': 'mine', '__base_version__': '2'};

    test('read returns empty for missing or malformed data', () {
      expect(readRolePromptOverrides(const {}), isEmpty);
      expect(
        readRolePromptOverrides(const {'prompt_overrides': 'oops'}),
        isEmpty,
      );
      expect(readRolePromptOverride(const {}, 'a'), isEmpty);
    });

    test('write adds an override and keeps other metadata keys', () {
      final metadata = <String, dynamic>{'ai_model': 'legacy', 'x': 1};
      final next = writeRolePromptOverride(metadata, 'a', override);
      expect(next['ai_model'], 'legacy');
      expect(next['x'], 1);
      expect(readRolePromptOverride(next, 'a'), override);
      // 入参不被修改。
      expect(metadata.containsKey('prompt_overrides'), isFalse);
    });

    test('write keeps other prompt overrides', () {
      final first = writeRolePromptOverride(const {}, 'a', override);
      final second = writeRolePromptOverride(first, 'b', {
        '__builtin__': 'other',
        '__base_version__': '1',
      });
      expect(readRolePromptOverrides(second).keys, unorderedEquals(['a', 'b']));
    });

    test('empty override removes the id, then the whole key', () {
      var metadata = writeRolePromptOverride({'keep': true}, 'a', override);
      metadata = writeRolePromptOverride(metadata, 'b', override);
      metadata = writeRolePromptOverride(metadata, 'a', const {});
      expect(readRolePromptOverrides(metadata).keys, ['b']);
      metadata = writeRolePromptOverride(metadata, 'b', const {});
      expect(metadata.containsKey('prompt_overrides'), isFalse);
      expect(metadata, {'keep': true});
    });

    test('removing a missing id on empty metadata stays empty', () {
      expect(writeRolePromptOverride(const {}, 'a', const {}), isEmpty);
    });
  });

  group('RolePromptOverridesSection', () {
    Future<List<Map<String, dynamic>>> pump(
      WidgetTester tester, {
      required Map<String, dynamic> metadata,
      required PromptRegistryLoader loader,
    }) async {
      final changes = <Map<String, dynamic>>[];
      var current = metadata;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => SingleChildScrollView(
                child: RolePromptOverridesSection(
                  roleName: 'Alice',
                  metadata: current,
                  loadRegistry: loader,
                  onChanged: (next) {
                    changes.add(next);
                    setState(() => current = next);
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return changes;
    }

    testWidgets('lists only chat prompts with badges', (tester) async {
      await pump(
        tester,
        metadata: {
          'prompt_overrides': {
            'chat.b': {'__builtin__': 'mine', '__base_version__': '1'},
          },
        },
        loader: ({bool force = false}) async => {
          'chat.a': _prompt('chat.a'),
          'chat.b': _prompt('chat.b', version: 2),
          'summary.x': _prompt('summary.x', appliesTo: const ['summary']),
        },
      );
      expect(find.text('提示词（仅此角色）'), findsOneWidget);
      expect(find.text('Title chat.a'), findsOneWidget);
      expect(find.text('Title chat.b'), findsOneWidget);
      expect(find.text('Title summary.x'), findsNothing);
      expect(find.text('已自定义'), findsOneWidget);
      expect(find.text('基于旧版'), findsOneWidget);
    });

    testWidgets('editing writes into metadata and keeps other keys', (
      tester,
    ) async {
      final changes = await pump(
        tester,
        metadata: {'ai_model': 'legacy'},
        loader: ({bool force = false}) async => {'chat.a': _prompt('chat.a')},
      );
      await tester.tap(find.text('Title chat.a'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Alice'), findsWidgets);
      await tester.enterText(find.byType(TextField), 'role specific');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(changes, hasLength(1));
      expect(changes.single['ai_model'], 'legacy');
      expect(readRolePromptOverride(changes.single, 'chat.a'), {
        '__builtin__': 'role specific',
        '__base_version__': '1',
      });
      expect(find.text('已自定义'), findsOneWidget);
    });

    testWidgets('restore default removes the override and the key', (
      tester,
    ) async {
      final changes = await pump(
        tester,
        metadata: {
          'prompt_overrides': {
            'chat.a': {'__builtin__': 'mine', '__base_version__': '1'},
          },
        },
        loader: ({bool force = false}) async => {'chat.a': _prompt('chat.a')},
      );
      await tester.tap(find.text('Title chat.a'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('恢复默认'));
      await tester.pumpAndSettle();
      expect(changes, hasLength(1));
      expect(changes.single.containsKey('prompt_overrides'), isFalse);
      expect(find.text('已自定义'), findsNothing);
    });

    testWidgets('cancel does not report a change', (tester) async {
      final changes = await pump(
        tester,
        metadata: const {},
        loader: ({bool force = false}) async => {'chat.a': _prompt('chat.a')},
      );
      await tester.tap(find.text('Title chat.a'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(changes, isEmpty);
    });

    testWidgets('load failure shows an error and retry reloads', (
      tester,
    ) async {
      var calls = 0;
      await pump(
        tester,
        metadata: const {},
        loader: ({bool force = false}) async {
          calls++;
          if (calls == 1) throw Exception('offline');
          return {'chat.a': _prompt('chat.a')};
        },
      );
      expect(find.textContaining('加载失败'), findsOneWidget);
      expect(find.text('Title chat.a'), findsNothing);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('Title chat.a'), findsOneWidget);
      expect(find.textContaining('加载失败'), findsNothing);
    });

    testWidgets('empty registry is treated as a load failure', (tester) async {
      await pump(
        tester,
        metadata: const {},
        loader: ({bool force = false}) async => {},
      );
      expect(find.textContaining('加载失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });
  });
}
