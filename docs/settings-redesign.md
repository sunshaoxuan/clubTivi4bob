# Desktop settings redesign

The shared Windows/macOS settings UI replaces the former unstructured scrolling
page with seven purpose-based categories. It uses the simplified channel browser's
navy gradient, pale blue selection, rounded surfaces and thin borders.

## Preserved controls

| Category | Controls |
| --- | --- |
| Channels and guide | M3U/Xtream/free providers; XMLTV add, edit, delete, enable, refresh, defaults; EPG mapping; refresh interval |
| Playback | User agent, buffer size, failover mode |
| Display and remote | Weather location, time format, web remote, key mapping help |
| Sync and privacy | Reviewed catalog refresh, playback feedback consent, automatic/manual diagnostics, candidate submission, historical downloads |
| AI and media | AI endpoint/model/key, enable, save/test/delete; Trakt/TMDB save/verify/clear; Debrid services |
| Recording and backup | Local/network folder, recording help, backup export/save/share/import |
| Updates and about | Version, live update check/download status, manual download when required, source repository |

Preference keys, persistence, API endpoints and consent requirements are unchanged.
AI, XMLTV and Debrid detail pages and all settings dialogs share the same design.
The old section layout and service card have been removed.

## Interaction and performance

- Wide windows use a sidebar; narrow windows use scrollable category chips.
- The workspace is capped at 1320 logical pixels for wide/4K displays.
- Each category mounts on its first visit, retaining draft inputs and scroll state.
- Hidden categories cannot receive keyboard focus and have their tickers paused.
- Mouse back navigation remains available alongside Escape support.
- Live update feedback still uses the existing platform-specific update service.

## Validation

`test/settings_design_test.dart` covers category completeness, 360/752/1200/3840
pixel layouts, enlarged text, lazy mounting, draft retention, mouse actions,
dialog styling, and the real screen's preference loading and saving.

An optional macOS visual fixture can be generated with:

```sh
BOBTV_SETTINGS_VISUAL=1 flutter test --no-pub --update-goldens test/settings_design_test.dart
```

It writes `/tmp/bobtv-settings-preview.png` and loads a local Chinese preview font.
Normal CI does not require that font or fixture.

The real-screen test also caught a web remote teardown race: a late stop or socket
callback could send client counts after its stream closed. Those callbacks now
check stream state, and stop iterates over a snapshot of connected clients.

Test build: `1.0.4+88`. This task does not publish a release, modify production
update feeds, install packages, or restart running BobTV applications.

The settings/player/update suite passed 50 tests, with one optional fullscreen
visual fixture skipped. Community/catalog/update-manifest suites passed another
27 tests. New design/test code and the remote lifecycle fix have no analyzer
issues. The packaged x64 Metal adapter passed 500 callbacks and 4000 two-stream
frames with resize/readback and no retained backings.

After SUNSX-PC came online, the Windows settings/update suite passed 16 tests
and Release compilation succeeded. Installer fixtures passed for both desktop
shortcut choices, including Chinese/Japanese install paths, start-menu entries,
managed shortcut policy and uninstall. Preserved helpers match the current
formal release, and installer source content matches after encoding/newline
normalization.

PowerShell Compress-Archive encountered an IOException on a protobuf file.
The file was confirmed readable and not read-only. A .NET ZIP rebuild succeeded;
the transferred archives matched SHA-256, normalized paths passed CRC checks,
and the previously blocked file was explicitly verified present.

The original Windows process remained PID 23920, responding, on installed
version `1.0.3+86`. The test executable is `1.0.4+88` and matches the freshly
compiled executable hash. No installed Windows files were modified. macOS and
Windows test packages are isolated from the installed apps. Neither platform
was restarted or automatically installed.

## Additional test pass on 2026-10-07

Real category pages were exercised at 480, 1200 and 3840 logical pixels, with
an isolated in-memory database. This found a narrow-window overflow in the
Trakt/TMDB key action row. Actions now wrap and use Chinese labels. Typing a
key also immediately refreshes the save button's enabled state.

AI detail tests use mocked preferences and secure storage, checking saving and
key masking without a model request. The Debrid detail page was checked at
480 pixels. All 15 settings tests passed. Existing packaged test artifacts
predate this action-row correction and must be rebuilt before distribution.
Native GUI clicking and installed-package playback were not performed during
this pass; running user applications and configurations were preserved.

## Authorized installation test, build 1.0.4+89

After user approval, both platforms were rebuilt. macOS x64 and arm64 DMG
checksums and signed update archives passed validation. The local x64 app was
installed at `~/Applications/BobTV.app`, preserving the desktop link. The former
app, preferences and complete application-support directory were backed up.
The new process initialized its player and synchronized the website catalog.
The installed Metal adapter passed 500 callbacks and 4000 two-stream frames,
including resize and GPU readback without retained backings.

The shared settings suite passed 15 tests with mocked credentials and an
in-memory database. Actual native settings appearance requires user observation;
this connection does not expose native mouse or screenshot automation.

Windows passed 21 settings/update tests plus both installer shortcut choices,
Unicode paths and uninstall fixtures. The installed app was replaced and
restarted using its existing interactive scheduled task. A previously downloaded
1.0.3+87 update raced the first manual installation and changed `data/app.so`.
The manual installer now stops only BobTV's detached update/monitor/progress
processes before closing the app. Reinstallation produced matching executable
and AOT hashes. The new process responded and emitted `video_ready`.

The Windows ZIP initially attempted to include an actively written build log.
Repacking only the application directory succeeded; transferred SHA-256 values
matched, and normalized ZIP entries passed CRC verification. The installed
player retains a pre-existing unsupported `loudnorm` filter warning. No claim
of live audio quality validation is made from these checks.
The restarted Windows process (PID 7192) acknowledged startup health and matched
the staged AOT hash. Application Error/WER events contained no new BobTV crash.
