import unittest

from services.message_format import normalize_tags, strip_to_plain, NO_REPLY_DIRECTIVE


class NormalizeTagsTests(unittest.TestCase):
    def test_maps_english_aliases_to_chinese(self):
        result = normalize_tags("<message>你好</message><action>挥手</action>")
        self.assertEqual(result, "<对话>你好</对话><动作>挥手</动作>")

    def test_case_insensitive_and_spaces(self):
        self.assertEqual(normalize_tags("< Action >点头</ Action >"), "<动作>点头</动作>")

    def test_mixed_chinese_open_english_close(self):
        self.assertEqual(normalize_tags("<对话>混用</message>"), "<对话>混用</对话>")

    def test_no_reply_alias_variants(self):
        self.assertEqual(normalize_tags("<no_reply/>"), NO_REPLY_DIRECTIVE)
        self.assertEqual(normalize_tags("<noreply></noreply>"), NO_REPLY_DIRECTIVE)
        self.assertEqual(normalize_tags("<no-reply/>"), NO_REPLY_DIRECTIVE)

    def test_plain_text_untouched(self):
        self.assertEqual(normalize_tags("普通文本没有标签"), "普通文本没有标签")


class StripToPlainTests(unittest.TestCase):
    def test_keeps_dialogue_drops_action(self):
        text = "<对话>今天天气不错</对话><动作>抬头看天</动作>"
        self.assertEqual(strip_to_plain(text), "今天天气不错")

    def test_strips_english_alias_tags(self):
        text = "<message>出门散步</message><action>戴帽子</action>"
        self.assertEqual(strip_to_plain(text), "出门散步")

    def test_bare_text_kept(self):
        self.assertEqual(strip_to_plain("随手记一笔"), "随手记一笔")

    def test_no_reply_becomes_empty(self):
        self.assertEqual(strip_to_plain("<无回复/>"), "")


if __name__ == "__main__":
    unittest.main()
