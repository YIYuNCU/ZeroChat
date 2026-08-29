import base64
import unittest
from io import BytesIO
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest.mock import patch
import uuid

from fastapi import HTTPException, UploadFile

from routers import ai_behavior, onebot, roles
from services import memory_service
from transport import ws_dispatcher


class _FakeWebSocket:
    headers = {}
    url = SimpleNamespace(scheme="ws")


class FilePathSecurityTests(unittest.IsolatedAsyncioTestCase):
    async def test_http_role_delete_rejects_parent_directory(self):
        with TemporaryDirectory() as temp_dir:
            data_root = Path(temp_dir)
            roles_root = data_root / "roles"
            roles_root.mkdir()
            sentinel = data_root / "sentinel.txt"
            sentinel.write_text("keep", encoding="utf-8")

            with patch.object(roles, "ROLES_DIR", roles_root):
                with self.assertRaises(HTTPException):
                    await roles.delete_role("..")

            self.assertTrue(sentinel.exists())
            self.assertTrue(roles_root.exists())

    async def test_websocket_role_delete_stays_inside_roles_root(self):
        with TemporaryDirectory() as temp_dir:
            data_root = Path(temp_dir)
            roles_root = data_root / "roles"
            roles_root.mkdir()
            sentinel = data_root / "sentinel.txt"
            sentinel.write_text("keep", encoding="utf-8")

            with patch.object(ws_dispatcher.roles, "ROLES_DIR", roles_root):
                with self.assertRaises(ValueError):
                    await ws_dispatcher.handle_ws_action(
                        "roles_delete",
                        {"role_id": ".."},
                        _FakeWebSocket(),
                        {"host": "127.0.0.1", "port": 8000},
                    )

            self.assertTrue(sentinel.exists())
            self.assertTrue(roles_root.exists())

    def test_vision_upload_id_rejects_path_traversal_and_absolute_paths(self):
        with TemporaryDirectory() as temp_dir, patch.object(
            ai_behavior, "VISION_UPLOADS_DIR", Path(temp_dir)
        ):
            for upload_id in ("../roles", "..\\roles", "/tmp/file", "C:\\temp"):
                with self.subTest(upload_id=upload_id), self.assertRaises(ValueError):
                    ai_behavior._vision_upload_dir(upload_id)

            valid = ai_behavior._vision_upload_dir("v1_deadbeef_123")
            self.assertEqual(valid, Path(temp_dir).resolve() / "v1_deadbeef_123")

    def test_role_scoped_services_reject_path_traversal(self):
        with TemporaryDirectory() as temp_dir:
            roles_root = Path(temp_dir) / "roles"
            roles_root.mkdir()
            with patch.object(ai_behavior, "ROLES_DIR", roles_root), patch.object(
                onebot, "ROLES_DIR", roles_root
            ), patch.object(memory_service, "ROLES_DIR", roles_root):
                with self.assertRaises(HTTPException):
                    ai_behavior._role_dir("..")
                with self.assertRaises(ValueError):
                    onebot._role_dir("../other")
                with self.assertRaises(ValueError):
                    memory_service.get_memory_db("..")

    def test_role_directory_rejects_symlink_escape(self):
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            roles_root = root / "roles"
            outside = root / "outside"
            roles_root.mkdir()
            outside.mkdir()
            link = roles_root / "linked-role"
            try:
                link.symlink_to(outside, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlink creation unavailable: {exc}")

            with patch.object(roles, "ROLES_DIR", roles_root):
                with self.assertRaises(HTTPException):
                    roles.get_role_dir("linked-role")

            self.assertEqual(list(outside.iterdir()), [])

    def test_role_directory_rejects_cross_role_symlink(self):
        with TemporaryDirectory() as temp_dir:
            roles_root = Path(temp_dir) / "roles"
            target = roles_root / "target-role"
            target.mkdir(parents=True)
            link = roles_root / "linked-role"
            try:
                link.symlink_to(target, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlink creation unavailable: {exc}")

            with patch.object(roles, "ROLES_DIR", roles_root):
                with self.assertRaises(HTTPException):
                    roles.get_role_dir("linked-role")

    def test_role_emoji_category_rejects_symlink_escape(self):
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            roles_root = root / "roles"
            outside = root / "outside"
            outside.mkdir()
            with patch.object(roles, "ROLES_DIR", roles_root):
                emoji_root = roles.get_role_emojis_dir("role-1")
                link = emoji_root / "linked-category"
                try:
                    link.symlink_to(outside, target_is_directory=True)
                except OSError as exc:
                    self.skipTest(f"symlink creation unavailable: {exc}")

                with self.assertRaises(HTTPException):
                    roles.get_role_emoji_category_dir("role-1", "linked-category")

    def test_clone_preserves_in_data_links_and_skips_external_links(self):
        with TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            roles_root = root / "roles"
            roles_root.mkdir()
            source = roles_root / "source"
            source_assets = source / "assets"
            source_assets.mkdir(parents=True)
            (source / "profile.json").write_text(
                '{"id":"source","name":"Source"}', encoding="utf-8"
            )
            shared = root / "shared.png"
            shared.write_bytes(b"shared")
            outside = Path(temp_dir).parent / f"zerochat-outside-{uuid.uuid4().hex}.png"
            outside.write_bytes(b"outside")
            try:
                (source_assets / "shared.png").symlink_to(shared)
                (source_assets / "outside.png").symlink_to(outside)
            except OSError as exc:
                outside.unlink(missing_ok=True)
                self.skipTest(f"symlink creation unavailable: {exc}")

            try:
                with patch.object(roles, "DATA_DIR", root), patch.object(
                    roles, "ROLES_DIR", roles_root
                ), patch.object(memory_service, "ROLES_DIR", roles_root):
                    roles.clone_role("source", new_id="clone")
                    clone_assets = roles_root / "clone" / "assets"
                    self.assertTrue((clone_assets / "shared.png").is_symlink())
                    self.assertFalse((clone_assets / "outside.png").exists())
            finally:
                memory_service.close_all_connections()
                outside.unlink(missing_ok=True)

    async def test_vision_upload_enforces_count_and_size_limits(self):
        with TemporaryDirectory() as temp_dir, patch.object(
            ws_dispatcher, "VISION_UPLOADS_DIR", Path(temp_dir)
        ):
            with self.assertRaises(ValueError):
                await ws_dispatcher._handle_vision_upload_init(
                    {
                        "total_chunks": ws_dispatcher.VISION_UPLOAD_MAX_CHUNKS + 1,
                        "file_size": 1,
                    },
                    "",
                )

            await ws_dispatcher._handle_vision_upload_init(
                {"upload_id": "limited", "total_chunks": 1, "file_size": 1},
                "",
            )
            oversized = base64.b64encode(
                b"x" * (ws_dispatcher.VISION_UPLOAD_MAX_CHUNK_SIZE + 1)
            ).decode("ascii")
            with self.assertRaises(ValueError):
                await ws_dispatcher._handle_vision_upload_chunk(
                    {
                        "upload_id": "limited",
                        "chunk_index": 0,
                        "chunk_base64": oversized,
                    },
                    "",
                )

    def test_http_upload_enforces_size_limit_and_removes_partial_file(self):
        with TemporaryDirectory() as temp_dir, patch.object(
            roles, "MAX_IMAGE_UPLOAD_BYTES", 4
        ):
            destination = Path(temp_dir) / "image.png"
            upload = UploadFile(filename="image.png", file=BytesIO(b"12345"))
            with self.assertRaises(HTTPException) as raised:
                roles._save_bounded_upload(upload, destination)

            self.assertEqual(raised.exception.status_code, 413)
            self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
