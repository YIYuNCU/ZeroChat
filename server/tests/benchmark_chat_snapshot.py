"""Synthetic snapshot benchmark; never reads or modifies application data."""
import json
import tempfile
import time
from pathlib import Path
from unittest.mock import patch

from routers import roles


def main():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        for role in range(100):
            target = root / str(role) / "chats"
            target.mkdir(parents=True)
            count = 10000 if role == 0 else 10
            messages = [{"id": str(i), "sender_id": "me", "content": "hello " * 20,
                         "timestamp": "2026-09-05T10:00:00.000", "type": "text",
                         "quote_id": None, "quote_content": None} for i in range(count)]
            (target / "messages.json").write_text(json.dumps({"messages": messages}), encoding="utf-8")
        with patch.object(roles, "ROLES_DIR", root):
            start = time.perf_counter()
            snapshot = roles._build_chats_snapshot("http://test")
            cold = time.perf_counter() - start
            start = time.perf_counter()
            for _ in range(5):
                if hasattr(roles, "get_chat_snapshot"):
                    roles._build_chats_snapshot("http://test", client_md5=snapshot["md5"])
                else:
                    roles._build_chats_snapshot("http://test")
            print(json.dumps({"messages": snapshot["total_messages"],
                              "cold_ms": round(cold * 1000, 2),
                              "unchanged_mean_ms": round((time.perf_counter() - start) * 200, 2)}))


if __name__ == "__main__":
    main()
