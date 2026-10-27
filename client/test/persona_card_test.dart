import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zerochat/models/ai_model_profile.dart';
import 'package:zerochat/models/role.dart';
import 'package:zerochat/models/summary_config.dart';

void main() {
  Map<String, dynamic> baseJson() => {
    'id': 'r1',
    'name': 'Alice',
    'system_prompt': 'extra',
  };

  group('PersonaCard / Role', () {
    test('persona_card JSON round trip', () {
      final role = Role(
        id: 'r1',
        name: 'Alice',
        systemPrompt: 'extra',
        personaCard: const PersonaCard(
          identity: 'id',
          personality: 'pe',
          relationship: 're',
          scenario: 'sc',
          speakingStyle: 'st',
          boundaries: 'bo',
          exampleDialogues: [
            PersonaExample(user: 'hi', assistant: 'hello'),
            PersonaExample(user: 'bye', assistant: 'see you'),
          ],
        ),
      );
      final json = jsonDecode(role.toJsonString()) as Map<String, dynamic>;
      final card = json['persona_card'] as Map<String, dynamic>;
      expect(card['schema_version'], 1);
      expect(card['speaking_style'], 'st');
      expect(card['example_dialogues'], [
        {'user': 'hi', 'assistant': 'hello'},
        {'user': 'bye', 'assistant': 'see you'},
      ]);

      final restored = Role.fromJsonString(role.toJsonString());
      expect(restored.personaCard, role.personaCard);
      expect(restored.systemPrompt, 'extra');
    });

    test('legacy JSON without persona_card parses to empty card', () {
      final role = Role.fromJson(baseJson());
      expect(role.personaCard.isEmpty, isTrue);
      expect(role.personaCard.exampleDialogues, isEmpty);
    });

    test('empty card is still serialized with schema_version 1', () {
      final json = Role.fromJson(baseJson()).toJson();
      final card = json['persona_card'] as Map<String, dynamic>;
      expect(card['schema_version'], 1);
      expect(card['identity'], '');
      expect(card['example_dialogues'], isEmpty);
    });

    test('malformed persona_card is tolerated', () {
      expect(
        Role.fromJson({...baseJson(), 'persona_card': 'oops'}).personaCard,
        const PersonaCard(),
      );
      final role = Role.fromJson({
        ...baseJson(),
        'persona_card': {
          'identity': 123,
          'personality': 'ok',
          'example_dialogues': [
            {'user': 'u', 'assistant': 5},
            'bad',
            null,
            {'user': 'u2', 'assistant': 'a2'},
          ],
        },
      });
      expect(role.personaCard.identity, '');
      expect(role.personaCard.personality, 'ok');
      expect(role.personaCard.exampleDialogues, const [
        PersonaExample(user: 'u', assistant: ''),
        PersonaExample(user: 'u2', assistant: 'a2'),
      ]);
      expect(
        Role.fromJson({
          ...baseJson(),
          'persona_card': {'example_dialogues': 'nope'},
        }).personaCard.exampleDialogues,
        isEmpty,
      );
    });

    test('copyWith keeps and replaces personaCard', () {
      final role = Role.fromJson(baseJson()).copyWith(
        personaCard: const PersonaCard(identity: 'x'),
      );
      expect(role.copyWith(name: 'B').personaCard.identity, 'x');
      expect(
        role.copyWith(personaCard: const PersonaCard(identity: 'y'))
            .personaCard
            .identity,
        'y',
      );
    });
  });

  group('prompt overrides', () {
    test('normalizePromptOverrides keeps reserved keys', () {
      final result = normalizePromptOverrides({
        'chat.main': {
          '__builtin__': 'b',
          '__append__': 'a',
          '__base_version__': '2',
        },
        'bad': 'x',
        'nonString': {'__append__': 5},
      });
      expect(result, {
        'chat.main': {
          '__builtin__': 'b',
          '__append__': 'a',
          '__base_version__': '2',
        },
      });
    });

    test('model profile round trip keeps reserved keys', () {
      final profile = ModelApiProfile.fromJson({
        'id': 'p',
        'name': 'P',
        'api_url': 'https://example.com/v1',
        'model': 'm',
        'prompt_overrides': {
          'chat.main': {'__append__': 'a', '__base_version__': '3'},
        },
      });
      expect(profile.toJson()['prompt_overrides'], {
        'chat.main': {'__append__': 'a', '__base_version__': '3'},
      });
    });

    test('ConfigurablePrompt parses version tolerantly', () {
      ConfigurablePrompt parse(Object? version) => ConfigurablePrompt.fromJson({
        'id': 'p',
        if (version != null) 'version': version,
      });
      expect(parse(3).version, 3);
      expect(parse('4').version, 4);
      expect(parse(null).version, 1);
      expect(parse('abc').version, 1);
      expect(parse(0).version, 1);
      expect(parse(-2).version, 1);
    });

    test('stale detection follows __base_version__', () {
      const prompt = ConfigurablePrompt(
        id: 'p',
        title: 'P',
        group: '',
        origin: '',
        appliesTo: [],
        builtin: '',
        version: 3,
      );
      expect(prompt.isOverrideStale(const {}), isFalse);
      expect(prompt.isOverrideStale(const {'__append__': 'a'}), isTrue);
      expect(
        prompt.isOverrideStale(const {
          '__append__': 'a',
          '__base_version__': '2',
        }),
        isTrue,
      );
      expect(
        prompt.isOverrideStale(const {
          '__append__': 'a',
          '__base_version__': '3',
        }),
        isFalse,
      );
    });
  });
}
