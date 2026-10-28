"""入站图片：下载 QQ 图片并落盘为 vision 上传，随 AIEvent 走与 App 相同的识图工具模式。"""
from __future__ import annotations

import json
import logging
import uuid
from typing import List

import httpx

from core.utils import is_safe_external_url

logger = logging.getLogger(__name__)

MAX_IMAGES = 3  # 限制单批处理数量避免过长延迟
MAX_IMAGE_BYTES = 12 * 1024 * 1024
_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
    "Referer": "https://qq.com",
}


def _vision_configured() -> bool:
    from services import vision_service

    cfg = vision_service.resolve_vision_config()
    return bool(cfg.get("api_url") and cfg.get("api_key"))


async def _download(client: httpx.AsyncClient, url: str) -> bytes:
    async with client.stream("GET", url, headers=_HEADERS) as resp:
        resp.raise_for_status()
        if int(resp.headers.get("content-length") or 0) > MAX_IMAGE_BYTES:
            raise ValueError("OneBot image exceeds size limit")
        chunks: List[bytes] = []
        total = 0
        async for chunk in resp.aiter_bytes(64 * 1024):
            total += len(chunk)
            if total > MAX_IMAGE_BYTES:
                raise ValueError("OneBot image exceeds size limit")
            chunks.append(chunk)
    return b"".join(chunks)


async def stage_images(image_urls: List[str]) -> List[str]:
    """下载图片并落盘到 data/vision/<upload_id>/，返回 upload_id 列表。

    入站图片 URL 不可信：必须通过 SSRF 校验。未配置识图 API 时直接跳过（保留 [图片] 占位）。
    """
    if not image_urls:
        return []
    if not _vision_configured():
        logger.info("OneBot 图片跳过：未配置 Vision API")
        return []

    from routers import ai_behavior
    from services import vision_service

    upload_ids: List[str] = []
    async with httpx.AsyncClient(timeout=30.0) as client:
        for url in image_urls[:MAX_IMAGES]:
            if not is_safe_external_url(url):
                logger.warning("OneBot 图片下载拒绝（URL 未通过 SSRF 校验）: %s", url[:80])
                continue
            try:
                data = await _download(client, url)
                if not data:
                    continue
                mime = vision_service.guess_image_mime(data) or "image/jpeg"
                upload_id = f"qq_{uuid.uuid4().hex}"
                upload_dir = ai_behavior._vision_upload_dir(upload_id)
                upload_dir.mkdir(parents=True, exist_ok=True)
                (upload_dir / "merged.bin").write_bytes(data)
                (upload_dir / "meta.json").write_text(
                    json.dumps({"mime_type": mime, "completed": True}), encoding="utf-8"
                )
                upload_ids.append(upload_id)
            except httpx.TimeoutException:
                logger.warning("OneBot 图片下载超时: %s", url[:60])
            except Exception as exc:  # noqa: BLE001 - 单张失败不影响其余
                logger.warning("OneBot 图片处理失败: %s", exc)
    return upload_ids
