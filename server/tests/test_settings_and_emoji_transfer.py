import base64
import hashlib
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from routers.settings import SettingsUpdate, update_settings
from services.ai_service import _normalize_embedding_url
from transport import ws_dispatcher


class SettingsAndEmojiTransferTests(unittest.IsolatedAsyncioTestCase):
    async def test_rest_settings_persists_embedding_fields(self):
        update = SettingsUpdate(
            embedding_enabled=True,
            embedding_api_url="https://api.example.com/v1",
            embedding_api_key="new-key",
            embedding_model="embedding-model",
        )
        with patch("routers.settings.settings_service.save_settings", return_value=True) as save:
            result = await update_settings(update)

        self.assertTrue(result["success"])
        self.assertEqual(
            save.call_args.args[0],
            {
                "embedding_enabled": True,
                "embedding_api_url": "https://api.example.com/v1",
                "embedding_api_key": "new-key",
                "embedding_model": "embedding-model",
            },
        )

    async def test_websocket_settings_masks_embedding_key_without_mutating_cache(self):
        settings = {"embedding_api_key": "secret-value", "ai_api_key": "chat-key"}
        with patch("transport.ws_dispatcher.settings_service.load_settings", return_value=settings):
            result = await ws_dispatcher._handle_settings_get({}, "")

        returned = result["settings"]
        self.assertNotIn("embedding_api_key", returned)
        self.assertIn("embedding_api_key_masked", returned)
        self.assertEqual(settings["embedding_api_key"], "secret-value")

    async def test_websocket_settings_persists_embedding_fields(self):
        payload = {
            "updates": {
                "embedding_enabled": True,
                "embedding_api_url": "https://api.example.com/v1",
                "embedding_api_key": "new-key",
                "embedding_model": "embedding-model",
            }
        }
        with patch("transport.ws_dispatcher.settings_service.save_settings", return_value=True) as save:
            result = await ws_dispatcher._handle_settings_update(payload, "")

        self.assertTrue(result["success"])
        self.assertEqual(save.call_args.args[0], payload["updates"])

    async def test_emoji_transfer_reads_role_asset_in_chunks(self):
        with TemporaryDirectory() as temp_dir:
            role_dir = Path(temp_dir) / "role-1"
            emoji_file = role_dir / "emojis" / "happy" / "wave.png"
            emoji_file.parent.mkdir(parents=True)
            content = b"emoji-data-" * 7000
            emoji_file.write_bytes(content)
            reference = ws_dispatcher._role_emoji_ref("role-1", "happy", "wave.png")

            ws_dispatcher._EMOJI_TRANSFERS.clear()
            with patch("transport.ws_dispatcher.roles.get_role_dir", return_value=role_dir):
                init = await ws_dispatcher._handle_emoji_file_init({"reference": reference}, "")
                self.assertEqual(init["sha256"], hashlib.sha256(content).hexdigest())
                chunks = []
                for index in range(init["total_chunks"]):
                    part = await ws_dispatcher._handle_emoji_file_chunk(
                        {"transfer_id": init["transfer_id"], "chunk_index": index}, ""
                    )
                    chunks.append(base64.b64decode(part["chunk_base64"]))

        self.assertEqual(b"".join(chunks), content)

    def test_embedding_url_normalization_preserves_provider_base_path(self):
        self.assertEqual(
            _normalize_embedding_url("https://api.example.com/compatible-mode/v1"),
            "https://api.example.com/compatible-mode/v1/embeddings",
        )
        self.assertEqual(
            _normalize_embedding_url("https://api.example.com/v1/chat/completions"),
            "https://api.example.com/v1/embeddings",
        )


if __name__ == "__main__":
    unittest.main()
