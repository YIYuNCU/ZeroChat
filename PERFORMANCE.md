# Performance and Cache Changes

## Measured Results

Synthetic measurements on the Windows development machine, September 5, 2026.
These numbers describe local storage and synchronization work, not AI provider latency
or Android frame performance.

| Scenario | Before | After |
| --- | ---: | ---: |
| Server cold snapshot, 100 chats / 10,990 messages | 2,655.65 ms | 696.45 ms |
| Server unchanged snapshot check, mean of 5 requests | 2,021.98 ms | 83.62 ms |
| Client 10,000-message archive, full parse versus indexed 50-message page | 111 ms | 1.85 ms |

The client comparison is a full-file parse versus a warm indexed page in a Flutter
test process. It does not include page layout. The server benchmark uses temporary
fixtures and does not read production data.

## Behavior

- JSONL archives remain the source of truth. Disposable `.idx` sidecars contain
  50-message byte offsets, pending-message positions, a source signature, and an
  integrity checksum. Old or damaged indexes rebuild in an isolate. Appends update
  indexes; edits and replacements rebuild them. Full history rewriting and hashing
  run outside the UI isolate. Unchanged local revisions reuse their hash.
  Interrupted-send status recovery batches changes into one rewrite per chat.
- Startup loads local data without waiting for the network. Legacy history migration
  and interrupted-send recovery are serialized with archive changes. Reconciliation
  keeps outbox delivery, snapshots, and missed-reply recovery in that order.
- Push refreshes coalesce and retain a trailing refresh. Task messages refresh both
  chat and task data. Tasks and moments refresh independently of chat recovery.
- Chat list sorting is cached until list state changes. Message send-status changes
  no longer rebuild the chat list. Message rows retain stable keys during pagination;
  closing a page cancels its pending page result.
- Avatar downloads coalesce by identity, including source URL and content hash.
  Emoji caches build their path index once and distinguish backend origins. Existing
  legacy emoji filenames are adopted by the backend configured on first upgrade.
- Cache clearing invalidates older downloads. Completed downloads commit through
  serialized file operations; active partial transfers survive ordinary trimming and
  are removed when invalidated transfers finish. Decode errors trigger bounded
  invalidation and retry instead of retaining a broken path indefinitely.
- Media maintenance and access-time writes coalesce over a three-second window.
  Existing limits remain: decoded images 100 entries / 64 MiB, avatars 200 files /
  100 MiB, emoji 500 files / 200 MiB. Disk limits are restored by maintenance after
  bursts. Imported originals and chat history are not media-cache eviction targets.
- HTTP and WebSocket share a snapshot cache with a 64 MiB retained-object budget.
  Cache lookup checks source-file signatures, including role additions/removals.
  Conditional matches return metadata without rebuilding or copying full history.
  Message writes invalidate the cache; oversized snapshots are served without caching.
- File workers are limited to four threads. Chat file read/modify/write operations
  share normalized role locks, initialize files exclusively, and replace JSON files
  atomically. Worker shutdown is tied to application lifespan. Existing SQLite and
  AI HTTP connection pools remain in place.
- Snapshot digests use matching Dart/Python field, timestamp, and sorting rules.
  Endpoint names and response fields remain compatible; older clients can still
  receive full snapshots. Matching moments hashes skip rendering and cache writes.

## Verification

From `client/`:

```text
flutter test --no-pub
flutter analyze --no-pub
```

From `server/`:

```text
python -m unittest discover -s tests
python -m tests.benchmark_chat_snapshot
```

The regression suites cover archive migration, index corruption, UTF-8 boundaries,
pending messages outside the resident window, pagination cancellation, trailing
refreshes, cache invalidation during transfers, source changes, eviction, concurrent
chat writes, initialization races, hash compatibility, and event-loop responsiveness.

Full snapshot transfer remains the compatibility fallback after data changes; no
incremental wire protocol or SQLite migration was added.

## Android Emulator Verification

September 5, 2026: `ZeroChat_API_34`, Android 14 (API 34), x86_64, Pixel 5 display
1080x2340, 4 virtual CPU cores, 3072 MiB RAM, WHPX acceleration, SwiftShader software
graphics, Flutter Profile build with Impeller OpenGLES.

The device integration test passed with 100 synthetic contacts and a 10,000-message
archive. It verifies real Android storage plugins, 200 initially resident messages,
50-message history pagination, chat navigation and scrolling, avatar request
coalescing, cache hits, disk removal after clearing, and lifecycle transitions with
missing backend credentials. Avatar HTTP responses are
injected fixtures; no real backend or AI provider is contacted successfully.

| Measurement | Result |
| --- | ---: |
| Indexed 50-message page, mean of 10 reads | 3.759 ms |
| Cached UI ready after local service initialization | 201 ms |
| Downloads for 10 concurrent identical avatar requests plus a cache hit | 1 |
| Scroll frames sampled | 131 |
| Mean / p99 frame build | 0.723 / 2.009 ms |
| Mean / p99 frame rasterization | 19.899 / 35.066 ms |
| Frames over the build / raster budget | 0 / 104 |

The 201 ms measurement starts at `pumpWidget`, after fixture creation and service
initialization; it is not cold app startup. Software rasterization exceeded the frame
budget on this emulator. These numbers do not establish real-device smoothness or an
Android before/after speedup. Long-session memory, real network reconnection and
background delivery still require separate measurement.

### Reproduce On This Windows Machine

From the repository root in PowerShell:

```powershell
./tools/setup_android_test_device.ps1
./tools/start_android_test_device.ps1
# Wait for the Android home screen.
./tools/run_android_emulator_test.ps1
# Replace the test entrypoint with the normal app, retaining synthetic local data.
./tools/run_android_emulator_test.ps1 -NormalApp
```

The setup uses the existing Android SDK emulator, platform tools, platforms and
accepted licenses. It downloads official Android command-line tools 19.0 and the API
34 image with catalog SHA1 verification into ignored `.android-test/`. It creates SDK
directory junctions pointing to the existing SDK; do not recursively clean through
those junctions. Defaults for SDK, JDK and Flutter paths can be overridden by script
parameters. The default serial is `emulator-5556`; the start script accepts `-Port`.

The test runner refuses any AVD other than `ZeroChat_API_34`. The smoke test clears
that app's preferences and secure credentials, then replaces its test archive. Do not use this AVD for personal
data. `-SkipBuild` reuses the last APK and should only be used when its entrypoint
matches the intended test. The normal app is the same source, built in Profile mode,
not a production release APK.

The opt-in Gradle init script uses Aliyun Google/Central Maven mirrors because Java
TLS access to Google Maven failed here, and aligns the integration-test plugin with
the project's cached AGP 8.11.1. Normal Gradle repository configuration is unchanged.
The runner attaches to the profile APK with `--no-dds` so on-device timeline capture
can reach its own VM service.

Machine-readable report: `.android-test/results/emulator-results.json`.
Device test log: `.android-test/results/integration-logcat.txt`.

The normal app initially exposed uncaught `ensureConnected()` failures when Android
permission dialogs or background/foreground changes fired lifecycle callbacks without
backend credentials. Lifecycle recovery now catches and logs those failures while
retaining reconnect/resync behavior. The device regression drives inactive, hidden,
paused and resumed transitions with empty secure credentials and checks that the
cached chat list remains usable.

Cold startup also exposed a missing notification after loading the local chat list:
the service held 100 chats while the mounted offline page still showed its initial
empty state. `ChatListService.init()` now notifies listeners after loading. The
`chat_list_startup_test.dart` regression mounts a listener before initialization and
verifies that cached conversation names appear without any network event.

After both fixes, the normal `lib/main.dart` Profile APK was installed and checked
through ADB and screenshots. The cold-started list displayed cached conversations,
opening `Performance Test` loaded 200/10,000 messages, and Android Home followed by
task resume preserved the chat page. The captured normal-app log contained no
`Unhandled Exception` or `FATAL EXCEPTION`; missing-backend failures were handled.
Android reported 218 ms for the HOT activity resume. A single post-resume memory
sample reported 166,256 KiB PSS (162.4 MiB); this is not a long-session leak test.
Cold activity timings included Android permission-controller transitions and are
not used as app-startup performance measurements.

Additional artifacts in `.android-test/results/`:

- `normal-chat-list.png` and `normal-chat-detail.png`: verified normal app screens.
- `normal-app-logcat.txt`: startup, history load and lifecycle logs after the fixes.
- `normal-resume.txt` and `normal-memory.txt`: Android activity and memory samples.

Final Flutter regression suite: 84 tests passed. The device smoke test passed in
Profile mode; the subsequent cache-initialization notification was verified by the
new widget regression and the normal-entrypoint emulator checks described above.

## Physical Phone Test

The phone runner builds an isolated `com.zerochat.zerochat.devicetest` package named
`ZeroChat Test`. The existing `com.zerochat.zerochat` application and its data are
not installation or cleanup targets. Before fixture cleanup, the Dart test checks
the running package ID with Android PackageInfo; the host also checks APK badging
before installation. Default builds keep the original application ID and label.

After authorizing the computer's USB debugging fingerprint, run from the repository
root (replace the serial with the value from `adb devices`):

```powershell
./tools/run_android_phone_test.ps1 -Serial PHONE_SERIAL
./tools/run_android_phone_test.ps1 -Serial PHONE_SERIAL -NormalApp
```

`-BuildOnly` prepares and verifies the APK without connecting to a device. The runner
builds ARM32/ARM64 Profile code, preserves Dart VM service authentication, and collects
only the test application's process log. It does not grant phone permissions or
change global animation, refresh-rate, network, or battery settings. The test resets
preferences and known API credentials only inside the isolated package and uses
synthetic contacts and messages. `-NormalApp` installs the real app entrypoint in the
same isolated package for manual checks with those fixtures.

Phone APKs and reports are stored under `.android-test/phone-results/`. The shared
driver retains the report filename `emulator-results.json` in this separate phone
directory; its contents are the physical-device measurements for this run.

### HONOR PTP-AN00 Results

September 5, 2026: HONOR PTP-AN00, Android 16, SM8750, ARM64-only device, 1264x2800
display. The same Profile-mode storage/cache/navigation/lifecycle test passed on the
physical phone with 100 synthetic contacts and 10,000 messages.

| Measurement | Physical Phone | Software-GPU Emulator |
| --- | ---: | ---: |
| Indexed 50-message page, mean of 10 reads | 1.0809 ms | 3.759 ms |
| Cached UI ready after service initialization | 171 ms | 201 ms |
| Downloads for 10 concurrent avatar requests plus a cache hit | 1 | 1 |
| Scroll frames sampled | 157 | 131 |
| Mean / p99 frame build | 0.244 / 1.012 ms | 0.723 / 2.009 ms |
| Mean / p99 frame rasterization | 0.938 / 1.611 ms | 19.899 / 35.066 ms |
| Frames over integration_test's build / raster budget | 0 / 0 | 0 / 104 |

The UI-ready measurement excludes local service initialization, and the frame sample
is a short synthetic scroll. This is a device comparison, not a before/after code
comparison or a guarantee about all chats, image-heavy content, or long sessions.

This phone did not expose readable Flutter logcat output, so VM service URL discovery
was unavailable. The successful test used `-NoServiceAuth`, which connects through
an ephemeral ADB-forwarded localhost port and disables VM authentication only in the
isolated smoke-test process. The runner stops that process and removes forwarding
when collection finishes. The normal-app mode retains VM authentication. Reproduce
the smoke test on this phone with:

```powershell
./tools/run_android_phone_test.ps1 -Serial PHONE_SERIAL -NoServiceAuth
```

`-UseBuiltApk` reuses the matching saved phone APK (smoke test or normal app), still
verifying its package ID. System logcat is not usable here as evidence that the
normal app has no errors; test success and the structured metrics came from the
Flutter VM test driver.

The isolated normal-entrypoint app also displayed its cached conversation list and
restored the `Performance Test` history page after Android Home and task resume.
Android reported 72 ms for that HOT activity resume. Post-resume `dumpsys meminfo`
reported 260,782 KiB PSS (254.7 MiB); this is one sample, not a leak test. The initial
COLD activity result involved permission UI and is excluded from startup comparisons.
The original production package's APK installation path was identical before and
after the test; only the separate `ZeroChat Test` app was installed and manipulated.

The phone's ordinary display settings and overlays were retained. Screenshots are
`normal-chat-list.png` and `normal-chat-detail.png` in the phone-results directory;
`normal-resume.txt` and `normal-memory.txt` contain Android's raw measurements.
No real backend synchronization, AI requests, or background message delivery was
validated on the phone in this run.
