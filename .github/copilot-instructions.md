# ZeroChat Project Guidelines

## Quick Start

ZeroChat is a **Flutter client + FastAPI server** project. This repository is split into:
- **Client**: [client/](../client) — Flutter UI (Dart)
- **Server**: [server/](../server) — FastAPI backend (Python)

For detailed architecture and data flows, see [CLAUDE.md](../CLAUDE.md).

## Setup & Build

### Flutter (from `client/` directory)
```bash
cd client && flutter pub get          # Install dependencies
cd client && flutter run              # Run on device/emulator
cd client && flutter analyze          # Lint (follows analysis_options.yaml)
cd client && flutter test             # Run tests (uses flutter_test)
```

### Python Server (from `server/` directory)
**Option 1: venv + pip (default, faster)**
```bash
python -m venv venv
./venv/Scripts/activate  # or: source venv/bin/activate
pip install -r requirements.txt
python main.py
```

**Option 2: conda/mamba (recommended for isolation)**
```bash
mamba activate ZeroChat   # or: conda activate ZeroChat
python main.py
```

**Windows auto-start scripts**:
- [start.bat](../server/start.bat) — Creates venv if missing, installs deps, runs server
- [start_mamba.bat](../server/start_mamba.bat) — Alternative using conda/mamba
- [setup_autostart.bat](../server/setup_autostart.bat) — Windows task scheduler integration

**Dependency source of truth**: [server/requirements.txt](../server/requirements.txt)

## Code Style & Boundaries

- Keep changes minimal and scoped to the requested feature or bug fix.
- Do not edit generated or build output directories (`client/build/`, `client/.dart_tool/`, Android intermediates) unless explicitly required.
- For Flutter code, follow the lint baseline in [client/analysis_options.yaml](../client/analysis_options.yaml).
- For Python server code, preserve existing module boundaries:
  - Routes: [server/routers](../server/routers)
  - Business logic: [server/services](../server/services)
  - Transport layer: [server/transport](../server/transport)

## Architecture Layers

**Flutter Client** (`client/lib/`):
- **UI**: [pages/](../client/lib/pages) + [widgets/](../client/lib/widgets) — User interface
- **Orchestration**: [core/](../client/lib/core) — Central controllers, schedulers, message handling
- **External I/O**: [services/](../client/lib/services) — API calls, WebSocket, storage, notifications
- **Models**: [models/](../client/lib/models) — Data structures

**FastAPI Server** (`server/`):
- **Routes**: [routers/](../server/routers) — HTTP/WebSocket endpoints (ai_behavior, roles, moments, tasks, settings, onebot)
- **Business Logic**: [services/](../server/services) — AI calls, memory, scheduling, security
- **Transport**: [transport/](../server/transport) — WebSocket dispatch, push notifications, OneBot V11
- **Core**: [core/](../server/core) — Middleware, lifecycle hooks, utilities

**Key Pattern**: Keep UI in `pages/`/`widgets/`, orchestration in `core/`, external I/O in `services/`.

## Security & Configuration

⚠️ **CRITICAL FOR PRODUCTION**: Security defaults are hardcoded in [server/main.py](../server/main.py) and persisted in [server/config/settings.json](../server/config/settings.json).

- **Auth Token**: `ZEROCHAT_FIXED_TOKEN_2026` (header: `X-Auth-Token`)
- **Transfer Encryption**: `ZEROCHAT_TRANSFER_SECRET_2026` (AES-256, JSON bodies only)
- **Default AI API Key**: May be empty; configure via settings API

**Action**: Before deployment, update these defaults in `server/main.py` and change them in `settings.json`.

See [CLAUDE.md](../CLAUDE.md) for backend compatibility (WebSocket actions, memory fields, embedding config).

## Testing & Validation

⚠️ **Testing Gaps**: Project lacks automated Python tests, Flutter widget tests, and CI/CD pipelines. Manual validation is required before release.

- **Flutter**: `flutter analyze` checks for lint violations
- **Python**: No test framework configured; manual validation only
- **Pre-Release Checklist**:
  - Run `flutter analyze` in client directory
  - Test core workflows manually (chat, moments, group messages, proactive messages)
  - Verify encryption/auth defaults are updated for production
  - Check WebSocket reconnection behavior under network loss (complex; see [ws-timeout-summary.md](../memories/repo/ws-timeout-summary.md))

## Project Conventions

- Use `/` in repository paths when writing docs or instructions.
- **Dart Regex Pitfall**: When matching literal `$`, avoid `r'$'` in replacements. Use escaped pattern: `RegExp(r'\$')` instead.
- **Naming**: PascalCase for Dart classes/files; snake_case for Python modules.
- **Config Organization**: Runtime config in [settings.json](../server/config/settings.json); security defaults in [main.py](../server/main.py).
- **File Organization**: Services, routers, core, models, pages are grouped in separate directories (not scattered).

## Documentation & Operational Notes

### Core Docs (Link, Do Not Duplicate)
- **Product Overview**: [README.md](../README.md) — Features, architecture diagram, quick-start, deployment
- **Backend Architecture**: [CLAUDE.md](../CLAUDE.md) — Deep dive into Flutter/Python structure, data flows, memory/embedding, OneBot QQ, WebSocket actions, settings
- **Core Module Behaviors**: [client/lib/core/README.md](../client/lib/core/README.md) — Function signatures, parameters, callers for orchestration layer
- **Available Agents**: [AGENTS.md](../AGENTS.md) — Custom agents to improve productivity (e.g., ZeroChat Reviewer)

### Operational Notes (Known Behaviors & Gotchas)
Linked in [/memories/repo](../memories/repo/) — Repository-scoped facts:
- [avatar-cache.md](../memories/repo/avatar-cache.md) — Avatar image caching strategy
- [background-runtime.md](../memories/repo/background-runtime.md) — Background keep-alive and scheduling
- [chat-ui-backgrounds.md](../memories/repo/chat-ui-backgrounds.md) — Chat/moments background handling
- [moments-backend-runtime.md](../memories/repo/moments-backend-runtime.md) — Moments publication and scheduling
- [ws-timeout-summary.md](../memories/repo/ws-timeout-summary.md) — WebSocket timeout and reconnection behavior

## Common Pitfalls

- ❌ **Wrong directory**: Before `flutter pub get` or `npm install`, confirm current directory. Don't run in repo root (user memory: [debugging.md](../memories/user/debugging.md))
- ❌ **Build output edits**: Do not modify `client/build/`, `client/.dart_tool/`, or Android intermediates
- ❌ **Hardcoded secrets**: Auth token and encryption secret must not be hardcoded in source files
- ❌ **OneBot scope**: OneBot QQ integration only applies to specific roles; requires NapCat framework and `onebot_enabled` flag
- ❌ **Test coverage gaps**: No automated tests; manual QA before release
- ❌ **Bypassing ChatController**: Do not route AI calls or messages around the central orchestration hub
