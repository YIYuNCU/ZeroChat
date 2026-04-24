# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ZeroChat is an AI chat companion app with a WeChat-like UI. It uses a **Flutter client** + **FastAPI server** architecture. The server handles AI API calls, role management, memory persistence (SQLite), and scheduling (proactive messages, moments, tasks). The client provides the UI and local state management.

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
│   │   ├── proactive_message_scheduler.dart  # AI proactive messaging
│   │   ├── group_scheduler.dart      # Group chat scheduling
│   │   ├── message_store.dart        # Message persistence
│   │   └── segment_sender.dart       # Segmented message sending
│   ├── models/                   # Data models (role, message, chat, moments, etc.)
│   ├── pages/                    # UI pages (chat, settings, moments, roles, etc.)
│   ├── services/                 # I/O services (API, memory, notifications, sync, etc.)
│   ├── widgets/                  # Reusable UI components (chat bubble, input bar, etc.)
│   └── utils/                    # Utilities (datetime, etc.)
├── android/                      # Android platform config
├── pubspec.yaml                  # Dart dependencies
└── analysis_options.yaml         # Dart lint rules
```

### FastAPI Server (`server/`)
```
server/
├── main.py                   # Server entry — creates FastAPI app, config, CORS, lifecycle
├── config/settings.json      # Runtime config (auth token, encryption, etc.)
├── data/                     # Runtime data (roles, avatars, moments, user_emojis, etc.)
├── routers/                  # API route handlers
│   ├── ai_behavior.py        # Unified AI behavior endpoint
│   ├── chat.py               # Chat message API
│   ├── roles.py              # Role CRUD API
│   ├── moments.py            # Moments (朋友圈) API
│   ├── tasks.py              # Scheduled tasks API
│   └── settings.py           # Settings API
├── services/                 # Business logic
│   ├── ai_service.py         # AI API calling (OpenAI-compatible)
│   ├── memory_service.py     # Memory storage (SQLite-based)
│   ├── scheduler_service.py  # APScheduler-based task scheduling
│   ├── settings_service.py   # Configuration management
│   ├── search_service.py     # Web search for AI
│   └── security_service.py   # Auth token + encryption
├── transport/                # WebSocket & file serving
│   ├── ws_dispatcher.py      # WebSocket message dispatcher
│   ├── ws_endpoint.py        # WebSocket endpoint
│   ├── push_hub.py           # Push notification hub
│   └── file_routes.py        # File upload/download routes
└── core/                     # Server core utilities
    ├── lifecycle.py          # Startup/shutdown lifecycle hooks
    └── middleware.py         # FastAPI middleware (CORS, auth, etc.)
```

### Key Data Flow

1. **Chat**: Client sends message → `ai_behavior.py` → `ai_service.py` (AI API) → response streamed via WebSocket back to client
2. **Memory**: Messages stored in SQLite (server) and synchronized to client; core memories are summarized by a dedicated assistant model
3. **Scheduling**: `scheduler_service.py` (APScheduler) manages proactive messages, moments publishing, and timed tasks — runs independently in a background thread
4. **Sync**: Client `realtime_sync_service.dart` connects via WebSocket for live push; REST API for CRUD operations

### Security & Transport

- All `/api/*` endpoints require `X-Auth-Token` header (default: `ZEROCHAT_FIXED_TOKEN_2026`)
- JSON request/response bodies are AES-encrypted (default key: `ZEROCHAT_TRANSFER_SECRET_2026`)
- File uploads/downloads bypass JSON encryption but still require auth token
- Configurable in `server/config/settings.json`

## Key Conventions

- **mamba**: Use mamba for Python dependency management;activate env with `mamba activate ZeroChat`
- **Flutter**: Keep UI in `client/lib/pages/`/`client/lib/widgets/`, orchestration in `client/lib/core/`, external I/O in `client/lib/services/`
- **Server**: Route handlers in `routers/`, business logic in `services/`, transport concerns in `transport/`
- **Dependencies**: Dart deps in `client/pubspec.yaml`, Python deps in `server/requirements.txt`
- **Security defaults**: Auth token and encryption secret configured in `server/main.py` and persisted in `server/config/settings.json`
- **Linting**: Flutter uses `package:flutter_lints/flutter.yaml`; run with `flutter analyze`
- **Memory format**: SQLite (migrated from JSON); core memory + short-term memory window for context management
- **Emoji/sticker system**: AI determines emotion → selects emoji from configured folders; triggered by AI call (not keyword matching)