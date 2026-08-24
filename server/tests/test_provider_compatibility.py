import unittest
from unittest.mock import AsyncMock, patch

from routers.settings import SettingsUpdate, _model_ids, _models_request, update_settings
from services.ai_service import (
    _build_chat_request,
    _normalize_api_url,
    _parse_native_gemini_response,
    _post_chat,
)
from services import vision_service


class ProviderCompatibilityTests(unittest.IsolatedAsyncioTestCase):
    def test_native_gemini_endpoint_and_payload(self):
        api_url = "https://generativelanguage.googleapis.com/v1beta"
        self.assertEqual(
            _normalize_api_url(api_url, "gemini-2.5-flash"),
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
        )
        payload, headers = _build_chat_request(
            messages=[
                {"role": "system", "content": "be concise"},
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": "describe this"},
                        {"type": "image_url", "image_url": {"url": "data:image/png;base64,AA=="}},
                    ],
                },
            ],
            api_key="test-key",
            model="gemini-2.5-flash",
            api_url=api_url,
            temperature=0.4,
            max_tokens=123,
            tools=None,
        )
        self.assertEqual(headers["Content-Type"], "application/json")
        self.assertEqual(payload["systemInstruction"]["parts"], [{"text": "be concise"}])
        self.assertEqual(payload["contents"][0]["parts"][1]["inlineData"]["mimeType"], "image/png")
        self.assertEqual(payload["generationConfig"]["maxOutputTokens"], 123)

    def test_native_gemini_rebuilds_complete_resource_urls(self):
        native_resource = (
            "https://generativelanguage.googleapis.com/v1beta/models/"
            "gemini-2.5-flash:generateContent?key=ignored"
        )
        openai_resource = (
            "https://generativelanguage.googleapis.com/v1beta/openai/"
            "chat/completions"
        )
        expected = (
            "https://generativelanguage.googleapis.com/v1beta/models/"
            "gemini-2.5-pro:generateContent"
        )
        self.assertEqual(
            _normalize_api_url(native_resource, "gemini-2.5-pro", "gemini_native"),
            expected,
        )
        self.assertEqual(
            _normalize_api_url(openai_resource, "gemini-2.5-pro", "gemini_native"),
            expected,
        )

    def test_explicit_native_format_uses_custom_gateway_path(self):
        api_url = "https://gemini-gateway.example/api/google/openai/chat/completions"
        expected = (
            "https://gemini-gateway.example/api/google/v1beta/models/"
            "gemini-2.5-flash:generateContent"
        )
        self.assertEqual(
            _normalize_api_url(api_url, "gemini-2.5-flash", "gemini_native"),
            expected,
        )
        models_url, headers, native = _models_request(
            api_url, "test-key", "gemini_native",
        )
        self.assertTrue(native)
        self.assertEqual(headers, {})
        self.assertEqual(
            models_url,
            "https://gemini-gateway.example/api/google/v1beta/models?key=test-key",
        )

    async def test_native_chat_uses_query_string_api_key(self):
        response = type(
            "Response",
            (),
            {
                "raise_for_status": lambda self: None,
                "json": lambda self: {
                    "candidates": [{"content": {"parts": [{"text": "ok"}]}}],
                },
            },
        )()
        client = type("Client", (), {"post": AsyncMock(return_value=response)})()
        with patch("services.ai_service._get_http_client", return_value=client):
            result = await _post_chat(
                messages=[{"role": "user", "content": "hello"}],
                api_url="https://gemini-gateway.example/proxy/chu",
                api_key="test-key",
                model="gemini-2.5-flash",
                temperature=0.7,
                max_tokens=8,
                api_format="gemini_native",
            )

        self.assertTrue(result["success"])
        self.assertEqual(
            client.post.await_args.args[0],
            "https://gemini-gateway.example/proxy/chu/v1beta/models/"
            "gemini-2.5-flash:generateContent?key=test-key",
        )
        self.assertEqual(
            client.post.await_args.kwargs["headers"],
            {"Content-Type": "application/json"},
        )

    def test_native_gemini_function_call_round_trip(self):
        text, calls, usage = _parse_native_gemini_response({
            "usageMetadata": {"totalTokenCount": 12},
            "candidates": [{"content": {"parts": [
                {"functionCall": {"name": "search_memory", "args": {"query": "birthday"}}, "thoughtSignature": "sig"},
                {"text": "I will check."},
            ]}}],
        })
        self.assertEqual(text, "I will check.")
        self.assertEqual(calls[0]["function"]["arguments"], {"query": "birthday"})
        self.assertEqual(calls[0]["extra_content"]["google"]["thought_signature"], "sig")
        self.assertEqual(usage["totalTokenCount"], 12)

    def test_gemini_models_requests_cover_native_and_openai_compatibility(self):
        native_url, native_headers, native = _models_request(
            "https://generativelanguage.googleapis.com/v1beta", "key",
        )
        compat_url, compat_headers, compat = _models_request(
            "https://generativelanguage.googleapis.com/v1beta/openai", "key",
        )
        self.assertEqual(native_url, "https://generativelanguage.googleapis.com/v1beta/models?key=key")
        self.assertEqual(native_headers, {})
        self.assertTrue(native)
        self.assertEqual(compat_url, "https://generativelanguage.googleapis.com/v1beta/openai/models")
        self.assertEqual(compat_headers, {"Authorization": "Bearer key"})
        self.assertFalse(compat)
        forced_compat_url, forced_compat_headers, forced_compat = _models_request(
            "https://generativelanguage.googleapis.com/v1beta",
            "key",
            "openai_compatible",
        )
        self.assertEqual(
            forced_compat_url,
            "https://generativelanguage.googleapis.com/v1beta/openai/models",
        )
        self.assertEqual(forced_compat_headers, {"Authorization": "Bearer key"})
        self.assertFalse(forced_compat)
        self.assertEqual(
            _model_ids({"models": [
                {"name": "models/gemini-2.5-flash", "supportedGenerationMethods": ["generateContent"]},
                {"name": "models/text-embedding-004", "supportedGenerationMethods": ["embedContent"]},
            ]}, True),
            ["gemini-2.5-flash"],
        )
        for api_url in (
            "https://generativelanguage.googleapis.com/v1beta/models",
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
            "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
        ):
            models_url, _headers, native = _models_request(
                api_url, "key", "gemini_native",
            )
            self.assertTrue(native)
            self.assertEqual(
                models_url,
                "https://generativelanguage.googleapis.com/v1beta/models?key=key",
            )

    def test_explicit_gemini_protocol_overrides_auto_detection(self):
        api_url = "https://generativelanguage.googleapis.com/v1beta/openai"
        self.assertEqual(
            _normalize_api_url(api_url, "gemini-2.5-flash", "gemini_native"),
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
        )
        payload, headers = _build_chat_request(
            messages=[{"role": "user", "content": "hello"}],
            api_key="test-key",
            model="gemini-2.5-flash",
            api_url=api_url,
            temperature=0.7,
            max_tokens=32,
            tools=None,
            api_format="openai_compatible",
        )
        self.assertEqual(headers["Authorization"], "Bearer test-key")
        self.assertEqual(payload["model"], "gemini-2.5-flash")
        self.assertIn("messages", payload)

    async def test_settings_persist_validated_protocol_fields(self):
        update = SettingsUpdate(
            ai_api_format="gemini_native",
            vision_api_format="unexpected",
        )
        with patch("routers.settings.settings_service.save_settings", return_value=True) as save:
            result = await update_settings(update)

        self.assertTrue(result["success"])
        self.assertEqual(
            save.call_args.args[0],
            {"ai_api_format": "gemini_native", "vision_api_format": "auto"},
        )

    async def test_deepseek_vision_replaces_data_url_with_one_day_file(self):
        data_url = "data:image/png;base64,AA=="
        with patch.object(
            vision_service,
            "_upload_deepseek_vision_file",
            new=AsyncMock(return_value="file-api-test"),
        ) as upload:
            messages = await vision_service._prepare_deepseek_file_messages(
                [{"role": "user", "content": [
                    {"type": "text", "text": "what is this?"},
                    {"type": "image_url", "image_url": {"url": data_url}},
                ]}],
                "https://api.deepseek.com/v1",
                "key",
                "deepseek-v4-flash-vision-exp",
            )
        self.assertEqual(messages[0]["content"][1], {"type": "file", "file_id": "file-api-test"})
        upload.assert_awaited_once_with("https://api.deepseek.com/v1", "key", data_url)
        self.assertEqual(vision_service.DEEPSEEK_FILE_TTL_SECONDS, 86400)
        self.assertEqual(
            vision_service._deepseek_files_endpoint("https://api.deepseek.com/v1/chat/completions"),
            "https://api.deepseek.com/files",
        )

    async def test_deepseek_file_upload_sets_one_day_expiration(self):
        captured = {}

        class Response:
            def raise_for_status(self):
                return None

            def json(self):
                return {"id": "file-api-test"}

        class Client:
            async def __aenter__(self):
                return self

            async def __aexit__(self, *_args):
                return None

            async def post(self, *args, **kwargs):
                captured["args"] = args
                captured["kwargs"] = kwargs
                return Response()

        with patch("services.vision_service.httpx.AsyncClient", return_value=Client()):
            file_id = await vision_service._upload_deepseek_vision_file(
                "https://api.deepseek.com/v1",
                "key",
                "data:image/png;base64,AA==",
            )

        self.assertEqual(file_id, "file-api-test")
        self.assertEqual(captured["args"][0], "https://api.deepseek.com/files")
        self.assertEqual(captured["kwargs"]["data"], {
            "purpose": "user_data",
            "expires_after[anchor]": "created_at",
            "expires_after[seconds]": "86400",
        })


if __name__ == "__main__":
    unittest.main()
