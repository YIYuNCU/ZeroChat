import 'package:flutter_test/flutter_test.dart';
import 'package:zerochat/core/segment_sender.dart';

void main() {
  group('SegmentSender.splitMessage', () {
    test('merges a trailing action-only segment into dialogue', () {
      final segments = SegmentSender.splitMessage(
        '<dialogue>Hello</dialogue>\$<action>waves</action>',
      );

      expect(segments, ['<dialogue>Hello</dialogue><action>waves</action>']);
    });

    test('merges leading action and sound descriptions into dialogue', () {
      final segments = SegmentSender.splitMessage(
        '<action>walks over</action>\$<sound>footsteps</sound>\$'
        '<dialogue>I am here.</dialogue>',
      );

      expect(segments, [
        '<action>walks over</action><sound>footsteps</sound>'
            '<dialogue>I am here.</dialogue>',
      ]);
    });

    test('keeps separate dialogue-bearing segments', () {
      final segments = SegmentSender.splitMessage(
        '<dialogue>First.</dialogue>\$<dialogue>Second.</dialogue>',
      );

      expect(segments, [
        '<dialogue>First.</dialogue>',
        '<dialogue>Second.</dialogue>',
      ]);
    });

    test('merges any non-dialogue segment into dialogue', () {
      final segments = SegmentSender.splitMessage(
        '<dialogue>Got it.</dialogue>\$<psychology>feels relieved</psychology>',
      );

      expect(segments, [
        '<dialogue>Got it.</dialogue><psychology>feels relieved</psychology>',
      ]);
    });
  });
}
