# ZeroChat Project Guidelines

## Code Style

- Keep changes minimal and scoped to the requested feature or bug fix.
- Do not edit generated or build output directories (for example `client/build/`, `client/.dart_tool/`, Android intermediates) unless the task explicitly targets them.
- For Flutter code, follow the lint baseline in [client/analysis_options.yaml](../client/analysis_options.yaml).
- For Python server code, preserve existing module boundaries under [server/routers](../server/routers), [server/services](../server/services), and [server/transport](../server/transport).

## Architecture

- This repository is split into Flutter client and FastAPI server:
  - Client entry: [client/lib/main.dart](../client/lib/main.dart)
  - Core runtime logic: [client/lib/core](../client/lib/core)
  - Service layer: [client/lib/services](../client/lib/services)
  - Server entry: [server/main.py](../server/main.py)
  - API route layer: [server/routers](../server/routers)
  - Server business services: [server/services](../server/services)
- Keep UI concerns in `client/lib/pages`/`client/lib/widgets`, orchestration in `client/lib/core`, and external I/O in `client/lib/services`.

## Build And Test

- Flutter setup/run (from `client/` directory):
  - `cd client && flutter pub get`
  - `cd client && flutter run`
  - `cd client && flutter test`
- Python server setup/run (from [server](../server)):
  - manual run after mamba(ZeroChat) setup: `python main.py`
- Python dependency source of truth: [server/requirements.txt](../server/requirements.txt).

## Project Conventions

- Use `/` in repository paths when writing docs or instructions.
- Security-related defaults (auth token and transfer encryption) are configured in [server/main.py](../server/main.py) and persisted through [server/config/settings.json](../server/config/settings.json).
- Regex pitfall in Dart: when matching literal `$`, do not use `r'$'` in replacements; use an escaped literal pattern such as `RegExp(r'\$')`.

## Docs (Link, Do Not Duplicate)

- Product and setup overview: [README.md](../README.md)
- Core module behavior notes: [client/lib/core/README.md](../client/lib/core/README.md)
- Repository-specific operational notes: [/memories/repo](../memories/repo)
