"""测试公共夹具。"""
import pytest


@pytest.fixture(autouse=True)
def _isolated_onebot_message_log(tmp_path, monkeypatch):
    """OneBot 额外消息库默认写在 data/ 下；测试一律改到临时目录，避免污染真实数据。"""
    from services.onebot import message_log, paths

    monkeypatch.setattr(paths, "DATA_DIR", tmp_path / "onebot_log_data")
    message_log.reset_schema_cache()
    yield
    message_log.reset_schema_cache()
