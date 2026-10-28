"""OneBot 相关的数据目录与路径安全封装。"""
from pathlib import Path

from core.utils import ensure_direct_child_path

DATA_DIR = Path(__file__).resolve().parents[2] / "data"
ROLES_DIR = DATA_DIR / "roles"


def role_dir(role_id: str) -> Path:
    return ensure_direct_child_path(ROLES_DIR, role_id, "role_id")


def emoji_root(role_id: str) -> Path:
    return ensure_direct_child_path(role_dir(role_id), "emojis", "emoji root")


def profile_path(role_id: str) -> Path:
    return role_dir(role_id) / "profile.json"
