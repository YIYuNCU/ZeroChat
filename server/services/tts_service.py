"""AI 语音合成（TTS）服务。

支持三个后端：

* ``mimo``        – 小米 MiMo-TTS（OpenAI Chat Completions 兼容，朗读文本放在 assistant 消息里）
* ``qwen``        – 阿里云百炼 Qwen-TTS（非实时 multimodal-generation 接口）
* ``gpt_sovits``  – GPT-SoVITS ``api_v2.py`` 的 ``/tts`` 接口

全局配置存放在 ``settings.json`` 的 ``tts_config``（API Key 只存服务端，读取时掩码）；
单个角色可通过 ``role.metadata["voice"]`` 覆盖音色 / 风格 / GPT-SoVITS 参考音频，
或关闭语音。合成出的音频保存在 ``data/roles/<role_id>/voices/``，客户端通过
``ws-emoji://voice/<role_id>/<filename>`` 分块下载，OneBot 直接读取本地文件。
"""
from __future__ import annotations

import asyncio
import base64
import io
import logging
import re
import time
import uuid
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Optional
from urllib.parse import quote, urlparse

import httpx

from core.utils import (
    ensure_direct_child_path,
    ensure_simple_path_segment,
    is_safe_external_url,
    mask_api_key,
)
from services import settings_service

logger = logging.getLogger(__name__)

DATA_DIR = Path(__file__).parent.parent / "data"
ROLES_DIR = DATA_DIR / "roles"

PROVIDERS = ("mimo", "qwen", "gpt_sovits")
DEFAULT_PROVIDER = "mimo"

#: 单条语音音频的大小上限（下载或解码后）。
MAX_AUDIO_BYTES = 10 * 1024 * 1024
#: 每轮回复最多发送的语音条数。
MAX_VOICES_PER_TURN = 3

#: 语音文件保留策略（按角色）。
VOICE_RETENTION_DAYS = 30
VOICE_RETENTION_MAX_FILES = 300
VOICE_RETENTION_MAX_BYTES = 200 * 1024 * 1024

_KEY_CONFIG = "tts_config"
_AUDIO_EXTS = (".wav", ".mp3")
_MASK_PLACEHOLDERS = {"", "***"}

_ROLE_VOICE_KEYS = {
    "mimo": ("voice", "style"),
    "qwen": ("voice", "style"),
    "gpt_sovits": ("ref_audio_path", "prompt_text", "prompt_lang", "text_lang"),
}


class TTSError(Exception):
    """合成失败。消息可以安全地展示给模型（不含密钥）。"""


@dataclass
class SynthesizedAudio:
    data: bytes
    ext: str  # ".wav" | ".mp3"
    mime: str
    duration_ms: Optional[int] = None


# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------

def default_tts_config() -> Dict[str, Any]:
    return {
        "enabled": False,
        "provider": DEFAULT_PROVIDER,
        "timeout_seconds": 60,
        "max_chars": 300,
        "mimo": {
            "api_url": "https://api.xiaomimimo.com/v1",
            "api_key": "",
            "model": "mimo-v2.5-tts",
            "voice": "mimo_default",
            "style": "",
        },
        "qwen": {
            "api_url": "https://dashscope.aliyuncs.com/api/v1",
            "api_key": "",
            "model": "qwen3-tts-flash",
            "voice": "Cherry",
            "language_type": "Auto",
            "style": "",
        },
        "gpt_sovits": {
            "api_url": "http://127.0.0.1:9880",
            "ref_audio_path": "",
            "prompt_text": "",
            "prompt_lang": "zh",
            "text_lang": "zh",
            "text_split_method": "cut5",
            "speed_factor": 1.0,
        },
    }


def _clamp_int(value: Any, low: int, high: int, fallback: int) -> int:
    try:
        return max(low, min(high, int(value)))
    except (TypeError, ValueError):
        return fallback


def _clamp_float(value: Any, low: float, high: float, fallback: float) -> float:
    try:
        return max(low, min(high, float(value)))
    except (TypeError, ValueError):
        return fallback


def _text(value: Any, limit: int = 2000) -> str:
    return str(value).strip()[:limit]


def sanitize_tts_config(value: Any) -> Dict[str, Any]:
    """把（可能不完整的）配置规整为存储形状；未知键丢弃。"""
    base = default_tts_config()
    if not isinstance(value, dict):
        return base
    if value.get("enabled") is not None:
        base["enabled"] = bool(value["enabled"])
    provider = _text(value.get("provider"), 40).lower()
    base["provider"] = provider if provider in PROVIDERS else DEFAULT_PROVIDER
    base["timeout_seconds"] = _clamp_int(value.get("timeout_seconds"), 5, 180, base["timeout_seconds"])
    base["max_chars"] = _clamp_int(value.get("max_chars"), 20, 1000, base["max_chars"])
    for provider_name in PROVIDERS:
        incoming = value.get(provider_name)
        if not isinstance(incoming, dict):
            continue
        section = base[provider_name]
        for key in section:
            if key not in incoming or incoming[key] is None:
                continue
            if key == "speed_factor":
                section[key] = _clamp_float(incoming[key], 0.5, 2.0, section[key])
            else:
                section[key] = _text(incoming[key])
    return base


def load_tts_config() -> Dict[str, Any]:
    return sanitize_tts_config(settings_service.load_settings().get(_KEY_CONFIG))


def _is_unchanged_secret(value: Any) -> bool:
    text = str(value or "").strip()
    return text in _MASK_PLACEHOLDERS or "..." in text


def update_tts_config(updates: Any) -> bool:
    """合并部分更新；api_key 为空、``***`` 或掩码值时保留旧值。"""
    if not isinstance(updates, dict):
        return False
    current = load_tts_config()
    merged: Dict[str, Any] = {k: v for k, v in current.items() if k not in PROVIDERS}
    for key in ("enabled", "provider", "timeout_seconds", "max_chars"):
        if key in updates and updates[key] is not None:
            merged[key] = updates[key]
    for provider_name in PROVIDERS:
        section = dict(current[provider_name])
        incoming = updates.get(provider_name)
        if isinstance(incoming, dict):
            for key, val in incoming.items():
                if key == "api_key" and _is_unchanged_secret(val):
                    continue
                if key in section and val is not None:
                    section[key] = val
        merged[provider_name] = section
    return settings_service.save_settings({_KEY_CONFIG: sanitize_tts_config(merged)})


def _provider_ready(provider: str, params: Dict[str, Any]) -> bool:
    if not str(params.get("api_url") or "").strip():
        return False
    if provider in ("mimo", "qwen"):
        return bool(str(params.get("api_key") or "").strip() and str(params.get("model") or "").strip())
    return bool(str(params.get("ref_audio_path") or "").strip())


def public_tts_config(config: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """返回给客户端的配置：api_key 替换为 api_key_masked，并带 configured 标志。"""
    cfg = sanitize_tts_config(config) if config is not None else load_tts_config()
    result = {k: v for k, v in cfg.items() if k not in PROVIDERS}
    for provider in PROVIDERS:
        section = dict(cfg[provider])
        if "api_key" in section:
            masked = mask_api_key(section.pop("api_key"))
            if masked is not None:
                section["api_key_masked"] = masked
        result[provider] = section
    result["configured"] = _provider_ready(cfg["provider"], cfg[cfg["provider"]])
    return result


def _role_voice_overrides(role_data: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    metadata = (role_data or {}).get("metadata")
    voice = metadata.get("voice") if isinstance(metadata, dict) else None
    return voice if isinstance(voice, dict) else {}


def resolve_tts_config(role_data: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """全局配置合并角色覆盖，返回当前 provider 的生效参数。"""
    cfg = load_tts_config()
    provider = cfg["provider"]
    params = dict(cfg[provider])
    overrides = _role_voice_overrides(role_data)
    for key in _ROLE_VOICE_KEYS[provider]:
        value = overrides.get(key)
        if isinstance(value, str) and value.strip():
            params[key] = value.strip()[:2000]
    return {
        "enabled": bool(cfg["enabled"]),
        "provider": provider,
        "timeout_seconds": cfg["timeout_seconds"],
        "max_chars": cfg["max_chars"],
        "params": params,
        "role_enabled": overrides.get("enabled") is not False,
        "configured": _provider_ready(provider, params),
    }


def is_voice_available(role_data: Optional[Dict[str, Any]] = None) -> bool:
    resolved = resolve_tts_config(role_data)
    return bool(resolved["enabled"] and resolved["configured"] and resolved["role_enabled"])


# ---------------------------------------------------------------------------
# 文本清洗
# ---------------------------------------------------------------------------

_PAIRED_TAG_RE = re.compile(r"<\s*([^<>\s/]+)[^<>]*>.*?<\s*/\s*\1\s*>", re.S)
_ANY_TAG_RE = re.compile(r"<[^<>]*>")
_STAGE_DIRECTION_RE = re.compile(r"[（(][^（）()]*[）)]|\*[^*\n]+\*")
_SPEAKABLE_RE = re.compile(r"[0-9A-Za-z\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]")


def clean_tts_text(text: Any) -> str:
    """去掉标签 / 动作描述 / 多余空白，得到可朗读的纯口语文本。"""
    value = str(text or "")
    value = _PAIRED_TAG_RE.sub(" ", value)
    value = _ANY_TAG_RE.sub(" ", value)
    value = _STAGE_DIRECTION_RE.sub(" ", value)
    value = re.sub(r"\s+", " ", value).strip()
    return value if _SPEAKABLE_RE.search(value) else ""


# ---------------------------------------------------------------------------
# HTTP 适配器
# ---------------------------------------------------------------------------

def _make_client(timeout: float) -> httpx.AsyncClient:
    """独立函数，便于测试注入 MockTransport。"""
    return httpx.AsyncClient(timeout=timeout, follow_redirects=False)


def _require_http_url(url: str) -> str:
    value = str(url or "").strip()
    parsed = urlparse(value)
    if parsed.scheme.lower() not in ("http", "https") or not parsed.hostname:
        raise TTSError("TTS 服务地址无效")
    return value.rstrip("/")


def _sniff_audio(data: bytes, hint: str = "") -> tuple[str, str]:
    if data[:4] == b"RIFF":
        return ".wav", "audio/wav"
    if data[:3] == b"ID3" or (len(data) > 1 and data[0] == 0xFF and (data[1] & 0xE0) == 0xE0):
        return ".mp3", "audio/mpeg"
    if hint.lower().endswith(".mp3") or "mpeg" in hint.lower():
        return ".mp3", "audio/mpeg"
    return ".wav", "audio/wav"


def _wav_duration_ms(data: bytes) -> Optional[int]:
    try:
        with wave.open(io.BytesIO(data), "rb") as reader:
            rate = reader.getframerate()
            return int(reader.getnframes() * 1000 / rate) if rate else None
    except Exception:  # noqa: BLE001 - 非标准 wav（如流式头）直接放弃时长
        return None


def _build_audio(data: bytes, hint: str = "") -> SynthesizedAudio:
    if not data:
        raise TTSError("TTS 返回了空音频")
    if len(data) > MAX_AUDIO_BYTES:
        raise TTSError("TTS 音频超过大小限制")
    ext, mime = _sniff_audio(data, hint)
    return SynthesizedAudio(
        data=data, ext=ext, mime=mime,
        duration_ms=_wav_duration_ms(data) if ext == ".wav" else None,
    )


def _error_detail(response: httpx.Response) -> str:
    try:
        body = response.json()
    except Exception:  # noqa: BLE001
        return ""
    if isinstance(body, dict):
        error = body.get("error")
        message = (
            (error.get("message") if isinstance(error, dict) else error)
            or body.get("message") or ""
        )
        return str(message).strip()[:100]
    return ""


def _raise_for_status(response: httpx.Response) -> None:
    status = response.status_code
    if status < 400:
        return
    if status in (401, 403):
        raise TTSError(f"TTS 鉴权失败（{status}），请检查 API Key")
    detail = _error_detail(response)
    suffix = f"：{detail}" if detail else ""
    raise TTSError(f"TTS 服务返回错误（{status}）{suffix}")


async def _post_json(
    url: str, payload: Dict[str, Any], headers: Dict[str, str], timeout: float,
) -> httpx.Response:
    try:
        async with _make_client(timeout) as client:
            response = await client.post(url, json=payload, headers=headers)
    except httpx.TimeoutException as exc:
        raise TTSError("TTS 请求超时") from exc
    except httpx.HTTPError as exc:
        raise TTSError(f"TTS 服务连接失败（{type(exc).__name__}）") from exc
    _raise_for_status(response)
    return response


def _json_body(response: httpx.Response) -> Dict[str, Any]:
    try:
        body = response.json()
    except Exception as exc:  # noqa: BLE001
        raise TTSError("TTS 返回了无法解析的响应") from exc
    if not isinstance(body, dict):
        raise TTSError("TTS 返回了无法解析的响应")
    return body


def _decode_b64_audio(value: Any) -> bytes:
    encoded = str(value or "").strip()
    if not encoded:
        raise TTSError("TTS 响应中没有音频数据")
    if len(encoded) > 4 * ((MAX_AUDIO_BYTES + 2) // 3):
        raise TTSError("TTS 音频超过大小限制")
    try:
        return base64.b64decode(encoded)
    except Exception as exc:  # noqa: BLE001
        raise TTSError("TTS 音频数据无法解码") from exc


async def _synthesize_mimo(params: Dict[str, Any], text: str, style: str, timeout: float) -> SynthesizedAudio:
    base = _require_http_url(params.get("api_url"))
    url = base if base.endswith("/chat/completions") else f"{base}/chat/completions"
    messages = []
    if style:
        messages.append({"role": "user", "content": style})
    messages.append({"role": "assistant", "content": text})
    payload: Dict[str, Any] = {
        "model": params.get("model"),
        "messages": messages,
        "audio": {"format": "wav", "voice": params.get("voice") or "mimo_default"},
    }
    response = await _post_json(url, payload, {"api-key": str(params.get("api_key") or "")}, timeout)
    body = _json_body(response)
    try:
        audio = body["choices"][0]["message"]["audio"]["data"]
    except (KeyError, IndexError, TypeError) as exc:
        raise TTSError("TTS 响应中没有音频数据") from exc
    return _build_audio(_decode_b64_audio(audio))


async def _download_audio(url: str, timeout: float) -> tuple[bytes, str]:
    if not await asyncio.to_thread(is_safe_external_url, url):
        raise TTSError("TTS 返回的音频地址不安全")
    try:
        async with _make_client(timeout) as client:
            async with client.stream("GET", url) as response:
                _raise_for_status(response)
                chunks: list[bytes] = []
                total = 0
                async for chunk in response.aiter_bytes():
                    total += len(chunk)
                    if total > MAX_AUDIO_BYTES:
                        raise TTSError("TTS 音频超过大小限制")
                    chunks.append(chunk)
                return b"".join(chunks), urlparse(url).path
    except httpx.TimeoutException as exc:
        raise TTSError("TTS 音频下载超时") from exc
    except httpx.HTTPError as exc:
        raise TTSError(f"TTS 音频下载失败（{type(exc).__name__}）") from exc


async def _synthesize_qwen(params: Dict[str, Any], text: str, style: str, timeout: float) -> SynthesizedAudio:
    base = _require_http_url(params.get("api_url"))
    url = base if "multimodal-generation" in base else f"{base}/services/aigc/multimodal-generation/generation"
    model = str(params.get("model") or "")
    input_body: Dict[str, Any] = {
        "text": text,
        "voice": params.get("voice") or "Cherry",
        "language_type": params.get("language_type") or "Auto",
    }
    if style and "instruct" in model.lower():
        input_body["instructions"] = style
    payload = {"model": model, "input": input_body}
    headers = {"Authorization": f"Bearer {params.get('api_key') or ''}"}
    response = await _post_json(url, payload, headers, timeout)
    body = _json_body(response)
    audio = (body.get("output") or {}).get("audio") if isinstance(body.get("output"), dict) else None
    if not isinstance(audio, dict):
        raise TTSError("TTS 响应中没有音频数据")
    if audio.get("data"):
        return _build_audio(_decode_b64_audio(audio["data"]))
    audio_url = str(audio.get("url") or "").strip()
    if not audio_url:
        raise TTSError("TTS 响应中没有音频数据")
    data, hint = await _download_audio(audio_url, timeout)
    return _build_audio(data, hint)


async def _synthesize_gpt_sovits(params: Dict[str, Any], text: str, style: str, timeout: float) -> SynthesizedAudio:
    base = _require_http_url(params.get("api_url"))
    url = base if base.endswith("/tts") else f"{base}/tts"
    ref_audio = str(params.get("ref_audio_path") or "").strip()
    if not ref_audio:
        raise TTSError("GPT-SoVITS 未配置参考音频路径")
    payload = {
        "text": text,
        "text_lang": params.get("text_lang") or "zh",
        "ref_audio_path": ref_audio,
        "prompt_text": params.get("prompt_text") or "",
        "prompt_lang": params.get("prompt_lang") or "zh",
        "text_split_method": params.get("text_split_method") or "cut5",
        "batch_size": 1,
        "media_type": "wav",
        "streaming_mode": False,
        "speed_factor": params.get("speed_factor") or 1.0,
    }
    response = await _post_json(url, payload, {}, timeout)
    return _build_audio(response.content)


_ADAPTERS = {
    "mimo": _synthesize_mimo,
    "qwen": _synthesize_qwen,
    "gpt_sovits": _synthesize_gpt_sovits,
}


async def synthesize(resolved: Dict[str, Any], text: str, style: str = "") -> SynthesizedAudio:
    """用 ``resolve_tts_config`` 的结果合成一段音频。"""
    adapter = _ADAPTERS[resolved["provider"]]
    timeout = float(resolved["timeout_seconds"])
    try:
        return await asyncio.wait_for(
            adapter(resolved["params"], text, style, timeout), timeout=timeout + 5,
        )
    except asyncio.TimeoutError as exc:
        raise TTSError("TTS 请求超时") from exc


# ---------------------------------------------------------------------------
# 存储
# ---------------------------------------------------------------------------

def voices_dir(role_id: str, create: bool = False) -> Path:
    role_dir = ensure_direct_child_path(ROLES_DIR, role_id, "role_id")
    directory = ensure_direct_child_path(role_dir, "voices", "voices root")
    if create:
        directory.mkdir(parents=True, exist_ok=True)
    return directory


def voice_ref(role_id: str, filename: str) -> str:
    return "ws-emoji://voice/{}/{}".format(quote(role_id, safe=""), quote(filename, safe=""))


def voice_file_path(role_id: str, filename: str) -> Path:
    """校验后的语音文件路径（不保证存在）。"""
    safe_name = ensure_simple_path_segment(filename, "filename")
    if Path(safe_name).suffix.lower() not in _AUDIO_EXTS:
        raise ValueError("invalid voice filename")
    return ensure_direct_child_path(voices_dir(role_id), safe_name, "filename")


def save_voice(role_id: str, audio: SynthesizedAudio) -> Path:
    directory = voices_dir(role_id, create=True)
    path = ensure_direct_child_path(directory, f"{uuid.uuid4().hex}{audio.ext}", "filename")
    path.write_bytes(audio.data)
    try:
        cleanup_role_voices(role_id)
    except Exception:  # noqa: BLE001 - 清理失败不影响本次发送
        logger.warning("语音文件清理失败: role=%s", role_id, exc_info=True)
    return path


def cleanup_role_voices(
    role_id: str,
    *,
    max_age_days: int = VOICE_RETENTION_DAYS,
    max_files: int = VOICE_RETENTION_MAX_FILES,
    max_bytes: int = VOICE_RETENTION_MAX_BYTES,
    now: Optional[float] = None,
) -> int:
    """按年龄 / 数量 / 总大小清理角色语音文件，返回删除数量。"""
    directory = voices_dir(role_id)
    if not directory.is_dir():
        return 0
    current = time.time() if now is None else now
    entries = []
    for item in directory.iterdir():
        if item.is_file() and item.suffix.lower() in _AUDIO_EXTS:
            stat = item.stat()
            entries.append((stat.st_mtime, stat.st_size, item))
    entries.sort(key=lambda row: row[0], reverse=True)  # 新 → 旧
    removed = 0
    kept_bytes = 0
    for index, (mtime, size, item) in enumerate(entries):
        too_old = current - mtime > max_age_days * 86400
        over_limit = index >= max_files or kept_bytes + size > max_bytes
        if too_old or over_limit:
            try:
                item.unlink()
                removed += 1
            except OSError:
                pass
        else:
            kept_bytes += size
    return removed


# ---------------------------------------------------------------------------
# 对外入口
# ---------------------------------------------------------------------------

async def synthesize_for_role(
    role_data: Dict[str, Any], text: str, style: str = "",
) -> Dict[str, Any]:
    """为角色合成并保存一条语音，返回投递信息。失败抛 ``TTSError``。"""
    role_id = str((role_data or {}).get("id") or "").strip()
    if not role_id:
        raise TTSError("缺少角色信息")
    resolved = resolve_tts_config(role_data)
    if not (resolved["enabled"] and resolved["configured"] and resolved["role_enabled"]):
        raise TTSError("语音功能未启用或未配置")
    spoken = clean_tts_text(text)
    if not spoken:
        raise TTSError("没有可朗读的文字，请只写口语内容")
    if len(spoken) > resolved["max_chars"]:
        raise TTSError(f"语音文字过长（上限 {resolved['max_chars']} 字），请缩短后重试")
    base_style = str(resolved["params"].get("style") or "").strip()
    extra_style = clean_tts_text(style)[:200]
    combined_style = "，".join(part for part in (base_style, extra_style) if part)
    started = time.monotonic()
    try:
        audio = await synthesize(resolved, spoken, combined_style)
    except TTSError as exc:
        logger.warning(
            "TTS 合成失败: provider=%s role=%s reason=%s",
            resolved["provider"], role_id, exc,
        )
        raise
    path = save_voice(role_id, audio)
    logger.info(
        "TTS 合成完成: provider=%s role=%s chars=%d bytes=%d cost=%.2fs",
        resolved["provider"], role_id, len(spoken), len(audio.data), time.monotonic() - started,
    )
    return {
        "text": spoken,
        "ref": voice_ref(role_id, path.name),
        "filename": path.name,
        "duration_ms": audio.duration_ms,
        "mime": audio.mime,
    }
