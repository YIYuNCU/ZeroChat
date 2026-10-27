"""TTS 服务与 send_voice_message 工具的测试。"""
import base64
import io
import json
import os
import shutil
import tempfile
import time
import unittest
import uuid
import wave
from pathlib import Path
from unittest.mock import AsyncMock, patch

import httpx

from services import ai_service, tts_service
from services.ai_tools import execute_send_voice_message


def _wav_bytes(seconds: float = 0.5, rate: int = 8000) -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as writer:
        writer.setnchannels(1)
        writer.setsampwidth(2)
        writer.setframerate(rate)
        writer.writeframes(b"\x00\x00" * int(rate * seconds))
    return buffer.getvalue()


def _make_temp_root() -> Path:
    root = Path(tempfile.gettempdir()) / f"zerochat_tts_{uuid.uuid4().hex}"
    root.mkdir(parents=True, exist_ok=True)
    return root


def _client_factory(handler):
    def factory(timeout):
        return httpx.AsyncClient(transport=httpx.MockTransport(handler), timeout=timeout)
    return factory


def _resolved(provider: str, **params) -> dict:
    cfg = tts_service.default_tts_config()
    base = dict(cfg[provider])
    base.update(params)
    return {
        "enabled": True, "provider": provider, "timeout_seconds": 10,
        "max_chars": 300, "params": base, "role_enabled": True, "configured": True,
    }


class ConfigTests(unittest.TestCase):
    def test_sanitize_falls_back_and_clamps(self):
        cfg = tts_service.sanitize_tts_config({
            "enabled": 1, "provider": "bogus", "timeout_seconds": 9999, "max_chars": 1,
            "gpt_sovits": {"speed_factor": 99, "ref_audio_path": " /a.wav ", "junk": "x"},
        })
        self.assertTrue(cfg["enabled"])
        self.assertEqual(cfg["provider"], "mimo")
        self.assertEqual(cfg["timeout_seconds"], 180)
        self.assertEqual(cfg["max_chars"], 20)
        self.assertEqual(cfg["gpt_sovits"]["speed_factor"], 2.0)
        self.assertEqual(cfg["gpt_sovits"]["ref_audio_path"], "/a.wav")
        self.assertNotIn("junk", cfg["gpt_sovits"])
        self.assertEqual(tts_service.sanitize_tts_config("nope"), tts_service.default_tts_config())

    def test_update_keeps_existing_key_for_blank_or_masked_values(self):
        stored = tts_service.default_tts_config()
        stored["mimo"]["api_key"] = "sk-secret-0123456789"
        saved = {}

        def fake_save(values):
            saved.update(values)
            return True

        with patch("services.tts_service.settings_service.load_settings", return_value={"tts_config": stored}), \
                patch("services.tts_service.settings_service.save_settings", side_effect=fake_save):
            for incoming in ("", "***", "sk-secre...6789"):
                saved.clear()
                tts_service.update_tts_config({"mimo": {"api_key": incoming, "voice": "冰糖"}})
                self.assertEqual(saved["tts_config"]["mimo"]["api_key"], "sk-secret-0123456789")
                self.assertEqual(saved["tts_config"]["mimo"]["voice"], "冰糖")
            tts_service.update_tts_config({"mimo": {"api_key": "sk-new-key-0000000000"}})
            self.assertEqual(saved["tts_config"]["mimo"]["api_key"], "sk-new-key-0000000000")

    def test_public_config_never_contains_plaintext_key(self):
        cfg = tts_service.default_tts_config()
        cfg["qwen"]["api_key"] = "sk-abcdefghijklmnop"
        public = tts_service.public_tts_config(cfg)
        self.assertNotIn("api_key", public["qwen"])
        self.assertNotIn("sk-abcdefghijklmnop", json.dumps(public))
        self.assertIn("api_key_masked", public["qwen"])
        self.assertFalse(public["configured"])  # 当前 provider(mimo) 未配置 key

    def test_role_overrides_and_availability(self):
        cfg = tts_service.default_tts_config()
        cfg.update(enabled=True, provider="gpt_sovits")
        cfg["gpt_sovits"]["ref_audio_path"] = "/global.wav"
        role = {"id": "r1", "metadata": {"voice": {"ref_audio_path": "/role.wav", "prompt_lang": "en"}}}
        with patch("services.tts_service.settings_service.load_settings", return_value={"tts_config": cfg}):
            resolved = tts_service.resolve_tts_config(role)
            self.assertEqual(resolved["params"]["ref_audio_path"], "/role.wav")
            self.assertEqual(resolved["params"]["prompt_lang"], "en")
            self.assertTrue(tts_service.is_voice_available(role))
            off = {"id": "r1", "metadata": {"voice": {"enabled": False}}}
            self.assertFalse(tts_service.is_voice_available(off))

    def test_unavailable_when_disabled_or_unconfigured(self):
        cfg = tts_service.default_tts_config()
        with patch("services.tts_service.settings_service.load_settings", return_value={"tts_config": cfg}):
            self.assertFalse(tts_service.is_voice_available({"id": "r1"}))
        cfg["enabled"] = True
        with patch("services.tts_service.settings_service.load_settings", return_value={"tts_config": cfg}):
            self.assertFalse(tts_service.is_voice_available({"id": "r1"}))  # mimo 缺 key


class CleanTextTests(unittest.TestCase):
    def test_strips_tags_and_stage_directions(self):
        raw = "<动作>揉了揉眼睛</动作>你好呀（小声）*笑*，今天过得怎么样？<声音>叹气</声音>"
        self.assertEqual(tts_service.clean_tts_text(raw), "你好呀 ，今天过得怎么样？")

    def test_rejects_unspeakable(self):
        self.assertEqual(tts_service.clean_tts_text("（笑）"), "")
        self.assertEqual(tts_service.clean_tts_text("😀😀 ~~"), "")
        self.assertEqual(tts_service.clean_tts_text(None), "")


class AdapterTests(unittest.IsolatedAsyncioTestCase):
    async def test_mimo_request_and_response(self):
        seen = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["url"] = str(request.url)
            seen["key"] = request.headers.get("api-key")
            seen["body"] = json.loads(request.content)
            data = base64.b64encode(_wav_bytes()).decode()
            return httpx.Response(200, json={"choices": [{"message": {"audio": {"data": data}}}]})

        with patch("services.tts_service._make_client", _client_factory(handler)):
            audio = await tts_service.synthesize(
                _resolved("mimo", api_key="k-123", voice="冰糖"), "你好呀", "温柔",
            )
        self.assertEqual(seen["url"], "https://api.xiaomimimo.com/v1/chat/completions")
        self.assertEqual(seen["key"], "k-123")
        body = seen["body"]
        self.assertEqual(body["model"], "mimo-v2.5-tts")
        self.assertEqual(body["audio"], {"format": "wav", "voice": "冰糖"})
        self.assertEqual(body["messages"][-1], {"role": "assistant", "content": "你好呀"})
        self.assertEqual(body["messages"][0], {"role": "user", "content": "温柔"})
        self.assertEqual(audio.ext, ".wav")
        self.assertAlmostEqual(audio.duration_ms, 500, delta=5)

    async def test_mimo_without_style_has_only_assistant_message(self):
        seen = {}

        def handler(request):
            seen["body"] = json.loads(request.content)
            data = base64.b64encode(_wav_bytes()).decode()
            return httpx.Response(200, json={"choices": [{"message": {"audio": {"data": data}}}]})

        with patch("services.tts_service._make_client", _client_factory(handler)):
            await tts_service.synthesize(_resolved("mimo", api_key="k"), "嗨", "")
        self.assertEqual([m["role"] for m in seen["body"]["messages"]], ["assistant"])

    async def test_qwen_downloads_audio_url(self):
        calls = []

        def handler(request: httpx.Request) -> httpx.Response:
            calls.append((request.method, str(request.url)))
            if request.method == "POST":
                self.assertEqual(request.headers["authorization"], "Bearer qk")
                body = json.loads(request.content)
                self.assertEqual(body["model"], "qwen3-tts-flash")
                self.assertEqual(
                    body["input"],
                    {"text": "你好", "voice": "Cherry", "language_type": "Auto"},
                )
                return httpx.Response(200, json={"output": {"audio": {"url": "https://oss.example/a.wav"}}})
            return httpx.Response(200, content=_wav_bytes())

        with patch("services.tts_service._make_client", _client_factory(handler)), \
                patch("services.tts_service.is_safe_external_url", return_value=True):
            audio = await tts_service.synthesize(_resolved("qwen", api_key="qk"), "你好", "")
        self.assertEqual(calls[0][1], "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")
        self.assertEqual(calls[1], ("GET", "https://oss.example/a.wav"))
        self.assertEqual(audio.ext, ".wav")

    async def test_qwen_instruct_model_sends_instructions(self):
        seen = {}

        def handler(request):
            seen["body"] = json.loads(request.content)
            data = base64.b64encode(_wav_bytes()).decode()
            return httpx.Response(200, json={"output": {"audio": {"data": data}}})

        with patch("services.tts_service._make_client", _client_factory(handler)):
            await tts_service.synthesize(
                _resolved("qwen", api_key="qk", model="qwen3-tts-instruct-flash"), "你好", "温柔",
            )
        self.assertEqual(seen["body"]["input"]["instructions"], "温柔")

    async def test_qwen_rejects_unsafe_audio_url(self):
        def handler(request):
            return httpx.Response(200, json={"output": {"audio": {"url": "http://127.0.0.1/a.wav"}}})

        with patch("services.tts_service._make_client", _client_factory(handler)), \
                patch("services.tts_service.is_safe_external_url", return_value=False):
            with self.assertRaises(tts_service.TTSError):
                await tts_service.synthesize(_resolved("qwen", api_key="qk"), "你好", "")

    async def test_gpt_sovits_request_and_error(self):
        seen = {}

        def ok(request: httpx.Request) -> httpx.Response:
            seen["url"] = str(request.url)
            seen["body"] = json.loads(request.content)
            return httpx.Response(200, content=_wav_bytes())

        params = dict(ref_audio_path="/refs/a.wav", prompt_text="参考", prompt_lang="zh", text_lang="zh")
        with patch("services.tts_service._make_client", _client_factory(ok)):
            audio = await tts_service.synthesize(_resolved("gpt_sovits", **params), "你好", "忽略")
        self.assertEqual(seen["url"], "http://127.0.0.1:9880/tts")
        body = seen["body"]
        self.assertEqual(body["text"], "你好")
        self.assertEqual(body["ref_audio_path"], "/refs/a.wav")
        self.assertEqual(body["media_type"], "wav")
        self.assertFalse(body["streaming_mode"])
        self.assertNotIn("忽略", json.dumps(body, ensure_ascii=False))
        self.assertEqual(audio.mime, "audio/wav")

        def bad(request):
            return httpx.Response(400, json={"message": "ref_audio_path not exists"})

        with patch("services.tts_service._make_client", _client_factory(bad)):
            with self.assertRaises(tts_service.TTSError) as ctx:
                await tts_service.synthesize(_resolved("gpt_sovits", **params), "你好", "")
        self.assertIn("ref_audio_path not exists", str(ctx.exception))

    async def test_gpt_sovits_requires_reference_audio(self):
        with self.assertRaises(tts_service.TTSError):
            await tts_service.synthesize(_resolved("gpt_sovits", ref_audio_path=""), "你好", "")

    async def test_auth_failure_message_has_no_secret(self):
        def handler(request):
            return httpx.Response(401, json={"error": {"message": "bad key"}})

        with patch("services.tts_service._make_client", _client_factory(handler)):
            with self.assertRaises(tts_service.TTSError) as ctx:
                await tts_service.synthesize(_resolved("mimo", api_key="sk-top-secret"), "你好", "")
        self.assertIn("401", str(ctx.exception))
        self.assertNotIn("sk-top-secret", str(ctx.exception))

    async def test_timeout_maps_to_tts_error(self):
        def handler(request):
            raise httpx.ReadTimeout("slow", request=request)

        with patch("services.tts_service._make_client", _client_factory(handler)):
            with self.assertRaises(tts_service.TTSError):
                await tts_service.synthesize(_resolved("mimo", api_key="k"), "你好", "")

    async def test_oversized_audio_is_rejected(self):
        def handler(request):
            return httpx.Response(200, content=b"RIFF" + b"\x00" * (tts_service.MAX_AUDIO_BYTES + 1))

        with patch("services.tts_service._make_client", _client_factory(handler)):
            with self.assertRaises(tts_service.TTSError):
                await tts_service.synthesize(
                    _resolved("gpt_sovits", ref_audio_path="/a.wav"), "你好", "",
                )


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.root = _make_temp_root()
        patcher = patch("services.tts_service.ROLES_DIR", self.root)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)

    def test_save_and_resolve_path(self):
        audio = tts_service.SynthesizedAudio(_wav_bytes(), ".wav", "audio/wav", 500)
        path = tts_service.save_voice("role-1", audio)
        self.assertTrue(path.is_file())
        self.assertEqual(tts_service.voice_file_path("role-1", path.name), path.resolve())
        self.assertEqual(
            tts_service.voice_ref("role-1", path.name),
            f"ws-emoji://voice/role-1/{path.name}",
        )

    def test_path_traversal_and_bad_extension_rejected(self):
        for name in ("../x.wav", "a/b.wav", "..", "voice.txt"):
            with self.assertRaises(ValueError):
                tts_service.voice_file_path("role-1", name)
        with self.assertRaises(ValueError):
            tts_service.voice_file_path("../evil", "a.wav")

    def test_cleanup_by_count_and_age(self):
        directory = tts_service.voices_dir("role-1", create=True)
        now = time.time()
        for index in range(5):
            file = directory / f"{index}.wav"
            file.write_bytes(b"RIFF")
            os.utime(file, (now - index, now - index))
        old = directory / "old.wav"
        old.write_bytes(b"RIFF")
        os.utime(old, (now - 40 * 86400, now - 40 * 86400))
        removed = tts_service.cleanup_role_voices("role-1", max_files=3, now=now)
        remaining = sorted(p.name for p in directory.iterdir())
        self.assertEqual(remaining, ["0.wav", "1.wav", "2.wav"])
        self.assertEqual(removed, 3)


class SynthesizeForRoleTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.root = _make_temp_root()
        patcher = patch("services.tts_service.ROLES_DIR", self.root)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        cfg = tts_service.default_tts_config()
        cfg.update(enabled=True, max_chars=20)
        cfg["mimo"]["api_key"] = "k"
        cfg["mimo"]["style"] = "甜美"
        settings_patch = patch(
            "services.tts_service.settings_service.load_settings", return_value={"tts_config": cfg},
        )
        settings_patch.start()
        self.addCleanup(settings_patch.stop)

    async def test_success_builds_delivery_and_combines_style(self):
        captured = {}

        async def fake_synth(resolved, text, style=""):
            captured.update(text=text, style=style)
            return tts_service.SynthesizedAudio(_wav_bytes(), ".wav", "audio/wav", 500)

        with patch("services.tts_service.synthesize", side_effect=fake_synth):
            delivery = await tts_service.synthesize_for_role({"id": "role-1"}, "<动作>笑</动作>你好呀", "温柔")
        self.assertEqual(captured, {"text": "你好呀", "style": "甜美，温柔"})
        self.assertTrue(delivery["ref"].startswith("ws-emoji://voice/role-1/"))
        self.assertEqual(delivery["text"], "你好呀")
        self.assertEqual(delivery["duration_ms"], 500)
        self.assertTrue(tts_service.voice_file_path("role-1", delivery["filename"]).is_file())

    async def test_too_long_and_empty_text_fail_without_calling_provider(self):
        with patch("services.tts_service.synthesize", new=AsyncMock()) as synth:
            with self.assertRaises(tts_service.TTSError):
                await tts_service.synthesize_for_role({"id": "role-1"}, "好" * 50, "")
            with self.assertRaises(tts_service.TTSError):
                await tts_service.synthesize_for_role({"id": "role-1"}, "（笑）", "")
        synth.assert_not_called()


class VoiceToolTests(unittest.IsolatedAsyncioTestCase):
    async def test_executor_success_failure_and_cap(self):
        delivery = {"text": "你好", "ref": "ws-emoji://voice/r/a.wav", "filename": "a.wav", "duration_ms": 2000, "mime": "audio/wav"}
        with patch("services.tts_service.synthesize_for_role", new=AsyncMock(return_value=delivery)):
            result, got = await execute_send_voice_message({"id": "r"}, "你好", "", 0)
        self.assertEqual(got, delivery)
        self.assertIn("语音已发送", result)

        with patch(
            "services.tts_service.synthesize_for_role",
            new=AsyncMock(side_effect=tts_service.TTSError("TTS 请求超时")),
        ):
            result, got = await execute_send_voice_message({"id": "r"}, "你好", "", 0)
        self.assertIsNone(got)
        self.assertIn("TTS 请求超时", result)

        with patch("services.tts_service.synthesize_for_role", new=AsyncMock(side_effect=RuntimeError("boom"))):
            result, got = await execute_send_voice_message({"id": "r"}, "你好", "", 0)
        self.assertIsNone(got)
        self.assertNotIn("boom", result)

        with patch("services.tts_service.synthesize_for_role", new=AsyncMock()) as synth:
            result, got = await execute_send_voice_message(
                {"id": "r"}, "你好", "", tts_service.MAX_VOICES_PER_TURN,
            )
        synth.assert_not_called()
        self.assertIsNone(got)

    async def test_tool_loop_collects_voices_and_logs(self):
        delivery = {"text": "晚安", "ref": "ws-emoji://voice/r/a.wav", "filename": "a.wav", "duration_ms": 1000, "mime": "audio/wav"}
        initial = {
            "assistant_content": None,
            "tool_calls": [{
                "id": "call_v", "type": "function",
                "function": {"name": "send_voice_message", "arguments": {"text": "晚安", "style": "轻声"}},
            }],
        }
        final = {"success": True, "content": "好梦"}
        messages = []
        with patch(
            "services.ai_service.execute_send_voice_message",
            new=AsyncMock(return_value=("语音已发送", delivery)),
        ) as executor, patch(
            "services.ai_service._call_with_role_config", new=AsyncMock(return_value=final),
        ):
            result = await ai_service._handle_tool_calls(initial, messages, {"id": "r"}, [])
        executor.assert_awaited_once_with({"id": "r"}, "晚安", "轻声", 0)
        self.assertEqual(result["_voices_called"], [delivery])
        self.assertEqual(result["_tool_calls_log"][0]["name"], "send_voice_message")
        tool_msgs = [m for m in messages if m["role"] == "tool"]
        self.assertEqual(tool_msgs[0]["content"], "语音已发送")

    async def test_tool_exposure_and_prompt_gating(self):
        captured = {}

        async def call_model(_role, messages, **kwargs):
            captured["tools"] = kwargs.get("tools") or []
            captured["system"] = messages[0]["content"]
            return {"success": True, "content": "ok"}

        def names():
            return {t["function"]["name"] for t in captured["tools"]}

        with patch("services.ai_service._call_with_role_config", side_effect=call_model):
            await ai_service.generate_with_role({"id": "r"}, "hi", enable_voice=False)
            self.assertNotIn("send_voice_message", names())
            self.assertNotIn("send_voice_message", captured["system"])
            await ai_service.generate_with_role({"id": "r"}, "hi", enable_voice=True)
            self.assertIn("send_voice_message", names())
            self.assertIn("send_voice_message", captured["system"])


class PipelineVoiceTests(unittest.IsolatedAsyncioTestCase):
    def test_transcript_helper(self):
        from routers.ai_behavior import _with_voice_transcripts

        voices = [{"text": "晚安"}, {"text": " "}]
        self.assertEqual(_with_voice_transcripts("好梦", voices, plain=True), "好梦\n[语音] 晚安")
        self.assertEqual(_with_voice_transcripts("", voices, plain=False), "<对话>[语音] 晚安</对话>")
        self.assertEqual(_with_voice_transcripts("hi", [], plain=True), "hi")


if __name__ == "__main__":
    unittest.main()
