# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ZeroChat is an AI chat companion app with a WeChat-like UI. It uses a **Flutter client** + **FastAPI server** architecture. The server handles AI API calls, role management, memory persistence (SQLite), scheduling (proactive messages, moments, tasks), and **OneBot V11 QQ integration**. The client provides the UI, local state management, and background runtime support.

## Build & Run Commands

### Flutter Client (workspace root → `client/`)
- `cd client && flutter pub get` — install dependencies
- `cd client && flutter run` — run on connected device/emulator
- `cd client && flutter analyze` — run Dart static analysis
- `cd client && flutter test` — run all tests
- `cd client && flutter build apk` — build Android APK

### Python Server (from `server/` directory)
- Activate conda env (ZeroChat) then: `python main.py` — start the server on port 8000
- Or use `start.bat` (Windows) / `start.sh` (Linux/Mac) — auto-creates venv and installs deps

### Test Dependencies
- No test framework is configured for the Python server
- Flutter tests use `flutter_test` (sdk) with `flutter_lints` for linting

## Architecture

### Flutter Client (`client/lib/`)
```
client/
├── lib/
│   ├── main.dart                 # App entry point
│   ├── core/                     # Runtime orchestration (controllers, schedulers, managers)
│   │   ├── chat_controller.dart      # Central chat logic hub
│   │   ├── memory_manager.dart       # Memory management (core + short-term)
│   │   ├── moments_scheduler.dart    # Moments (朋友圈) scheduler
│   │   ├── group_scheduler.dart      # Group chat scheduling
│   │   ├── message_store.dart        # Message persistence
│   │   └── segment_sender.dart       # Segmented message sending
│   ├── models/                   # Data models
│   │   ├── role.dart                 # Role model
│   │   ├── message.dart              # Message model
│   │   ├── chat_context.dart         # Chat context model
│   │   ├── chat_info.dart            # Chat list info model
│   │   ├── group_chat.dart           # Group chat model
│   │   ├── moment_post.dart          # Moments post model
│   │   ├── emoji_item.dart           # Emoji item model
│   │   ├── sticker.dart              # Sticker model
│   │   ├── favorite_collection.dart  # Favorites collection model
│   │   ├── user.dart                 # User model
│   │   ├── proactive_config.dart     # Proactive message config model
│   │   └── onebot_config.dart        # OneBot QQ config model
│   ├── pages/                    # UI pages
│   │   ├── chat_list_page.dart       # Chat list (main page)
│   │   ├── chat_detail_page.dart     # Chat conversation detail
│   │   ├── contacts_page.dart        # Contacts list
│   │   ├── discover_page.dart        # Discover / moments feed
│   │   ├── profile_page.dart         # User profile
│   │   ├── moments_page.dart         # Moments (朋友圈) feed
│   │   ├── publish_moment_page.dart  # Publish a moment
│   │   ├── settings_page.dart        # App settings
│   │   ├── api_settings_page.dart    # AI API provider settings
│   │   ├── chat_settings_page.dart   # Per-chat settings
│   │   ├── role_settings_page.dart   # Role editing/configuration
│   │   ├── role_detail_page.dart     # Role detail view
│   │   ├── group_settings_page.dart  # Group chat settings
│   │   ├── create_group_page.dart    # Create group chat
│   │   ├── emoji_manager_page.dart   # Emoji/sticker management
│   │   ├── favorites_page.dart       # Favorites list
│   │   ├── favorite_detail_page.dart # Favorite detail view
│   │   ├── global_prompts_page.dart  # Global system prompts
│   │   ├── task_manager_page.dart    # Scheduled task management
│   │   └── ...
│   ├── services/                 # I/O services
│   │   ├── api_service.dart          # REST API client
│   │   ├── secure_websocket_client.dart  # Encrypted WebSocket client
│   │   ├── secure_backend_client.dart    # Encrypted HTTP client (AES)
│   │   ├── realtime_sync_service.dart    # WebSocket real-time sync
│   │   ├── memory_service.dart       # Memory management service
│   │   ├── settings_service.dart     # Settings persistence
│   │   ├── role_service.dart         # Role CRUD operations
│   │   ├── chat_list_service.dart    # Chat list management
│   │   ├── group_chat_service.dart   # Group chat operations
│   │   ├── moments_service.dart      # Moments API calls
│   │   ├── emoji_service.dart        # Emoji management
│   │   ├── sticker_service.dart      # Sticker management
│   │   ├── favorite_service.dart     # Favorites management
│   │   ├── task_service.dart         # Task management
│   │   ├── notification_service.dart # Local notifications
│   │   ├── background_runtime_service.dart  # Background keep-alive & scheduling
│   │   ├── intent_service.dart       # Intent handling & navigation
│   │   ├── message_splitter_service.dart    # Long message splitting
│   │   ├── image_service.dart        # Image loading & caching
│   │   ├── avatar_cache_service.dart # Avatar image cache
│   │   ├── storage_service.dart      # Local storage (SQLite/SharedPrefs)
│   │   ├── wake_lock_service.dart    # Screen wake lock
│   │   └── ...
│   ├── widgets/                  # Reusable UI components
│   │   ├── chat_bubble.dart          # Chat message bubble
│   │   ├── input_bar.dart            # Message input bar
│   │   ├── tab_bar.dart              # Bottom tab bar
│   │   └── smart_avatar_image.dart   # Smart avatar with fallback
│   └── utils/                    # Utilities
│       └── datetime_util.dart        # Date/time formatting helpers
├── android/                      # Android platform config
├── pubspec.yaml                  # Dart dependencies (version 1.2.4)
└── analysis_options.yaml         # Dart lint rules
```

### FastAPI Server (`server/`)
```
server/
├── main.py                   # Server entry — FastAPI app, config, CORS, lifecycle, routes
├── config/settings.json      # Runtime config (auth token, encryption, API keys, OneBot toggle)
├── data/                     # Runtime data (roles, avatars, moments, user_emojis, etc.)
├── runtime/                  # Runtime files (server logs, auto-generated)
├── routers/                  # API route handlers
│   ├── ai_behavior.py        # Unified AI behavior endpoint (chat, moments, tasks, proactive)
│   ├── chat.py               # Chat message API
│   ├── roles.py              # Role CRUD API
│   ├── moments.py            # Moments (朋友圈) API
│   ├── tasks.py              # Scheduled tasks API
│   ├── settings.py           # Settings API
│   └── onebot.py             # OneBot V11 QQ protocol adapter (HTTP POST + reverse WS)
├── services/                 # Business logic
│   ├── ai_service.py         # AI API calling (OpenAI-compatible + embedding)
│   ├── ai_tools.py           # AI function-calling tools (schedule_task, block_user)
│   ├── memory_service.py     # Memory storage (SQLite-based)
│   ├── vector_memory.py      # Vector memory store (semantic search via embeddings)
│   ├── scheduler_service.py  # APScheduler-based task scheduling
│   ├── settings_service.py   # Configuration management
│   ├── search_service.py     # Web search for AI
│   └── security_service.py   # Auth token + encryption
├── transport/                # WebSocket & file serving
│   ├── ws_dispatcher.py      # WebSocket message dispatcher
│   ├── ws_endpoint.py        # Secure WebSocket endpoint
│   ├── onebot_ws.py          # OneBot reverse WebSocket connection manager
│   ├── push_hub.py           # Push notification hub (server-side push events)
│   └── file_routes.py        # File upload/download routes
├── core/                     # Server core utilities
│   ├── lifecycle.py          # Startup/shutdown lifecycle hooks (scheduler init/teardown)
│   ├── middleware.py         # FastAPI middleware (request logging, security/auth)
│   └── utils.py              # Shared utilities (tool role ID check, API key masking)
└── utils/                    # Standalone utility scripts
    └── migrate_messages_to_short_term.py  # One-time migration: messages → short_term
```

### Key Data Flow

1. **Chat**: Client sends message → `ai_behavior.py` → `ai_service.py` (AI API) → response streamed via WebSocket back to client
2. **Memory**: Messages stored in SQLite (server) and synchronized to client; core memories are summarized by a dedicated assistant model; vector embeddings are generated for user messages and summaries to enable semantic memory retrieval
3. **Scheduling**: `scheduler_service.py` (APScheduler) manages proactive messages, moments publishing, and timed tasks — runs independently in a background thread. AI-generated events (moments, comments, tasks, proactive messages) are handled via `lifecycle.py`
4. **AI Tool Calls**: `ai_service.py` (via `generate_with_role`) exposes function-calling tools defined in `ai_tools.py` to the AI model. Currently supports `schedule_task` (all contexts) and `block_user` (OneBot third-party only). Tool calls are executed, results injected back as `tool` messages, then the model generates the final response.
5. **OneBot QQ**: `onebot.py` bridges AI roles to QQ groups/private chats via NapCat framework using OneBot V11 protocol. Supports HTTP POST events and reverse WebSocket connections. Message aggregation window of 15 seconds
6. **Sync**: Client `realtime_sync_service.dart` connects via WebSocket for live push; REST API for CRUD operations. Client also uses `secure_websocket_client.dart` and `secure_backend_client.dart` with AES encryption

### Security & Transport

- All `/api/*` endpoints require `X-Auth-Token` header (default: `ZEROCHAT_FIXED_TOKEN_2026`)
- JSON request/response bodies are AES-encrypted (default key: `ZEROCHAT_TRANSFER_SECRET_2026`)
- File uploads/downloads bypass JSON encryption but still require auth token
- WebSocket at `/ws/secure` uses the same encryption for all frames
- OneBot WebSocket at `/onebot/ws/{role_id}` uses `access_token` query parameter
- Configurable in `server/config/settings.json`

## Key Conventions

- **mamba**: Use mamba for Python dependency management; activate env with `mamba activate ZeroChat`
- **Flutter**: Keep UI in `client/lib/pages/`/`client/lib/widgets/`, orchestration in `client/lib/core/`, external I/O in `client/lib/services/`
- **Server**: Route handlers in `routers/`, business logic in `services/`, transport concerns in `transport/`
- **Dependencies**: Dart deps in `client/pubspec.yaml`, Python deps in `server/requirements.txt`
- **Security defaults**: Auth token and encryption secret configured in `server/main.py` and persisted in `server/config/settings.json`
- **Linting**: Flutter uses `package:flutter_lints/flutter.yaml`; run with `flutter analyze`
- **Memory format**: SQLite (migrated from JSON); core memory + short-term memory window + vector memory for semantic retrieval
- **Emoji/sticker system**: AI determines emotion → selects emoji from configured folders; triggered by AI call (not keyword matching)
- **OneBot QQ**: Role config supports `onebot_enabled` flag; server config has global `onebot_enabled` toggle; messages aggregated within 15s window

## Backend Compatibility (Frontend Integration)

### WebSocket Actions

| Action | Payload | Response | Description |
|--------|---------|----------|-------------|
| `roles_memory_get` | `{role_id}` | `{core_memory, short_term, vector_memory_count}` | Fetch all memories for a role |
| `roles_memory_update` | `{role_id, core_memory?, short_term?}` | `{core_memory, short_term}` | Update memories for a role |
| `vector_memory_clear` | `{role_id}` | `{success, vector_memory_count}` | Clear vector memory embeddings for a role |

### Memory Response Fields (roles_memory_get)

```json
{
  "core_memory": ["line1", "line2"],
  "short_term": [{"role": "user", "content": "..."}],
  "vector_memory_count": 42
}
```

### Frontend MemoryService Fields

- `MemoryService.vectorMemoryCount` — number of vector embeddings on backend (read from `roles_memory_get` response)
- `MemoryService.clearVectorMemory()` — calls `vector_memory_clear` action, resets count to 0

### Vector Memory Behavior

- **Auto-embedding**: Every user message (≥10 chars) is asynchronously embedded and stored in the SQLite `vector_embeddings` table on the backend
- **Semantic retrieval**: During chat, `get_context_messages()` also queries vector memory for semantically similar past conversations (top-3, min similarity 0.35), injected as system context
- **Summary storage**: AI-generated memory summaries (`trigger_chat_summary`, `trigger_memory_summary`, `sequential_memory_generation`) are also embedded and stored
- **Sources**: `chat` (user messages), `memory_summary` (chat summaries), `sequential` (bridging memories), `core_summary` (core memory updates)
- **Backend-only**: Vector memory is managed entirely on the backend; the frontend only sees the count and can trigger a clear

### Settings Config

Embedding API defaults to the primary AI API provider if not separately configured:
- `embedding_enabled` (default: true)
- `embedding_api_url` (falls back to `ai_api_url`)
- `embedding_api_key` (falls back to `ai_api_key`)
- `embedding_model` (auto-detected: `deepseek-embedding` for DeepSeek, `BAAI/bge-m3` for SiliconFlow, `text-embedding-ada-002` otherwise)
