"""
设置服务
管理全局配置（API URL、KEY、模型等）
"""
import json
from pathlib import Path
from typing import Optional, Dict, Any

CONFIG_DIR = Path(__file__).parent.parent / "config"

def get_settings_file() -> Path:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    return CONFIG_DIR / "settings.json"

def get_default_settings() -> Dict[str, Any]:
    """获取默认设置"""
    return {
        "host": "0.0.0.0",
        "port": 8000,
        "ai_api_url": "",
        "ai_api_key": "",
        "ai_model": "gpt-3.5-turbo",
        "updated_at": None
    }

def load_settings() -> Dict[str, Any]:
    """加载设置"""
    settings_file = get_settings_file()
    default = get_default_settings()
    
    if settings_file.exists():
        try:
            with open(settings_file, "r", encoding="utf-8") as f:
                saved = json.load(f)
                return {**default, **saved}
        except Exception:
            pass
    
    return default

def save_settings(settings: Dict[str, Any]) -> bool:
    """保存设置"""
    try:
        settings_file = get_settings_file()
        
        # 合并现有设置
        current = load_settings()
        current.update(settings)
        
        # 添加更新时间
        from datetime import datetime
        current["updated_at"] = datetime.now().isoformat()
        
        with open(settings_file, "w", encoding="utf-8") as f:
            json.dump(current, f, indent=2, ensure_ascii=False)
        
        return True
    except Exception as e:
        print(f"Error saving settings: {e}")
        return False

def get_ai_config() -> Dict[str, str]:
    """获取 AI API 配置"""
    settings = load_settings()
    return {
        "api_url": settings.get("ai_api_url", ""),
        "api_key": settings.get("ai_api_key", ""),
        "model": settings.get("ai_model", "gpt-3.5-turbo")
    }

def update_ai_config(api_url: Optional[str] = None, 
                     api_key: Optional[str] = None,
                     model: Optional[str] = None) -> bool:
    """更新 AI API 配置"""
    updates = {}
    if api_url is not None:
        updates["ai_api_url"] = api_url
    if api_key is not None:
        updates["ai_api_key"] = api_key
    if model is not None:
        updates["ai_model"] = model
    
    if updates:
        return save_settings(updates)
    return True
