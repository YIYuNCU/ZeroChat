import 'package:flutter_test/flutter_test.dart';
import 'package:zerochat/models/role.dart';

void main() {
  test('showNoReply defaults off and survives JSON round-trip', () {
    final defaultRole = Role(id: 'role-1', name: '测试角色', systemPrompt: '测试');
    final visibleRole = defaultRole.copyWith(showNoReply: true);
    final restored = Role.fromJson(visibleRole.toJson());

    expect(defaultRole.showNoReply, isFalse);
    expect(restored.showNoReply, isTrue);
    expect(restored.toJson()['show_no_reply'], isTrue);
  });
}
