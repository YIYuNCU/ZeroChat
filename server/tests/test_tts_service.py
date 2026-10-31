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


def _default_profile(saved: dict) -> dict:
    """update_tts_config 保存出的 tts_config 里的默认档案。"""
    store = saved["tts_config"]
    return next(p for p in store["profiles"] if p["id"] == store["default_profile_id"])


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
                self.assertEqual(_default_profile(saved)["mimo"]["api_key"], "sk-secret-0123456789")
                self.assertEqual(_default_profile(saved)["mimo"]["voice"], "冰糖")
            tts_service.update_tts_config({"mimo": {"api_key": "sk-new-key-0000000000"}})
            self.assertEqual(_default_profile(saved)["mimo"]["api_key"], "sk-new-key-0000000000")

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


class CustomProviderConfigTests(unittest.TestCase):
    def _section(self, **overrides) -> dict:
        section = dict(tts_service.default_tts_config()["custom"])
        section.update(api_url="https://tts.example/v1/speech", **overrides)
        return section

    def test_default_template_is_valid_and_not_ready_without_url(self):
        cfg = tts_service.default_tts_config()
        tts_service.validate_custom_section(cfg["custom"])  # 未填地址：跳过
        tts_service.validate_custom_section(self._section())
        self.assertFalse(tts_service.public_tts_config(cfg)["configured"])
        cfg.update(provider="custom")
        cfg["custom"]["api_url"] = "https://tts.example/v1/speech"
        self.assertTrue(tts_service.public_tts_config(cfg)["configured"])

    def test_sanitize_normalizes_enums_and_keeps_templates(self):
        cfg = tts_service.sanitize_tts_config({
            "custom": {"method": "get", "response_type": "BASE64", "body": '{"t": "{{text}}"}' + " " * 5000},
        })
        self.assertEqual(cfg["custom"]["method"], "GET")
        self.assertEqual(cfg["custom"]["response_type"], "base64")
        self.assertEqual(cfg["custom"]["body"], '{"t": "{{text}}"}')
        bad = tts_service.sanitize_tts_config({"custom": {"method": "DELETE", "response_type": "zip"}})
        self.assertEqual(bad["custom"]["method"], "POST")
        self.assertEqual(bad["custom"]["response_type"], "binary")

    def test_validation_errors(self):
        cases = {
            "headers": ("{not json", "请求头"),
            "body": ("[1, 2]{{text}}", "请求体"),
        }
        for key, (value, label) in cases.items():
            with self.assertRaises(tts_service.TTSError) as ctx:
                tts_service.validate_custom_section(self._section(**{key: value}))
            self.assertIn(label, str(ctx.exception))
        with self.assertRaises(tts_service.TTSError) as ctx:
            tts_service.validate_custom_section(self._section(body='{"t": "{{txt}}"}'))
        self.assertIn("{{txt}}", str(ctx.exception))
        with self.assertRaises(tts_service.TTSError):
            tts_service.validate_custom_section(self._section(body='{"t": "hi"}'))  # 缺 {{text}}
        with self.assertRaises(tts_service.TTSError):
            tts_service.validate_custom_section(self._section(response_type="url", response_path=""))
        with self.assertRaises(tts_service.TTSError):
            tts_service.validate_custom_section(self._section(method="GET", body='["{{text}}"]'))

    def test_update_rejects_invalid_custom_section_and_keeps_key(self):
        stored = tts_service.default_tts_config()
        stored["custom"]["api_key"] = "sk-custom-0123456789"
        saved = {}

        def fake_save(values):
            saved.update(values)
            return True

        with patch("services.tts_service.settings_service.load_settings", return_value={"tts_config": stored}), \
                patch("services.tts_service.settings_service.save_settings", side_effect=fake_save):
            with self.assertRaises(tts_service.TTSError):
                tts_service.update_tts_config({"custom": {"api_url": "https://x.example", "body": "oops"}})
            self.assertEqual(saved, {})
            tts_service.update_tts_config({"custom": {"api_url": "https://x.example/tts", "api_key": ""}})
            self.assertEqual(_default_profile(saved)["custom"]["api_key"], "sk-custom-0123456789")
            self.assertEqual(_default_profile(saved)["custom"]["api_url"], "https://x.example/tts")

    def test_role_overrides_apply_to_custom(self):
        cfg = tts_service.default_tts_config()
        cfg.update(enabled=True, provider="custom")
        cfg["custom"].update(api_url="https://x.example/tts", voice="global")
        role = {"id": "r1", "metadata": {"voice": {"voice": "role-voice", "ref_audio_path": "/ignored.wav"}}}
        with patch("services.tts_service.settings_service.load_settings", return_value={"tts_config": cfg}):
            resolved = tts_service.resolve_tts_config(role)
        self.assertEqual(resolved["params"]["voice"], "role-voice")
        self.assertTrue(resolved["configured"])


class CustomAdapterTests(unittest.IsolatedAsyncioTestCase):
    def _params(self, **overrides) -> dict:
        params = {
            "api_url": "https://tts.example/v1/speech",
            "api_key": "ck-123", "model": "m-1", "voice": "alloy",
        }
        params.update(overrides)
        return params

    async def test_default_template_posts_json_and_reads_binary(self):
        seen = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["method"] = request.method
            seen["url"] = str(request.url)
            seen["auth"] = request.headers.get("authorization")
            seen["body"] = json.loads(request.content)
            return httpx.Response(200, content=_wav_bytes(), headers={"content-type": "audio/wav"})

        with patch("services.tts_service._make_client", _client_factory(handler)):
            audio = await tts_service.synthesize(_resolved("custom", **self._params()), '他说"你好"\n再见', "温柔")
        self.assertEqual(seen["method"], "POST")
        self.assertEqual(seen["url"], "https://tts.example/v1/speech")
        self.assertEqual(seen["auth"], "Bearer ck-123")
        # 引号 / 换行经 JSON 解析后再替换，结构不会被破坏。
        self.assertEqual(seen["body"], {"model": "m-1", "input": '他说"你好"\n再见', "voice": "alloy"})
        self.assertEqual(audio.ext, ".wav")

    async def test_custom_headers_style_placeholder_and_nested_body(self):
        seen = {}

        def handler(request):
            seen["key"] = request.headers.get("x-api-key")
            seen["body"] = json.loads(request.content)
            return httpx.Response(200, content=_wav_bytes())

        params = self._params(
            headers='{"X-Api-Key": "{{api_key}}"}',
            body='{"payload": {"items": ["{{text}}", "{{style}}"], "speed": 1.2, "stream": false}}',
        )
        with patch("services.tts_service._make_client", _client_factory(handler)):
            await tts_service.synthesize(_resolved("custom", **params), "嗨", "开心")
        self.assertEqual(seen["key"], "ck-123")
        self.assertEqual(seen["body"], {"payload": {"items": ["嗨", "开心"], "speed": 1.2, "stream": False}})

    async def test_get_encodes_url_and_query(self):
        seen = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen["method"] = request.method
            seen["url"] = request.url
            seen["body"] = request.content
            return httpx.Response(200, content=_wav_bytes())

        params = self._params(
            method="GET", api_url="https://tts.example/say/{{voice}}?q={{text}}",
            headers="", body='{"fmt": "wav", "lang": "{{style}}"}',
        )
        with patch("services.tts_service._make_client", _client_factory(handler)):
            await tts_service.synthesize(_resolved("custom", **params), "你好 & 世界", "zh")
        self.assertEqual(seen["method"], "GET")
        self.assertEqual(seen["url"].params["q"], "你好 & 世界")
        self.assertEqual(seen["url"].params["fmt"], "wav")
        self.assertEqual(seen["url"].params["lang"], "zh")
        self.assertEqual(seen["url"].path, "/say/alloy")
        self.assertEqual(seen["body"], b"")

    async def test_base64_response_with_path_and_data_uri(self):
        data = base64.b64encode(_wav_bytes()).decode()
        for value in (data, f"data:audio/wav;base64,{data}"):
            def handler(request, value=value):
                return httpx.Response(200, json={"result": [{"audio": value}]})

            params = self._params(response_type="base64", response_path="result[0].audio")
            with patch("services.tts_service._make_client", _client_factory(handler)):
                audio = await tts_service.synthesize(_resolved("custom", **params), "你好", "")
            self.assertAlmostEqual(audio.duration_ms, 500, delta=5)

    async def test_url_response_downloads_audio_and_blocks_unsafe_url(self):
        calls = []

        def handler(request: httpx.Request) -> httpx.Response:
            calls.append((request.method, str(request.url)))
            if request.method == "POST":
                return httpx.Response(200, json={"data": {"url": "https://cdn.example/a.wav"}})
            return httpx.Response(200, content=_wav_bytes())

        params = self._params(response_type="url", response_path="data.url")
        with patch("services.tts_service._make_client", _client_factory(handler)), \
                patch("services.tts_service.is_safe_external_url", return_value=True):
            await tts_service.synthesize(_resolved("custom", **params), "你好", "")
        self.assertEqual(calls[1], ("GET", "https://cdn.example/a.wav"))

        with patch("services.tts_service._make_client", _client_factory(handler)), \
                patch("services.tts_service.is_safe_external_url", return_value=False):
            with self.assertRaises(tts_service.TTSError):
                await tts_service.synthesize(_resolved("custom", **params), "你好", "")

    async def test_response_errors_are_friendly(self):
        def json_handler(request):
            return httpx.Response(200, json={"code": 0})

        with patch("services.tts_service._make_client", _client_factory(json_handler)):
            with self.assertRaises(tts_service.TTSError) as ctx:  # 声明 binary 却返回 JSON
                await tts_service.synthesize(_resolved("custom", **self._params()), "你好", "")
            self.assertIn("JSON", str(ctx.exception))
            missing = self._params(response_type="base64", response_path="data.audio")
            with self.assertRaises(tts_service.TTSError) as ctx:
                await tts_service.synthesize(_resolved("custom", **missing), "你好", "")
            self.assertIn("data.audio", str(ctx.exception))

        def ogg_handler(request):
            return httpx.Response(200, content=b"OggS" + b"\x00" * 64)

        with patch("services.tts_service._make_client", _client_factory(ogg_handler)):
            with self.assertRaises(tts_service.TTSError):
                await tts_service.synthesize(_resolved("custom", **self._params()), "你好", "")

        def denied(request):
            return httpx.Response(403, json={"detail": "nope"})

        with patch("services.tts_service._make_client", _client_factory(denied)):
            with self.assertRaises(tts_service.TTSError) as ctx:
                await tts_service.synthesize(_resolved("custom", **self._params(api_key="ck-secret")), "你好", "")
        self.assertNotIn("ck-secret", str(ctx.exception))

    async def test_invalid_templates_raise_tts_error(self):
        for bad in (self._params(headers="{oops"), self._params(body="[1]", method="GET"),
                    self._params(api_url="ftp://x.example")):
            with self.assertRaises(tts_service.TTSError):
                await tts_service.synthesize(_resolved("custom", **bad), "你好", "")


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


class TtsProfileTests(unittest.TestCase):
    """多档案：迁移、增删改、默认档案、角色选择。"""

    def _store(self, **extra):
        store = {
            "enabled": True,
            "default_profile_id": "a",
            "profiles": [
                {"id": "a", "name": "甲", "provider": "mimo",
                 "mimo": {"api_key": "sk-a-0123456789", "voice": "冰糖"}},
                {"id": "b", "name": "乙", "provider": "gpt_sovits",
                 "gpt_sovits": {"ref_audio_path": "/b.wav"}},
            ],
        }
        store.update(extra)
        return store

    def _patched(self, store):
        saved = {}

        def fake_save(values):
            saved.update(values)
            return True

        return saved, patch(
            "services.tts_service.settings_service.load_settings", return_value={"tts_config": store},
        ), patch("services.tts_service.settings_service.save_settings", side_effect=fake_save)

    def test_legacy_flat_config_migrates_to_default_profile(self):
        legacy = tts_service.default_tts_config()
        legacy.update(enabled=True, provider="qwen")
        legacy["qwen"]["api_key"] = "sk-legacy-0123456789"
        store = tts_service.sanitize_tts_store(legacy)
        self.assertTrue(store["enabled"])
        self.assertEqual(store["default_profile_id"], "default")
        self.assertEqual([p["id"] for p in store["profiles"]], ["default"])
        self.assertEqual(store["profiles"][0]["provider"], "qwen")
        self.assertEqual(store["profiles"][0]["qwen"]["api_key"], "sk-legacy-0123456789")
        self.assertNotIn("enabled", store["profiles"][0])

    def test_sanitize_store_repairs_ids_and_default(self):
        store = tts_service.sanitize_tts_store({
            "enabled": 1, "default_profile_id": "ghost",
            "profiles": [
                {"id": "ok", "name": "  "}, {"id": "ok", "name": "dup"}, {"id": "bad id!"}, "junk",
            ],
        })
        self.assertEqual([p["id"] for p in store["profiles"]], ["ok"])
        self.assertEqual(store["profiles"][0]["name"], "未命名")
        self.assertEqual(store["default_profile_id"], "ok")
        empty = tts_service.sanitize_tts_store({"profiles": []})
        self.assertEqual((empty["profiles"], empty["default_profile_id"]), ([], ""))

    def test_public_config_lists_profiles_and_mirrors_default(self):
        public = tts_service.public_tts_config(self._store())
        self.assertEqual([p["id"] for p in public["profiles"]], ["a", "b"])
        self.assertTrue(public["profiles"][0]["configured"])
        self.assertTrue(public["profiles"][1]["configured"])
        self.assertEqual(public["default_profile_id"], "a")
        # 顶层镜像默认档案，旧客户端可继续读取
        self.assertEqual(public["provider"], "mimo")
        self.assertTrue(public["configured"])
        self.assertIn("api_key_masked", public["mimo"])
        self.assertNotIn("sk-a-0123456789", json.dumps(public))

    def test_update_upserts_profiles_and_keeps_masked_secret(self):
        saved, load, save = self._patched(self._store())
        with load, save:
            tts_service.update_tts_config({"profiles": [
                {"id": "a", "name": "甲2", "mimo": {"api_key": "sk-a-0123...", "voice": "茉莉"}},
                {"id": "c", "name": "丙", "provider": "qwen", "qwen": {"api_key": "sk-c-0123456789"}},
            ]})
        profiles = {p["id"]: p for p in saved["tts_config"]["profiles"]}
        self.assertEqual(list(profiles), ["a", "b", "c"])
        self.assertEqual(profiles["a"]["name"], "甲2")
        self.assertEqual(profiles["a"]["mimo"]["api_key"], "sk-a-0123456789")
        self.assertEqual(profiles["a"]["mimo"]["voice"], "茉莉")
        self.assertEqual(profiles["b"]["gpt_sovits"]["ref_audio_path"], "/b.wav")
        self.assertEqual(profiles["c"]["provider"], "qwen")
        self.assertEqual(saved["tts_config"]["default_profile_id"], "a")

    def test_new_profile_keeps_defaults_for_blank_fields(self):
        saved, load, save = self._patched(self._store())
        with load, save:
            tts_service.update_tts_config({"profiles": [
                {"id": "n", "name": "新", "mimo": {"api_url": "", "model": " ", "voice": "茉莉"}},
                {"id": "a", "mimo": {"voice": ""}},
            ]})
        profiles = {p["id"]: p for p in saved["tts_config"]["profiles"]}
        defaults = tts_service.default_tts_config()["mimo"]
        self.assertEqual(profiles["n"]["mimo"]["api_url"], defaults["api_url"])
        self.assertEqual(profiles["n"]["mimo"]["model"], defaults["model"])
        self.assertEqual(profiles["n"]["mimo"]["voice"], "茉莉")
        self.assertEqual(profiles["a"]["mimo"]["voice"], "")  # 已有档案允许清空

    def test_update_generates_id_for_new_profile_without_valid_id(self):
        saved, load, save = self._patched(self._store())
        with load, save:
            tts_service.update_tts_config({"profiles": [{"name": "新"}, {"id": "no good", "name": "新2"}]})
        ids = [p["id"] for p in saved["tts_config"]["profiles"]]
        self.assertEqual(len(ids), 4)
        self.assertEqual(len(set(ids)), 4)

    def test_update_delete_and_default(self):
        saved, load, save = self._patched(self._store())
        with load, save:
            tts_service.update_tts_config({"default_profile_id": "b", "delete_profile_ids": ["a"]})
        self.assertEqual([p["id"] for p in saved["tts_config"]["profiles"]], ["b"])
        self.assertEqual(saved["tts_config"]["default_profile_id"], "b")
        saved2, load2, save2 = self._patched(self._store())
        with load2, save2:
            tts_service.update_tts_config({"delete_profile_ids": ["a"]})
        self.assertEqual(saved2["tts_config"]["default_profile_id"], "b")  # 默认档案被删后顺延

    def test_update_rejects_unknown_default_and_too_many_profiles(self):
        saved, load, save = self._patched(self._store())
        with load, save:
            with self.assertRaises(tts_service.TTSError):
                tts_service.update_tts_config({"default_profile_id": "ghost"})
            with self.assertRaises(tts_service.TTSError):
                tts_service.update_tts_config({"profiles": [
                    {"id": f"p{i}", "name": str(i)} for i in range(tts_service.MAX_PROFILES)
                ]})
        self.assertEqual(saved, {})

    def test_legacy_update_targets_default_profile(self):
        saved, load, save = self._patched(self._store())
        with load, save:
            tts_service.update_tts_config({"provider": "qwen", "qwen": {"voice": "Ethan"}})
        profiles = {p["id"]: p for p in saved["tts_config"]["profiles"]}
        self.assertEqual(profiles["a"]["provider"], "qwen")
        self.assertEqual(profiles["a"]["qwen"]["voice"], "Ethan")
        self.assertEqual(profiles["b"]["provider"], "gpt_sovits")

    def test_role_picks_profile_with_fallbacks(self):
        with patch(
            "services.tts_service.settings_service.load_settings", return_value={"tts_config": self._store()},
        ):
            default = tts_service.resolve_tts_config({"id": "r"})
            self.assertEqual((default["profile_id"], default["provider"]), ("a", "mimo"))
            picked = tts_service.resolve_tts_config(
                {"id": "r", "metadata": {"voice": {"profile_id": "b", "ref_audio_path": "/role.wav"}}},
            )
            self.assertEqual((picked["profile_id"], picked["profile_name"]), ("b", "乙"))
            self.assertEqual(picked["params"]["ref_audio_path"], "/role.wav")
            self.assertTrue(picked["configured"])
            gone = tts_service.resolve_tts_config({"id": "r", "metadata": {"voice": {"profile_id": "zzz"}}})
            self.assertEqual(gone["profile_id"], "a")
            explicit = tts_service.resolve_tts_config(
                {"id": "r", "metadata": {"voice": {"profile_id": "b"}}}, "a",
            )
            self.assertEqual(explicit["profile_id"], "a")

    def test_no_profiles_means_unavailable(self):
        store = self._store(profiles=[], default_profile_id="")
        with patch("services.tts_service.settings_service.load_settings", return_value={"tts_config": store}):
            resolved = tts_service.resolve_tts_config({"id": "r"})
            self.assertFalse(resolved["configured"])
            self.assertFalse(tts_service.is_voice_available({"id": "r"}))
            self.assertIsNone(tts_service.get_profile())


class TtsTestHandlerTests(unittest.IsolatedAsyncioTestCase):
    async def test_test_action_uses_requested_profile(self):
        from transport import ws_dispatcher

        store = {
            "enabled": False, "default_profile_id": "a",
            "profiles": [
                {"id": "a", "name": "甲", "provider": "mimo"},
                {"id": "b", "name": "乙", "provider": "gpt_sovits",
                 "gpt_sovits": {"ref_audio_path": "/b.wav"}},
            ],
        }
        seen = {}

        async def fake_synth(resolved, text, style=""):
            seen["profile"] = resolved["profile_id"]
            return tts_service.SynthesizedAudio(b"x" * 10, ".wav", "audio/wav", 100)

        with patch("services.tts_service.settings_service.load_settings", return_value={"tts_config": store}), \
                patch("services.tts_service.synthesize", side_effect=fake_synth):
            ghost = await ws_dispatcher._handle_settings_tts_test({"profile_id": "ghost"})
            self.assertFalse(ghost["success"])
            unconfigured = await ws_dispatcher._handle_settings_tts_test({})
            self.assertFalse(unconfigured["success"])  # 默认档案 mimo 缺 key
            ok = await ws_dispatcher._handle_settings_tts_test({"profile_id": "b"})
            self.assertTrue(ok["success"])
            self.assertEqual(seen["profile"], "b")


if __name__ == "__main__":
    unittest.main()
